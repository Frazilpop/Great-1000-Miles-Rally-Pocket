-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 Pocket: capture every TOYBOX command MAME runs, with the MCU RAM and
-- EEPROM before and after, so the RTL can replay them (sim/mcu/tb_kaneko_toybox).
--
--   TBX_OUT=build/mcu_mame/gtmr \
--   mame -rompath ~/Downloads gtmr -autoboot_script sim/mcu/mame_toybox_capture.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none \
--        -nothrottle -seconds_to_run 90
--
-- Run it from an EMPTY directory (sim/mcu/capture.sh does): MAME keeps the
-- 93C46 in nvram/, and a second run would boot a formatted machine and take a
-- different path through the game's setup.
--
-- WHERE "BEFORE" AND "AFTER" ARE TAKEN
--
-- MAME runs the command inside the write handler of the fourth 0xFFFF, so
-- there is no instant between "command issued" and "command done" that a
-- frame notifier could see. Instead:
--
--   before  in a write TAP on the com registers. Taps run BEFORE the handler
--           they wrap (handler_entry_write_tap::write), so RAM is still as the
--           game left it. The script mirrors m_mcu_com (COMBINE_DATA and all)
--           to know which write is the one that triggers.
--   after   at the first 68000 access to MCU RAM after that, read or write,
--           from taps on 200000-20ffff. Only the 68000 and the MCU touch that
--           RAM, so nothing can have changed it between the run and then; a
--           write tap fires before its write lands.
--
-- Output, TBX_OUT/cap.bin, little-endian records:
--   'W' sel:u8 data:u16 mask:u16            a write to mcu_com<sel>
--   'U' addr:u32 data:u16 mask:u16          a write elsewhere in 2a0000-2dffff
--   'B' frame:u32 dsw:u16 ram-diff ee-diff  state before a triggering write
--   'A' ram-diff ee-diff                    state after the command
--   'E'                                     end
-- ram-diff = n:u32 then n x (word:u16 value:u16), against the previous
-- snapshot (all zero at the start); ee-diff = n:u8 then n x (word:u8 value:u16).
-- Also TBX_OUT/mcudata_dec.bin, MAME's mcudata region AFTER decrypt_rom(), so
-- the harness can check its own decryption against MAME's.
--
-- Globals throughout: a tap or notifier held only by a local is collected and
-- stops silently.

tbx_dir   = os.getenv("TBX_OUT") or "."
tbx_mach  = manager.machine
tbx_space = tbx_mach.devices[":maincpu"].spaces["program"]
tbx_fh    = assert(io.open(tbx_dir .. "/cap.bin", "wb"))

-- MAME's 93C46 keeps its words in a byte array, m_data, little-endian
-- (eeprom.cpp internal_read: get_u16le). It is a save item, which is the one
-- Lua route to it.
do
    local ee = tbx_mach.devices[":eeprom"]
    for name, idx in pairs(ee.items) do
        if name:match("/m_data$") then tbx_ee_item = emu.item(idx) end
    end
    assert(tbx_ee_item, "no m_data save item on :eeprom")
end
tbx_dsw = tbx_mach.ioport.ports[":DSW1"]

