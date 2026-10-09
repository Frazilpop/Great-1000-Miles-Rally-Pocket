-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): per-frame profile of the gtmr 68000's I/O traffic —
-- what the program does with the OKIs, the hit chip, the TOYBOX, the
-- watchdog and the inputs, frame by frame — so a moment of play (a crash)
-- can be read as "what the CPU did there".
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_io_profile.lua gtmr \
--       IO_PROFILE_OUT=build/mame/gtmr_io.txt IO_PROFILE_FRAMES=3000
--
-- One line per frame:
--   f<N> rom=<reads> ram=<accesses> oki0=<r>/<w> oki1=<r>/<w> hit=<r>/<w>
--        mcu=<cmds> wd=<n> in=<n> okb0=<n> okb1=<n> | oki0 writes | oki1 writes
--        | oki0 status reads (distinct values:count)
--
-- Environment:
--   IO_PROFILE_OUT     output (default gtmr_io_profile.txt)
--   IO_PROFILE_FRAMES  frames to run (default 3000)
--   IO_PROFILE_PLAY    1 = coin up and start a race (inputs scripted below)

local OUT    = os.getenv("IO_PROFILE_OUT") or "gtmr_io_profile.txt"
local FRAMES = tonumber(os.getenv("IO_PROFILE_FRAMES") or "3000")
local PLAY   = (os.getenv("IO_PROFILE_PLAY") or "0") ~= "0"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local fmt   = string.format
local fh    = assert(io.open(OUT, "w"))

local c = {}
local function zero()
  c = { rom = 0, ram = 0, o0r = 0, o0w = 0, o1r = 0, o1w = 0, hr = 0, hw = 0,
        mcu = 0, wd = 0, inp = 0, okb0 = 0, okb1 = 0, mst = 0, wheel = 0,
        o0wl = {}, o1wl = {}, o0rl = {}, o1rl = {}, hl = {}, mcul = {}, okbl = {} }
end
zero()

