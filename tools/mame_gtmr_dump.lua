-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): dump the gtmr board's complete video state at chosen
-- frames, with MAME's own picture of that frame, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_dump.lua gtmr \
--       DUMP_DIR=build/mame/dump/gtmr DUMP_FRAME=600,1800
--
-- or by hand (fresh -nvram_directory, or the EEPROM from the last run leaks in):
--
--   DUMP_DIR=$PWD/build/mame/dump/gtmr DUMP_FRAME=600 \
--   mame -rompath ~/Downloads gtmr -autoboot_script tools/mame_gtmr_dump.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle \
--        -seconds_to_run 600 -nvram_directory <empty dir>
--
-- Environment:
--   DUMP_DIR    output directory. One frame: files go straight in it. Several
--               (DUMP_FRAME=600,1800,...): one subdirectory f<NNNNN> each.
--   DUMP_FRAME  frame number(s), counted as MAME frame notifications from
--               power-on: frame 1 is the first picture MAME renders.
--   DUMP_SET    optional; checked against the running set.
--   LAYERS_OFF  optional comma list from spr,t00,t01,t10,t11 (t<chip><layer>):
--               the picture of the dumped frame is rendered with those layers
--               removed and saved as screen_off_<list>.png instead of
--               screen.png. Every other file is identical to a normal run's
--               (the sprite bitmap and VIEW2 regs are saved / put back as the
--               game left them). See "Layers off" below.
--
-- Files (16-bit data is little-endian u16 words, as mame_dump_frame.lua):
--   view2_0_vram.bin  500000-503fff   view2_1_vram.bin  580000-583fff
--   view2_0_regs.bin  the chip's 16 registers (0x600000-0x60001f; only the
--                     first 8 are mapped on this board, the rest read 0 on the
--                     bus — these are the device's own copies)
--   view2_1_regs.bin  0x680000-0x68001f (all 16 mapped)
--   spr_regs.bin      700000-70001f, the KC-002's 16 registers
--   palette.bin       300000-30ffff, 32768 xGRB_555 entries
--   spriteram_live.bin 400000-401fff, as the 68000 sees it now
--   spriteram_buffered.bin  the buffered copy the KC-002 drew THIS picture's
--                     sprites from (buffered_spriteram16 m_buffered, see below)
--   spriteram_next.bin      the buffered copy as it stands now — what the next
--                     frame's sprites will be drawn from
--   spr_regs_at_draw.bin    sprite regs at the IRQ5 acknowledge just after the
--                     KC-002 drew (see below)
--   sprite_bitmap.bin  KC-002 output that was composited into this picture:
--                     320x240 u16, (priority << 14) | pen, 0 = transparent;
--                     palette index = 0x4000 + pen (set_color_base(0x40*256)).
--                     Under every layer MAME fills with pen 0x7f00 (KC-002 is
--                     sprite type 1, kaneko16_v.cpp fill_bitmap).
--   workram.bin       100000-10ffff     mcuram.bin  200000-20ffff
--   ram310000.bin     310000-327fff
--   screen.png        MAME's picture of this frame (screen:snapshot, 320x240)
--   frame.json        metadata: frame numbers, times, vpos, which frame each
--                     item reflects, register values, display-enable writes
--
-- FRAME ALIGNMENT — WHAT EACH FILE DESCRIBES
--
-- Everything is captured inside the frame notifier, which MAME calls from
-- video_manager::frame_update(), called from screen_device::vblank_begin()
-- (screen.cpp update_if_primary), AFTER finish_screen_updates() has rendered
-- the frame and BEFORE any CPU runs again. So for frame N:
--
--   * VIEW2 VRAM / scroll RAM / registers, palette, work RAM, MCU RAM, sprite
--     regs, live sprite RAM: the state at the exact instant picture N was
--     rendered. The tilemaps of picture N were drawn from precisely these
--     bytes (one screen_update per frame: nothing on this board forces a
--     partial update).
--   * Sprites: kaneko16_state::interrupt at scanline 224 of frame N calls
--     render_sprites(m_spriteram->buffer()) and then m_spriteram->copy(). So
--     picture N's sprites were drawn ~16 lines before the picture from the
--     BUFFER, which held live sprite RAM as copied at line 224 of frame N-1.
--     spriteram_buffered.bin is m_buffered read in frame N-1's notifier —
--     nothing writes m_buffered between there and line 224 of frame N, so it
--     is byte for byte what the KC-002 drew from. spriteram_next.bin (m_buffered
--     at frame N) draws picture N+1.
--   * sprite_bitmap.bin is m_sprites_bitmap[m_buffer] read at frame N: the
--     exact sprite layer composited into picture N.
--   * spr_regs_at_draw.bin: the KC-002 reads its registers at line 224, not at
--     the picture. They are captured in a read tap on the level-5 autovector
--     (0x000074), i.e. when the 68000 acknowledges the IRQ that the line-224
--     callback raised right after drawing; frame.json gives the vpos.
--   * screen.png: screen:snapshot() renders the screen TEXTURE, which
--     video_output_update() has just pointed at picture N — so it IS picture
--     N, with the palette as dumped.
--
--   NOT screen:pixels(). video_output_update() flips m_curbitmap after
--   handing the new bitmap to the texture, and pixels() reads m_curbitmap, so
--   inside a frame notifier pixels() returns picture N-1 (through palette N).
--   That is the "picture N matches state N-1" lag recorded in
--   mame_dump_frame.lua for explbrkr: an artefact of the
--   reader, not of the hardware. PIXELS_TOO=1 also writes
--   pixels_at_notifier.rgb (raw RGB24, pixels() read in the same notifier as
--   screen.png) to demonstrate it: tools/pocket/gtmr_dump_view.py compares it
--   with this frame's screen.png and with the previous frame's.
--
-- LAYERS OFF
--
-- MAME has no switch for this driver's layers, so the script reaches in. In
-- frame N, at the IRQ5 acknowledge (just after the KC-002 drew and well
-- before vblank):
--   spr  zeroes m_sprites_bitmap[m_buffer] (0 = transparent), so the
--        composite has no sprites;
--   tXY  sets the VIEW2 disable bit for chip X layer Y in the device's m_regs
--        copy (regs[4] bit 12 = layer 0, bit 4 = layer 1; read at render in
--        kaneko_view2_tilemap_device::prepare). Written to the device state,
--        not through the bus, so the game never sees it; restored after the
--        picture (only the bits that were changed).
-- frame.json records the regs the picture was actually rendered with, so a
-- game write that undid the change between the hook and vblank would show.

