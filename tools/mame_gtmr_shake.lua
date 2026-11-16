-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): gtmrusa taken straight to its top-speed shake, to
-- watch in MAME or log. (gtmre has the routine too, 12 bytes lower, but its
-- work RAM is laid out otherwise; the addresses here are gtmrusa's.)
--
--   mame -rompath build/mame/romdir gtmrusa -window -skip_gameinfo \
--       -autoboot_script tools/mame_gtmr_shake.lua
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_shake.lua gtmrusa \
--       SHAKE_OUT=build/tmp/shake.txt SHAKE_FRAMES=2600
--
-- The shake (gtmrusa 0x90a0-0x9100) moves the car and
-- the camera three steps on and one back on alternate frames once the speed
-- word is 0xE00 or more, the car isn't sliding sideways, and the distance
-- run is past the stage's share of it (0x14710 by stage: none on stage 1,
-- 0x40 of 0x60 on 2 and 3, 0x30 from 4). This script puts in a coin,
-- starts, holds the accelerator, sets the stage number (0x103f40) to 4 and,
-- once the car reaches top speed, the distance (0x1035ec) to half way, so
-- the shake starts about 35 seconds after power-on, on stage 1's road.
-- Nothing else is touched; steering is left to the player.
--
-- SHAKE_OUT, if set, gets one line a frame: frame, VIEW2 chip 0's layer-0
-- scroll X and Y as last written (hex, 10.6), the speed, the distance's
-- high word, and the shake's flag (0x103f1a) and parity (0x103f18).
-- SHAKE_FRAMES ends the run after that many frames (none: runs on).

local OUT    = os.getenv("SHAKE_OUT")
local FRAMES = tonumber(os.getenv("SHAKE_FRAMES") or "0")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local fmt   = string.format
local fh    = OUT and assert(io.open(OUT, "w"))

local sx, sy = 0, 0
_G.gtmr_shake_taps = {
  space:install_write_tap(0x600004, 0x600007, "shake_scroll", function(o, d, m)
    if o == 0x600004 then sx = d else sy = d end
  end),
}

local function field(port, name)
  local p = mach.ioport.ports[port]
  if not p then return nil end
  for n, f in pairs(p.fields) do if n == name then return f end end
end
local P = {
  coin = field(":SYSTEM", "Coin 1"), start = field(":SYSTEM", "1 Player Start"),
  b2 = field(":P1", "P1 Button 2"),
}
local PLAN = { [400] = { coin = 1 }, [404] = { coin = 0 },
               [440] = { start = 1 }, [444] = { start = 0 }, [1000] = { b2 = 1 } }

local frames, halfway = 0, false
_G.gtmr_shake_frame = emu.add_machine_frame_notifier(function()
  local spd = space:read_u16(0x103e64)
  if frames >= 900 then space:write_u16(0x103f40, 4) end
  if frames >= 900 and not halfway and spd >= 0xE00 then
    space:write_u16(0x1035ec, 0x30)
    halfway = true
  end
  if fh then
    fh:write(fmt("%d %04x %04x %04x %04x %d %d\n", frames, sx, sy, spd,
                 space:read_u16(0x1035ec), space:read_u16(0x103f1a),
                 space:read_u16(0x103f18)))
  end
  frames = frames + 1
  if PLAN[frames] then
    for k, v in pairs(PLAN[frames]) do if P[k] then P[k]:set_value(v) end end
  end
  if FRAMES > 0 and frames >= FRAMES then
    for _, t in ipairs(_G.gtmr_shake_taps) do t:remove() end
    if fh then fh:close() end
    mach:exit()
  end
end)