local function io_r(offset, data, mask)
  local a = offset & 0xffffff
  if a == 0x800000 then c.o0r = c.o0r + 1; local v = data & 0xff; c.o0rl[v] = (c.o0rl[v] or 0) + 1
  elseif a == 0x880000 then c.o1r = c.o1r + 1; local v = data & 0xff; c.o1rl[v] = (c.o1rl[v] or 0) + 1
  elseif a >= 0x900000 and a < 0x900040 then c.hr = c.hr + 1; c.hl[#c.hl+1] = fmt("r%02x", a & 0x3f)
  elseif a == 0xa00000 then c.wd = c.wd + 1
  elseif a >= 0xb00000 and a < 0xb00008 then c.inp = c.inp + 1
  elseif a == 0xd00000 then c.mst = c.mst + 1
  elseif a == 0x0ffffe then c.wheel = c.wheel + 1
  end
end
local function io_w(offset, data, mask)
  local a = offset & 0xffffff
  if a == 0x800000 then c.o0w = c.o0w + 1; c.o0wl[#c.o0wl+1] = fmt("%02x", data & 0xff)
  elseif a == 0x880000 then c.o1w = c.o1w + 1; c.o1wl[#c.o1wl+1] = fmt("%02x", data & 0xff)
  elseif a >= 0x900000 and a < 0x900040 then c.hw = c.hw + 1; c.hl[#c.hl+1] = fmt("w%02x=%04x", a & 0x3f, data & 0xffff)
  elseif a == 0xa00000 then c.wd = c.wd + 1
  elseif a == 0xe00000 then c.okb0 = c.okb0 + 1; c.okbl[#c.okbl+1] = fmt("b0=%02x", data & 0xff)
  elseif a == 0xe80000 then c.okb1 = c.okb1 + 1; c.okbl[#c.okbl+1] = fmt("b1=%02x", data & 0xff)
  elseif a >= 0x2a0000 and a <= 0x2d0001 then
    -- the fourth 0xffff runs the command block at 200010
    if a == 0x2d0000 then
      c.mcu = c.mcu + 1
      local cmd = space:read_u16(0x200010)
      local off = space:read_u16(0x200012)
      local dat = space:read_u16(0x200014)
      c.mcul[#c.mcul+1] = fmt("%04x/%04x/%04x", cmd, off, dat)
    end
  end
end
local function rom_r(offset, data, mask) c.rom = c.rom + 1 end
local function ram_rw(offset, data, mask) c.ram = c.ram + 1 end

_G.gtmr_io_taps = {
  space:install_read_tap (0x0ffffe, 0xffffff, "io_r", io_r),
  space:install_write_tap(0x200000, 0xffffff, "io_w", io_w),
}

local function hist(t)
  local parts = {}
  for v, n in pairs(t) do parts[#parts+1] = fmt("%02x:%d", v, n) end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Inputs, when playing: a lookup of frame -> field values.
local ports = mach.ioport.ports
local function field(port, name)
  local p = ports[port]
  if not p then return nil end
  for n, f in pairs(p.fields) do if n == name then return f end end
  return nil
end
local P = {}
if PLAY then
  P.coin  = field(":SYSTEM", "Coin 1")
  P.start = field(":SYSTEM", "1 Player Start")
  P.b1    = field(":P1", "P1 Button 1")
  P.b2    = field(":P1", "P1 Button 2")
  P.left  = field(":P1", "P1 Left")
  P.right = field(":P1", "P1 Right")
  P.up    = field(":P1", "P1 Up")
  P.down  = field(":P1", "P1 Down")
  for k, v in pairs(P) do print("input", k, v and "ok" or "MISSING") end
  for pn, p in pairs(ports) do for fn, _ in pairs(p.fields) do print("port", pn, fn) end end
end

local PLAN = {}
if PLAY then
  -- frame -> {field=value}; a field stays as last set
  local f = os.getenv("IO_PROFILE_PLAN")
  if f then
    for line in io.lines(f) do
      local fr, rest = line:match("^(%d+)%s+(.*)$")
      if fr then
        PLAN[tonumber(fr)] = PLAN[tonumber(fr)] or {}
        for k, v in rest:gmatch("(%w+)=(%d)") do PLAN[tonumber(fr)][k] = tonumber(v) end
      end
    end
  end
end

local frames = 0
_G.gtmr_io_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  fh:write(fmt("f%d rom=%d ram=%d oki0=%d/%d oki1=%d/%d hit=%d/%d mcu=%d wd=%d in=%d wheel=%d mst=%d okb=%s | %s | %s | %s | %s | %s | %s\n",
    frames, c.rom, c.ram, c.o0r, c.o0w, c.o1r, c.o1w, c.hr, c.hw, c.mcu, c.wd, c.inp, c.wheel, c.mst,
    table.concat(c.okbl, ","),
    table.concat(c.o0wl, " "), table.concat(c.o1wl, " "),
    hist(c.o0rl), hist(c.o1rl), table.concat(c.hl, " "), table.concat(c.mcul, " ")))
  if (frames & 63) == 0 then fh:flush() end
  zero()
  if PLAY and PLAN[frames] then
    for k, v in pairs(PLAN[frames]) do if P[k] then P[k]:set_value(v) end end
  end
  local snapdir = os.getenv("IO_PROFILE_SNAP_DIR")
  local every = tonumber(os.getenv("IO_PROFILE_SNAP_EVERY") or "300")
  if snapdir and (frames % every) == 0 then
    mach.screens[":screen"]:snapshot(fmt("%s/f%05d.png", snapdir, frames))
  end
  if frames >= FRAMES then
    for _, t in ipairs(_G.gtmr_io_taps) do t:remove() end
    fh:flush(); fh:close()
    print(fmt("io profile: %d frames -> %s", frames, OUT))
    mach:exit()
  end
end)
