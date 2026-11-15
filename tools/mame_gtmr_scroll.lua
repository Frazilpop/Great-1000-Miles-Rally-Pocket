-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): the road's scroll in MAME, frame by frame, to set
-- against tb_gtmr's stats.csv (sx0, sy0).
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_scroll.lua gtmrusa \
--       SCR_OUT=build/tmp/mame_scroll.txt SCR_FRAMES=5000 \
--       SCR_PLAN=build/tmp/plan.txt
--
-- One line a frame: "<frame> <x> <y> <speed> <pc>", VIEW2 chip 0's layer-0
-- scroll as last written that frame (600004, 600006; hex, 10.6 fixed point),
-- the car's speed word, and the PC of the instruction that wrote X.
--
-- Environment:
--   SCR_OUT      output (default gtmr_scroll.txt)
--   SCR_FRAMES   frames to run (default 5000)
--   SCR_PLAN     a plan file as tools/mame_gtmr_io_profile.lua's; none: the attract

local OUT    = os.getenv("SCR_OUT") or "gtmr_scroll.txt"
local FRAMES = tonumber(os.getenv("SCR_FRAMES") or "5000")
local PLANF  = os.getenv("SCR_PLAN")

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local fmt   = string.format
local fh    = assert(io.open(OUT, "w"))

-- the speed word (compared with 0xC00 by the speed-lines routine)
local SPEED = { gtmr = 0x10362c, gtmre = 0x10362c, gtmrusa = 0x103e64 }
local spd = SPEED[emu.romname()]

local sx, sy, wpc = 0, 0, 0
_G.gtmr_scroll_taps = {
  space:install_write_tap(0x600004, 0x600007, "scroll_w", function(o, d, m)
    if o == 0x600004 then sx = d; wpc = cpu.state["PC"].value
    else sy = d end
  end),
}

local ports = mach.ioport.ports
local function field(port, name)
  local p = ports[port]
  if not p then return nil end
  for n, f in pairs(p.fields) do if n == name then return f end end
end
local P = {
  coin = field(":SYSTEM", "Coin 1"), start = field(":SYSTEM", "1 Player Start"),
  b1 = field(":P1", "P1 Button 1"), b2 = field(":P1", "P1 Button 2"),
  left = field(":P1", "P1 Left"), right = field(":P1", "P1 Right"),
  up = field(":P1", "P1 Up"), down = field(":P1", "P1 Down"),
}
local PLAN = {}
if PLANF then
  for line in io.lines(PLANF) do
    local fr, rest = line:match("^(%d+)%s+(.*)$")
    if fr then
      fr = tonumber(fr)
      PLAN[fr] = PLAN[fr] or {}
      for k, v in rest:gmatch("(%w+)=(%d)") do PLAN[fr][k] = tonumber(v) end
    end
  end
end

local frames = 0
_G.gtmr_scroll_frame = emu.add_machine_frame_notifier(function()
  fh:write(fmt("%d %04x %04x %04x %06x\n", frames, sx, sy,
               spd and space:read_u16(spd) or 0, wpc))
  frames = frames + 1
  if PLAN[frames] then
    for k, v in pairs(PLAN[frames]) do if P[k] then P[k]:set_value(v) end end
  end
  if frames >= FRAMES then
    for _, t in ipairs(_G.gtmr_scroll_taps) do t:remove() end
    fh:close()
    print(fmt("scroll: %d frames -> %s", frames, OUT))
    mach:exit()
  end
end)