do
    local r = tbx_mach.memory.regions[":mcudata"]
    local f = assert(io.open(tbx_dir .. "/mcudata_dec.bin", "wb"))
    local t = {}
    for i = 0, r.size - 1 do
        t[#t + 1] = string.char(r:read_u8(i))
        if #t == 4096 then f:write(table.concat(t)); t = {} end
    end
    f:write(table.concat(t))
    f:close()
end

tbx_com      = { 0, 0, 0, 0 }      -- mirror of m_mcu_com, zero at reset
tbx_pending  = false               -- a command ran; "after" not taken yet
tbx_inside   = false               -- our own reads of MCU RAM, not the game's
tbx_prev_ram = string.rep("\0", 0x10000)
tbx_prev_ee  = string.rep("\0", 128)
tbx_frame    = 0
tbx_counts   = { W = 0, U = 0, B = 0, A = 0 }

local function ram_now()
    tbx_inside = true
    -- Step 2: read_range steps the ADDRESS by `step` bytes (default 1), so
    -- without it every word comes back twice in a 128 KB string.
    local s = tbx_space:read_range(0x200000, 0x20ffff, 16, 2)   -- host order, LE
    tbx_inside = false
    assert(#s == 0x10000, "read_range returned " .. #s .. " bytes")
    return s
end

local function ee_now()
    local t = {}
    for i = 0, 127 do t[#t + 1] = string.char(tbx_ee_item:read(i)) end
    return table.concat(t)
end

-- Diff two little-endian word strings; compare 64-byte chunks first so an
-- unchanged 64 KB costs a thousand string compares, not 32768 unpacks.
local function ram_diff(prev, cur)
    local out, n = {}, 0
    for c = 0, 0xffff, 64 do
        if prev:sub(c + 1, c + 64) ~= cur:sub(c + 1, c + 64) then
            for b = c, c + 62, 2 do
                local v = string.unpack("<I2", cur, b + 1)
                if v ~= string.unpack("<I2", prev, b + 1) then
                    n = n + 1
                    out[#out + 1] = string.pack("<I2I2", b >> 1, v)
                end
            end
        end
    end
    return string.pack("<I4", n) .. table.concat(out)
end

local function ee_diff(prev, cur)
    local out, n = {}, 0
    for w = 0, 63 do
        local v = string.unpack("<I2", cur, 2 * w + 1)
        if v ~= string.unpack("<I2", prev, 2 * w + 1) then
            n = n + 1
            out[#out + 1] = string.pack("<I1I2", w, v)
        end
    end
    return string.pack("<I1", n) .. table.concat(out)
end

local function snap(kind)
    local ram, ee = ram_now(), ee_now()
    local head = (kind == "B")
        and string.pack("<c1I4I2", "B", tbx_frame, tbx_dsw:read() & 0xffff)
        or  "A"
    tbx_fh:write(head, ram_diff(tbx_prev_ram, ram), ee_diff(tbx_prev_ee, ee))
    tbx_prev_ram, tbx_prev_ee = ram, ee
    tbx_counts[kind] = tbx_counts[kind] + 1
end

local function finish_pending()
    if tbx_pending then
        tbx_pending = false
        snap("A")
    end
end

-- The four registers are mapped at exactly 2a0000/2b0000/2c0000/2d0000
-- (gtmr_map, gtmr2_map), but the whole span is tapped so a write the map
-- ignores is counted rather than unseen.
tbx_tw_com = tbx_space:install_write_tap(0x2a0000, 0x2dffff, "tbx_com",
    function(offset, data, mask)
        local sel = (offset - 0x2a0000) >> 16
        if (offset & 0xffff) > 1 then
            tbx_fh:write(string.pack("<c1I4I2I2", "U", offset, data, mask))
            tbx_counts.U = tbx_counts.U + 1
            return data
        end
        -- COMBINE_DATA
        local nv = (tbx_com[sel + 1] & ~mask & 0xffff) | (data & mask)
        tbx_com[sel + 1] = nv
        local fires = tbx_com[1] == 0xffff and tbx_com[2] == 0xffff and
                      tbx_com[3] == 0xffff and tbx_com[4] == 0xffff
        if fires then
            finish_pending()              -- two runs with no access between
            snap("B")
            tbx_com = { 0, 0, 0, 0 }
            tbx_pending = true
        end
        tbx_fh:write(string.pack("<c1I1I2I2", "W", sel, data, mask))
        tbx_counts.W = tbx_counts.W + 1
        return data
    end)

local function on_ram(offset, data, mask)
    if tbx_pending and not tbx_inside then finish_pending() end
    return data
end
tbx_tw_ram = tbx_space:install_write_tap(0x200000, 0x20ffff, "tbx_ramw", on_ram)
tbx_tr_ram = tbx_space:install_read_tap(0x200000, 0x20ffff, "tbx_ramr", on_ram)

-- TBX_PLAY=1: after TBX_PLAY_AT frames (default 1500, well into attract),
-- drop a coin and play — Start and Button 1 pressed in turn through the menus,
-- then Button 1 (accelerate) held. Attract alone issues one 04 at boot; a race
-- loads its course data through 04, which is the command worth having most
-- examples of. Crude, but the only aim is to reach those commands.
tbx_play    = os.getenv("TBX_PLAY") == "1"
tbx_play_at = tonumber(os.getenv("TBX_PLAY_AT") or "1500")
local function field(port, name)
    return tbx_mach.ioport.ports[port].fields[name]
end
if tbx_play then
    tbx_f_coin  = field(":SYSTEM", "Coin 1")
    tbx_f_start = field(":SYSTEM", "1 Player Start")
    tbx_f_b1    = field(":P1", "P1 Button 1")
end

-- TBX_INJECT=1: at frame TBX_INJECT_AT (default 600, after the boot commands)
-- issue commands of our own, through the 68000's program space, so MAME's own
-- mcu_run answers them: every 04 subcommand 0..63 with a random destination,
-- and 02/42/03/43/unknown at random offsets. The four 0xFFFF writes go in a
-- random order, sometimes as two byte writes, sometimes after a non-0xFFFF
-- value, so COMBINE_DATA and the trigger are exercised too. The game only ever
-- issues five commands, all at boot; this is how MAME gets to say what the
-- other 59 subcommands do. All in one frame-notifier call, while the 68000 is
-- stopped; "after" is still taken by the RAM taps (our next parameter write)
-- or at the game's next access.
--
-- Cases where MAME itself is undefined are skipped, not injected: a copy past
-- the end of the 64 KB share or the 128 KB region, or 02/42 past the share.
tbx_inject    = os.getenv("TBX_INJECT") == "1"
tbx_inject_at = tonumber(os.getenv("TBX_INJECT_AT") or "600")
tbx_skipped   = 0

local function rd8(i) return tbx_mach.memory.regions[":mcudata"]:read_u8(i) end

local function issue(cmd, off, data)
    tbx_space:write_u16(0x200010, cmd)
    tbx_space:write_u16(0x200012, off)
    tbx_space:write_u16(0x200014, data)
    local order = { 0, 1, 2, 3 }
    for i = 4, 2, -1 do
        local j = math.random(1, i); order[i], order[j] = order[j], order[i]
    end
    for _, sel in ipairs(order) do
        local a = 0x2a0000 + (sel << 16)
        local how = math.random(1, 4)
        if how == 1 then                              -- a wrong value first
            tbx_space:write_u16(a, math.random(0, 0xfffe))
            tbx_space:write_u16(a, 0xffff)
        elseif how == 2 then                          -- two byte writes
            tbx_space:write_u8(a + 1, 0xff)
            tbx_space:write_u8(a, 0xff)
        else
            tbx_space:write_u16(a, 0xffff)
        end
    end
end

local function inject()
    math.randomseed(0x70b0)
    for sub = 0, 63 do
        local e = 0x10000 + sub * 8
        local start = rd8(e + 2) | (rd8(e + 3) << 8)
        local len   = rd8(e + 4) | (rd8(e + 5) << 8)
        if start + len > 0x10000 then
            tbx_skipped = tbx_skipped + 1
        else
            local dest = math.random(0x0018, 0x10000 - len) & 0xffff
            if len == 0 then dest = math.random(0x0018, 0xffff) end
            issue(0x0400 | math.random(0, 255), dest,
                  (math.random(0, 0x3ff) << 6) | sub)
        end
    end
    local function woff() return math.random(0x0018, 0xff7e) end   -- /2 + 64 fits
    for _ = 1, 6 do issue(0x0200 | math.random(0, 255), woff(), math.random(0, 0xffff)) end
    for _ = 1, 6 do issue(0x4200 | math.random(0, 255), woff(), math.random(0, 0xffff)) end
    for _ = 1, 6 do issue(0x0300 | math.random(0, 255), woff(), math.random(0, 0xffff)) end
    for _ = 1, 2 do issue(0x4300 | math.random(0, 255), woff(), math.random(0, 0xffff)) end
    for _, hi in ipairs({ 0x00, 0x01, 0x05, 0x44, 0x82, 0xff }) do
        issue((hi << 8) | math.random(0, 255), woff(), math.random(0, 0xffff))
    end
    print(string.format("toybox inject: done at frame %d, %d subcommands skipped (MAME undefined)",
                        tbx_frame, tbx_skipped))
end

tbx_frame_n = emu.add_machine_frame_notifier(function()
    tbx_frame = tbx_frame + 1
    if tbx_inject and tbx_frame == tbx_inject_at then inject() end
    if not tbx_play then return end
    local t = tbx_frame - tbx_play_at
    if t < 0 then return end
    tbx_f_coin:set_value((t < 8) and 1 or 0)
    if t < 1800 then
        local ph = t % 120
        tbx_f_start:set_value((t >= 60 and ph < 8) and 1 or 0)
        tbx_f_b1:set_value((t >= 60 and ph >= 60 and ph < 68) and 1 or 0)
    else
        tbx_f_start:set_value(0)
        tbx_f_b1:set_value(1)
    end
end)

tbx_stop_n = emu.add_machine_stop_notifier(function()
    finish_pending()
    tbx_fh:write("E")
    tbx_fh:close()
    print(string.format("toybox capture: frames=%d com_writes=%d other_writes=%d commands=%d afters=%d",
        tbx_frame, tbx_counts.W, tbx_counts.U, tbx_counts.B, tbx_counts.A))
end)