local DIR    = os.getenv("DUMP_DIR") or "."
local SET    = os.getenv("DUMP_SET")
local PIXELS = (os.getenv("PIXELS_TOO") or "0") ~= "0"
if DIR:sub(1, 1) ~= "/" then DIR = (os.getenv("PWD") or ".") .. "/" .. DIR end

local FRAMES, WANT = {}, {}
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  FRAMES[#FRAMES + 1] = n; WANT[n] = true
end
table.sort(FRAMES)
local LAST = FRAMES[#FRAMES]

local OFF = {}
local offlist = os.getenv("LAYERS_OFF") or ""
for s in offlist:gmatch("[^,]+") do
  assert(({ spr = 1, t00 = 1, t01 = 1, t10 = 1, t11 = 1 })[s], "LAYERS_OFF: unknown layer " .. s)
  OFF[s] = true
end

local mach  = manager.machine
local romname = emu.romname()
local KNOWN = { gtmr = 1, gtmra = 1, gtmrb = 1, gtmro = 1, gtmre = 1, gtmrusa = 1,
                gtmr2 = 1, gtmr2a = 1, gtmr2u = 1, gtmr2ua = 1 }
assert(KNOWN[romname], "mame_gtmr_dump.lua is for the gtmr board, not " .. romname)
assert(not SET or SET == romname, "DUMP_SET=" .. tostring(SET) .. " but running " .. romname)

local space = mach.devices[":maincpu"].spaces["program"]
local scr   = mach.screens[":screen"]

local function item(tag, name)
  local idx = mach.devices[tag].items[name]
  assert(idx, "no save item " .. tag .. " " .. name)
  return emu.item(idx)
end
local it_buffered = item(":spriteram", "0/m_buffered")
local it_sprbuf   = item(":kan_spr", "0/m_buffer")
local it_bitmap   = { [0] = item(":kan_spr", "0/m_sprites_bitmap[i]"),
                      [1] = item(":kan_spr", "1/m_sprites_bitmap[i]") }
local it_sprregs  = item(":kan_spr", "0/m_sprites_regs")
local it_v2regs   = { [0] = item(":view2_0", "0/m_regs"), [1] = item(":view2_1", "0/m_regs") }

-- ------------------------------------------------------------ writers
local outdir = DIR
local function words_le(get, n)
  local t, out = {}, {}
  for i = 0, n - 1 do
    local v = get(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t >= 4096 then out[#out + 1] = table.concat(t); t = {} end
  end
  out[#out + 1] = table.concat(t)
  return table.concat(out)
end
local function write(name, data)
  local f = assert(io.open(outdir .. "/" .. name, "wb"))
  f:write(data); f:close()
end
local function bus(name, base, bytes)
  write(name, words_le(function(i) return space:read_u16(base + i * 2) end, bytes // 2))
end
local function itm(name, it, n)
  write(name, words_le(function(i) return it:read(i) end, n or it.count))
end
local function hexwords(it, n)
  local t = {}
  for i = 0, (n or it.count) - 1 do t[#t + 1] = string.format("%04x", it:read(i)) end
  return table.concat(t, " ")
end
local function bitmap_width(it) return it.count // 512 end   -- 512 rows

-- The Lua screen API has no vpos(); derive it from the time to the next
-- line 0 (vblank start on this screen: 240 lines, visible 0-239, so the
-- vblank period overlaps the top of the next frame).
local function vpos()
  local t = scr:time_until_pos(0)
  local lines = t / scr.scan_period
  return math.floor(scr.height - lines + 1e-6) % scr.height,
         (1 - (lines - math.floor(lines))) % 1
end

-- --------------------------------------------------------------- state
local frame = 0
local prev_buffered = nil            -- m_buffered at the previous notifier
local prev_buffered_frame = nil
local hook = {}                      -- per-frame IRQ5-acknowledge record
local disp = { writes = 0, last = nil, last_frame = nil }
local restore = nil

-- Display enable (0xc00000) is driver state with no save item; track writes.
_G.gtmr_disp_tap = space:install_write_tap(0xc00000, 0xc00001, "gtmr_disp",
  function(offset, data, mask)
    disp.writes = disp.writes + 1; disp.last = data & mask; disp.last_frame = frame + 1
  end)

-- Level-5 autovector fetch: the 68000 acknowledging the line-224 IRQ, which
-- the driver raises immediately after render_sprites() + copy().
_G.gtmr_irq5_tap = space:install_read_tap(0x000074, 0x000077, "gtmr_irq5",
  function(offset, data, mask)
    local f = frame + 1                -- the frame now being drawn
    if hook[f] then return end         -- once per frame (two word reads)
    local v, frac = vpos()
    local rec = { vpos = v, hpos = string.format("%.3f", frac),
                  regs = {}, applied = {} }
    for i = 0, 15 do rec.regs[i] = it_sprregs:read(i) end
    hook[f] = rec
    if WANT[f] and next(OFF) then
      if OFF.spr then
        local bm = it_bitmap[it_sprbuf:read(0)]
        local w = bitmap_width(bm)
        -- Keep what the KC-002 drew, so sprite_bitmap.bin is the same file
        -- a normal run writes.
        rec.bitmap = words_le(function(i) return bm:read((i // 320) * w + (i % 320)) end, 320 * 240)
        for y = 0, 239 do
          local row = y * w
          for x = 0, 319 do bm:write(row + x, 0) end
        end
        rec.applied[#rec.applied + 1] = "spr"
      end
      restore = {}
      for chip = 0, 1 do
        local mask = 0
        if OFF["t" .. chip .. "0"] then mask = mask | 0x1000 end
        if OFF["t" .. chip .. "1"] then mask = mask | 0x0010 end
        if mask ~= 0 then
          local r = it_v2regs[chip]:read(4)
          restore[chip] = { mask = mask, orig = r & mask }
          it_v2regs[chip]:write(4, r | mask)
          rec.applied[#rec.applied + 1] = string.format("view2_%d regs[4] |= %04x", chip, mask)
        end
      end
    end
  end)

local function json_str(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c)
  return string.format("\\u%04x", c:byte()) end) .. '"' end

local function dump_frame(n)
  outdir = (#FRAMES > 1) and string.format("%s/f%05d", DIR, n) or DIR
  os.execute('mkdir -p "' .. outdir .. '"')

  local sbuf = it_sprbuf:read(0)
  local bm = it_bitmap[sbuf]
  local w = bitmap_width(bm)

  -- Raw state at the render instant.
  bus("view2_0_vram.bin", 0x500000, 0x4000)
  bus("view2_1_vram.bin", 0x580000, 0x4000)
  -- The game's register values: any LAYERS_OFF bits are put back in the file
  -- (frame.json's *_as_rendered shows what the picture was drawn with).
  for chip = 0, 1 do
    local r = restore and restore[chip]
    write(string.format("view2_%d_regs.bin", chip), words_le(function(i)
      local v = it_v2regs[chip]:read(i)
      if r and i == 4 then v = (v & ~r.mask) | r.orig end
      return v end, 16))
  end
  itm("spr_regs.bin", it_sprregs)
  bus("palette.bin", 0x300000, 0x10000)
  bus("spriteram_live.bin", 0x400000, 0x2000)
  itm("spriteram_next.bin", it_buffered)
  if prev_buffered then write("spriteram_buffered.bin", prev_buffered) end
  bus("workram.bin", 0x100000, 0x10000)
  bus("mcuram.bin", 0x200000, 0x10000)
  bus("ram310000.bin", 0x310000, 0x18000)
  local h = hook[n]
  write("sprite_bitmap.bin", (h and h.bitmap) or words_le(function(i)
    return bm:read((i // 320) * w + (i % 320)) end, 320 * 240))
  if h then
    write("spr_regs_at_draw.bin", words_le(function(i) return h.regs[i] end, 16))
  end

  -- Picture.
  local png = next(OFF) and ("screen_off_" .. offlist:gsub(",", "_") .. ".png") or "screen.png"
  local err = scr:snapshot(outdir .. "/" .. png)
  if PIXELS then
    local px = scr:pixels()          -- u32 0xAARRGGBB, little-endian
    local t = {}
    for i = 1, #px, 4 do
      local b, g, r = px:byte(i, i + 2)
      t[#t + 1] = string.char(r, g, b)
    end
    write("pixels_at_notifier.rgb", table.concat(t))
  end

  local f = assert(io.open(outdir .. "/frame.json", "w"))
  local function kv(k, v, last) f:write(string.format('  %s: %s%s\n', json_str(k), v, last and "" or ",")) end
  f:write("{\n")
  kv("set", json_str(romname))
  kv("frame", n)
  kv("screen_frame_number", scr:frame_number())
  kv("machine_time", string.format("%.9f", mach.time:as_double()))
  kv("vpos_at_dump", (vpos()))
  kv("captured_in", json_str("frame notifier N = vblank_begin of frame N, right after picture N was rendered"))
  kv("state_files_reflect", json_str("frame N at the render instant (view2_*, palette, spr_regs, spriteram_live, workram, mcuram, ram310000)"))
  kv("spriteram_buffered_reflects", prev_buffered and
     json_str(string.format("m_buffered at frame %d's notifier = live sprite RAM at line 224 of frame %d; drew picture %d", prev_buffered_frame, prev_buffered_frame, n))
     or "null")
  kv("spriteram_next_reflects", json_str(string.format("live sprite RAM at line 224 of frame %d; draws picture %d", n, n + 1)))
  kv("sprite_bitmap_reflects", json_str(string.format("m_sprites_bitmap[%d], drawn at line 224 of frame %d, composited into picture %d", sbuf, n, n)))
  kv("picture", json_str(png .. " = picture " .. n .. (err and (" (snapshot error " .. tostring(err) .. ")") or "")))
  if h then
    kv("irq5_ack_vpos", h.vpos); kv("irq5_ack_line_fraction", h.hpos)
    kv("spr_regs_at_draw", json_str(table.concat((function() local t = {} for i = 0, 15 do t[#t+1] = string.format("%04x", h.regs[i]) end return t end)(), " ")))
    kv("layers_off_applied", json_str(table.concat(h.applied, "; ")))
  else
    kv("irq5_ack_vpos", "null")
  end
  kv("layers_off_requested", json_str(offlist))
  kv("view2_0_regs_as_rendered", json_str(hexwords(it_v2regs[0])))
  kv("view2_1_regs_as_rendered", json_str(hexwords(it_v2regs[1])))
  kv("spr_regs_now", json_str(hexwords(it_sprregs)))
  kv("display_enable_last_write", disp.last and string.format('"%04x"', disp.last) or "null")
  kv("display_enable_writes", disp.writes)
  kv("display_enable_last_write_frame", disp.last_frame or "null")
  kv("width", scr.width); kv("height", scr.height, true)
  f:write("}\n")
  f:close()
  print(string.format("dump: frame %d (screen frame %d) -> %s/%s", n, scr:frame_number(), outdir, png))
end

_G.gtmr_dump_frame_sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1

  if WANT[frame] then dump_frame(frame) end

  if restore then
    for chip, r in pairs(restore) do
      local v = it_v2regs[chip]:read(4)
      it_v2regs[chip]:write(4, (v & ~r.mask) | r.orig)
    end
    restore = nil
  end
  hook[frame - 1] = nil

  -- Keep this frame's buffer: it is what picture frame+1 is drawn from.
  if WANT[frame + 1] then
    prev_buffered = words_le(function(i) return it_buffered:read(i) end, it_buffered.count)
    prev_buffered_frame = frame
  end

  if frame >= LAST then mach:exit() end
end)
