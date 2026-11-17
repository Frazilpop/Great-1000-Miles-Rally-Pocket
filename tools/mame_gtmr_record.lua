-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): a race played by hand in MAME, recorded so that
-- tb_gtmr can replay it from power-on, frame for frame.
--
--   mame -rompath build/mame/romdir gtmrusa -window -skip_gameinfo \
--       -autoboot_delay 0 -nvram_directory <empty dir> -cfg_directory <empty dir> \
--       -autoboot_script tools/mame_gtmr_record.lua
--
-- (with REC_DIR set, and an empty nvram and cfg directory: the harness
-- starts from a blank EEPROM and MAME's default keys are the ones read).
--
-- The keys are read here once a frame, in the frame notifier, and held with
-- set_value until the notifier sees them let go. set_value doesn't shut the
-- keyboard out, though: MAME reads the key itself a frame before the
-- notifier does, so a press reaches the game a frame early and its release
-- (held by set_value) when the notifier sees it. The plan says so: a press
-- seen at notifier count k is written at k - 1, a release at k. (Found on a
-- drive of 11,602 frames, 16 Nov 2026: written at k, MAME's own playback of
-- the plan started the race a frame late and parted from the drive; written
-- so, it repeats it in every frame and every random number.) The harness's
-- plan has the keys below only; any other key on the SYSTEM port (Coin 2,
-- Service, 2 Players Start) reaches the game unrecorded, so each press of
-- one is written to other_keys.txt to be put in the plan by hand.
-- MAME's own keys: 5 coin, 1 start, the arrows, Left Ctrl button 1, Left
-- Alt button 2.
--
-- REC_DIR gets:
--   plan.txt    tb_gtmr's --inputs: "<frame> b2=1", a line per change (the
--               frame count as tools/mame_gtmr_shake.lua's: a change made at
--               notifier count k is the harness's plan line k; presses one
--               earlier, as above)
--   plan_tb.txt the same inputs for tb_gtmr's --inputs: a key set in MAME's
--               frame notifier reaches the game later than the harness's plan
--               line of the same number, the SYSTEM keys (coin, start) two
--               frames, the player's one (measured on a 11,602-frame drive,
--               16-17 Nov 2026: with these, the harness's random reads and
--               road kept to MAME's through the attract, the stage select
--               and a race's start; one frame either way parted them).
--               Written when MAME stops.
--   rand.txt    every read of the random port (0x900014), for --rand-from
--   scroll.txt  a line a frame, as mame_gtmr_shake.lua's SHAKE_OUT: frame,
--               VIEW2 chip 0's layer-0 scroll X and Y as last written,
--               the speed, the distance's high word, the shake's flag and
--               parity, and the stage number (gtmrusa's addresses)
--   idle.txt    the 68000's idle-loop turns a frame, as mame_gtmr_idle.lua's
-- Every file is flushed a frame at a time, so closing MAME at any point
-- leaves a usable recording. REC_FRAMES, if set, ends the run after that
-- many frames.

local DIR    = assert(os.getenv("REC_DIR"), "set REC_DIR")
local FRAMES = tonumber(os.getenv("REC_FRAMES") or "0")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local input = mach.input
local fmt   = string.format

local function open(name) return assert(io.open(DIR .. "/" .. name, "w")) end
local plan, rand, scroll, idle = open("plan.txt"), open("rand.txt"), open("scroll.txt"), open("idle.txt")
local other = open("other_keys.txt")

local tb_ev = {}             -- harness plan: frame -> { "b2=1", ... }
local function tb_add(f, kv)
  tb_ev[f] = tb_ev[f] or {}
  table.insert(tb_ev[f], kv)
end
local SYS = { coin = true, start = true }

local function field(port, name)
  local p = mach.ioport.ports[port]
  if not p then return nil end
  for n, f in pairs(p.fields) do if n == name then return f end end
end
local KEYS = {
  { "coin",  field(":SYSTEM", "Coin 1") },
  { "start", field(":SYSTEM", "1 Player Start") },
  { "up",    field(":P1", "P1 Up") },
  { "down",  field(":P1", "P1 Down") },
  { "left",  field(":P1", "P1 Left") },
  { "right", field(":P1", "P1 Right") },
  { "b1",    field(":P1", "P1 Button 1") },
  { "b2",    field(":P1", "P1 Button 2") },
}
local OTHER = {}
for n, f in pairs(mach.ioport.ports[":SYSTEM"].fields) do
  if n ~= "Coin 1" and n ~= "1 Player Start" then
    OTHER[#OTHER + 1] = { n, f:input_seq("standard"), false }
  end
end
local seqs, held = {}, {}
for i, k in ipairs(KEYS) do
  assert(k[2], "no field for " .. k[1])
  seqs[i] = k[2]:input_seq("standard")
  held[i] = 0
  k[2]:set_value(0)
end

local IDLE = { gtmr = 0x0ae4, gtmre = 0x0ae4, gtmrusa = 0x0b0a,
               gtmr2 = 0x0d10, gtmr2u = 0x0d34 }
local ipc = assert(IDLE[emu.romname()], "no idle loop for " .. emu.romname())

local sx, sy, turns = 0, 0, 0
_G.gtmr_record_taps = {
  space:install_write_tap(0x600004, 0x600007, "rec_scroll", function(o, d, m)
    if o == 0x600004 then sx = d else sy = d end
  end),
  space:install_read_tap(0x900014, 0x900015, "rec_rand", function(o, d, m)
    rand:write(fmt("900014 R %04x %04x\n", d, m))
  end),
  space:install_read_tap(ipc, ipc + 1, "rec_idle", function(o, d, m)
    turns = turns + 1
  end),
}
-- (the idle loop is one bra.b, a fetch a turn at ipc)

local frames = 0
_G.gtmr_record_frame = emu.add_machine_frame_notifier(function()
  scroll:write(fmt("%d %04x %04x %04x %04x %d %d %d\n", frames, sx, sy,
                   space:read_u16(0x103e64), space:read_u16(0x1035ec),
                   space:read_u16(0x103f1a), space:read_u16(0x103f18),
                   space:read_u16(0x103f40)))
  idle:write(fmt("%d %d\n", frames, turns))
  turns = 0
  frames = frames + 1
  local press, release = {}, {}
  for i, k in ipairs(KEYS) do
    local v = input:seq_pressed(seqs[i]) and 1 or 0
    if v ~= held[i] then
      held[i] = v
      k[2]:set_value(v)
      if v == 1 then press[#press + 1] = k[1] .. "=1"
      else release[#release + 1] = k[1] .. "=0" end
    end
  end
  -- in frame order: the last notifier's releases were at frames - 1 too
  if #press > 0 then plan:write((frames - 1) .. " " .. table.concat(press, " ") .. "\n") end
  if #release > 0 then plan:write(frames .. " " .. table.concat(release, " ") .. "\n") end
  for _, kv in ipairs(press) do
    tb_add(frames - 1 + (SYS[kv:match("^(%w+)")] and 2 or 1), kv)
  end
  for _, kv in ipairs(release) do
    tb_add(frames + (SYS[kv:match("^(%w+)")] and 2 or 1), kv)
  end
  for _, o in ipairs(OTHER) do
    local v = input:seq_pressed(o[2])
    if v and not o[3] then other:write(fmt("%d %s\n", frames - 1, o[1])) end
    o[3] = v
  end
  plan:flush(); rand:flush(); scroll:flush(); idle:flush(); other:flush()
  if FRAMES > 0 and frames >= FRAMES then mach:exit() end
end)

_G.gtmr_record_stop = emu.add_machine_stop_notifier(function()
  for _, f in ipairs({ plan, rand, scroll, idle, other }) do f:close() end
  local ks = {}
  for k in pairs(tb_ev) do ks[#ks + 1] = k end
  table.sort(ks)
  local tb = open("plan_tb.txt")
  for _, k in ipairs(ks) do tb:write(k .. " " .. table.concat(tb_ev[k], " ") .. "\n") end
  tb:close()
end)
