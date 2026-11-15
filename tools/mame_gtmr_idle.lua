-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): the gtmr-board 68000's spare time, frame by frame, in
-- MAME, to set against tb_gtmr's stats.csv (idle).
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_idle.lua gtmr \
--       IDLE_OUT=build/tmp/mame_idle.txt IDLE_FRAMES=2000 \
--       IDLE_PLAN=build/mame/play2/plan.txt
--
-- Each set's main program, once running, is one `bra.b *` and the game
-- happens in the interrupts. One line a frame: "<frame> <turns>", the turns
-- of that loop (10 cycles each, two fetches), so turns x 10 / the frame's
-- cycles is the share of the frame the 68000 had to spare. The first line
-- says the CPU's clock and the frame's length in its cycles.
--
-- Environment:
--   IDLE_OUT     output (default gtmr_idle.txt)
--   IDLE_FRAMES  frames to run (default 2000)
--   IDLE_PLAN    a plan file as tools/mame_gtmr_io_profile.lua's
--                ("<frame> coin=1 start=0 b1=1 right=0 ..."); none: the attract

local OUT    = os.getenv("IDLE_OUT") or "gtmr_idle.txt"
local FRAMES = tonumber(os.getenv("IDLE_FRAMES") or "2000")
local PLANF  = os.getenv("IDLE_PLAN")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local fmt   = string.format
local fh    = assert(io.open(OUT, "w"))

local IDLE = { gtmr = 0x0ae4, gtmre = 0x0ae4, gtmrusa = 0x0b0a,
               gtmr2 = 0x0d10, gtmr2u = 0x0d34 }
local ipc = assert(IDLE[emu.romname()], "no idle loop for " .. emu.romname())
local scr = mach.screens[":screen"]
-- (the 68000 is 16 MHz on every set: mame -listxml)
fh:write(fmt("# frame_cycles %.1f\n", 16e6 * scr.frame_period * 1e-18))

local turns = 0
_G.gtmr_idle_taps = {
  space:install_read_tap(ipc, ipc + 1, "idle_r", function(o, d, m)
    turns = turns + 1
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
_G.gtmr_idle_frame = emu.add_machine_frame_notifier(function()
  fh:write(fmt("%d %d\n", frames, turns))
  turns = 0
  frames = frames + 1
  if PLAN[frames] then
    for k, v in pairs(PLAN[frames]) do if P[k] then P[k]:set_value(v) end end
  end
  if frames >= FRAMES then
    for _, t in ipairs(_G.gtmr_idle_taps) do t:remove() end
    fh:close()
    print(fmt("idle: %d frames -> %s", frames, OUT))
    mach:exit()
  end
end)
