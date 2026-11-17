-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): a recorded race played back in MAME (as
-- mame_gtmr_replay.lua) and, in frame STATE_FRAME, MAME's game state taken
-- for tools/pocket/state_from_mame.py to put into a core save state.
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_state.lua gtmrusa \
--       PLAY_PLAN=<rec>/plan.txt STATE_DIR=<dir> STATE_FRAME=3400
--
-- Why: MAME runs the board at 60 Hz on 240 lines, the board doesn't, so
-- where the 68000 has no time to spare (a stage being set up, the heaviest
-- crowds) the game's own timing differs and a replay from power-on parts
-- from MAME's. Started from MAME's state at a calm frame instead, the core
-- follows MAME's run from there.
--
-- The point: the first fetch of the idle loop (a bra.b to itself) after
-- IRQ5's vector in frame STATE_FRAME, i.e. as the handler's RTE returns
-- there. The 68000 is then in the idle loop with its stack empty and
-- nothing pending, as a core state frozen in the idle loop is.
--
-- STATE_DIR gets the memories as big-endian images (spr, v2w0, v2w1, wram,
-- pal, mram, xram .bin) and regs.txt: the frame, the random port's reads so
-- far (the place in rand.txt for tb_gtmr --rand-from), the 68000's
-- registers, and the last word written to each VIEW2, sprite and hit-chip
-- register (write-only on the board, so taken as written).

local PLAN = assert(os.getenv("PLAY_PLAN"), "set PLAY_PLAN")
local DIR  = assert(os.getenv("STATE_DIR"), "set STATE_DIR")
local AT   = assert(tonumber(os.getenv("STATE_FRAME")), "set STATE_FRAME")

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local fmt   = string.format

local IDLE = { gtmr = 0x0ae4, gtmre = 0x0ae4, gtmrusa = 0x0b0a,
               gtmr2 = 0x0d10, gtmr2u = 0x0d34 }
local ipc = assert(IDLE[emu.romname()], "no idle loop for " .. emu.romname())

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

local REGS = { { 0x600000, 8 }, { 0x680000, 16 }, { 0x700000, 16 },
               { 0x900020, 4 }, { 0x90002c, 4 } }
local last = {}                -- the last word written at each register address
local nrand, frames, irq5, done = 0, 0, false, false

local function image(name, a, n)
  local f = assert(io.open(DIR .. "/" .. name, "wb"))
  local t = {}
  for i = 0, n - 2, 2 do
    local w = space:read_u16(a + i)
    t[#t + 1] = string.char(w >> 8, w & 0xff)
    if #t == 4096 then f:write(table.concat(t)); t = {} end
  end
  f:write(table.concat(t))
  f:close()
end

local function take()
  done = true
  image("spr.bin",  0x400000, 0x2000)
  image("v2w0.bin", 0x500000, 0x4000)
  image("v2w1.bin", 0x580000, 0x4000)
  image("wram.bin", 0x100000, 0x10000)
  image("pal.bin",  0x300000, 0x10000)
  image("mram.bin", 0x200000, 0x10000)
  image("xram.bin", 0x310000, 0x18000)
  local f = assert(io.open(DIR .. "/regs.txt", "w"))
  f:write(fmt("frame %d\nrand %d\nidle %x\n", frames, nrand, ipc))
  -- (SP is the supervisor's: the game's idle loop runs in supervisor mode)
  for _, r in ipairs({ "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                       "A0", "A1", "A2", "A3", "A4", "A5", "A6", "USP", "SP", "SR" }) do
    f:write(fmt("%s %x\n", r, cpu.state[r].value))
  end
  for _, r in ipairs(REGS) do
    local t = {}
    for i = 0, r[2] - 1 do t[#t + 1] = fmt("%04x", last[r[1] + 2 * i] or 0) end
    f:write(fmt("w%06x %s\n", r[1], table.concat(t, " ")))
  end
  f:close()
  print(fmt("state: taken in frame %d, after %d random reads", frames, nrand))
end

local function wtap(a, n, name)
  return space:install_write_tap(a, a + 2 * n - 1, name, function(o, d, m)
    local w = o & ~1
    last[w] = ((last[w] or 0) & ~m) | (d & m)
  end)
end
_G.gtmr_state_taps = {
  wtap(0x600000, 8, "st_v2r0"), wtap(0x680000, 16, "st_v2r1"), wtap(0x700000, 16, "st_sprr"),
  wtap(0x900020, 4, "st_hit0"), wtap(0x90002c, 4, "st_hit1"),
  space:install_read_tap(0x900014, 0x900015, "st_rand", function() nrand = nrand + 1 end),
  space:install_read_tap(0x000074, 0x000077, "st_irq5", function()
    if frames >= AT then irq5 = true end
  end),
  space:install_read_tap(ipc, ipc + 1, "st_idle", function()
    if irq5 and not done then take() end
  end),
}

_G.gtmr_state_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  for _, s in ipairs(steps[frames] or {}) do s[1]:set_value(s[2]) end
  if done then mach:exit() end
end)
