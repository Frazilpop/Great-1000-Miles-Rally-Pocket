-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): a plan file played back in MAME, for gtmrusa: the
-- check that a race recorded by tools/mame_gtmr_record.lua repeats (its
-- scroll.txt and rand.txt against this run's), and MAME's pictures of the
-- frames to set beside tb_gtmr's.
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_replay.lua gtmrusa \
--       PLAY_PLAN=<dir>/plan.txt PLAY_DIR=<dir> PLAY_FRAMES=11602 \
--       PLAY_SNAP=11180-11480 -- -snapshot_directory <abs dir>
--
-- PLAY_DIR gets play_scroll.txt (as the recorder's scroll.txt),
-- play_rand.txt and play_idle.txt. PLAY_SNAP, if set, snapshots those
-- frames as mNNNNN.png: MAME's snapshot k is the picture of the harness's
-- frame k. The plan's frames count as the recorder's and the shake
-- script's: line k is set in the notifier whose count becomes k.

local PLAN   = assert(os.getenv("PLAY_PLAN"), "set PLAY_PLAN")
local DIR    = assert(os.getenv("PLAY_DIR"), "set PLAY_DIR")
local FRAMES = tonumber(os.getenv("PLAY_FRAMES") or "0")
local SA, SB = (os.getenv("PLAY_SNAP") or ""):match("^(%d+)-(%d+)$")
SA, SB = tonumber(SA), tonumber(SB)

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local scr   = mach.screens[":screen"]
local fmt   = string.format

local function field(port, name)
  for n, f in pairs(mach.ioport.ports[port].fields) do if n == name then return f end end
end
local F = {
  coin = field(":SYSTEM", "Coin 1"), start = field(":SYSTEM", "1 Player Start"),
  up = field(":P1", "P1 Up"), down = field(":P1", "P1 Down"),
  left = field(":P1", "P1 Left"), right = field(":P1", "P1 Right"),
  b1 = field(":P1", "P1 Button 1"), b2 = field(":P1", "P1 Button 2"),
}
for _, f in pairs(F) do f:set_value(0) end

local steps = {}
for ln in io.lines(PLAN) do
  local k, rest = ln:match("^(%d+)%s+(.*)$")
  if k then
    k = tonumber(k)
    steps[k] = steps[k] or {}
    for n, v in rest:gmatch("(%w+)=(%d+)") do
      if F[n] then steps[k][#steps[k] + 1] = { F[n], tonumber(v) } end
    end
  end
end

local out  = assert(io.open(DIR .. "/play_scroll.txt", "w"))
local rf   = assert(io.open(DIR .. "/play_rand.txt", "w"))
local idf  = assert(io.open(DIR .. "/play_idle.txt", "w"))
local sx, sy, turns = 0, 0, 0
_G.gtmr_replay_taps = {
  space:install_write_tap(0x600004, 0x600007, "pl_scroll", function(o, d, m)
    if o == 0x600004 then sx = d else sy = d end
  end),
  space:install_read_tap(0x900014, 0x900015, "pl_rand", function(o, d, m)
    rf:write(fmt("900014 R %04x %04x\n", d, m))
  end),
  space:install_read_tap(0x0b0a, 0x0b0b, "pl_idle", function(o, d, m)
    turns = turns + 1
  end),
}

local frames = 0
_G.gtmr_replay_frame = emu.add_machine_frame_notifier(function()
  out:write(fmt("%d %04x %04x %04x %04x %d %d %d\n", frames, sx, sy,
                space:read_u16(0x103e64), space:read_u16(0x1035ec),
                space:read_u16(0x103f1a), space:read_u16(0x103f18),
                space:read_u16(0x103f40)))
  idf:write(fmt("%d %d\n", frames, turns))
  turns = 0
  if SA and frames >= SA and frames <= SB then scr:snapshot(fmt("m%05d.png", frames)) end
  frames = frames + 1
  for _, s in ipairs(steps[frames] or {}) do s[1]:set_value(s[2]) end
  if FRAMES > 0 and frames >= FRAMES then
    out:close(); rf:close(); idf:close()
    mach:exit()
  end
end)
