-- SPDX-License-Identifier: GPL-3.0-or-later
-- Great 1000 Miles Rally (Pocket): every 68000 write to the OKIs (800001,
-- 880001) and their banks (e00001, e80001), with the frame it fell in, for
-- the command stream; with MAME's -wavwrite beside it, the sound too.
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_oki.lua gtmr \
--       OKI_OUT=build/mame/oki/gtmr_race.txt OKI_FRAMES=4000 \
--       OKI_PLAN=build/mame/oki/race_plan.txt
--
-- OKI_OUT, one line a write: "<frame> <addr> <data> <clock>", the clock in
-- 48 MHz ticks of machine time from power-on: what sim/sound/tb_gtmr_oki
-- replays and tools/pocket/oki_model.py plays as MAME would. OKI_PLAN is
-- optional, the plan format of tools/mame_gtmr_io_profile.lua ("<frame>
-- coin=1 b1=0"...). Exits at frame OKI_FRAMES.
local OUT    = os.getenv("OKI_OUT") or "gtmr_oki.txt"
local FRAMES = tonumber(os.getenv("OKI_FRAMES") or "3000")
local PLANF  = os.getenv("OKI_PLAN")
local mach   = manager.machine
local space  = mach.devices[":maincpu"].spaces["program"]
local fmt    = string.format
local fh     = assert(io.open(OUT, "w"))
local frame, n = 0, 0

local function tap(lo)
  return space:install_write_tap(lo, lo + 1, fmt("oki_%06x", lo), function(offset, data, mask)
    if mask & 0xff ~= 0 then
      fh:write(fmt("%d %06x %02x %d\n", frame, lo + 1, data & 0xff,
                   math.floor(mach.time:as_double() * 48e6 + 0.5)))
      n = n + 1
    end
  end)
end
_G.gtmr_oki_taps = { tap(0x800000), tap(0x880000), tap(0xe00000), tap(0xe80000) }

local function field(port, name)
  local p = mach.ioport.ports[port]
  return p and p.fields[name]
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

_G.gtmr_oki_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if PLAN[frame] then
    for k, v in pairs(PLAN[frame]) do if P[k] then P[k]:set_value(v) end end
  end
  if frame % 1000 == 0 then print(frame .. " of " .. FRAMES); fh:flush() end
  if frame >= FRAMES then
    for _, t in ipairs(_G.gtmr_oki_taps) do t:remove() end
    fh:close()
    print(fmt("oki: %d writes in %d frames -> %s", n, frame, OUT))
    mach:exit()
  end
end)
