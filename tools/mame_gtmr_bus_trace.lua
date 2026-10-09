-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): trace the 68000's first N bus accesses from power-on on
-- the gtmr board, as the oracle for the core's own trace.
--
--   tools/pocket/mame_oracle.sh tools/mame_gtmr_bus_trace.lua gtmr \
--       BUS_TRACE_OUT=build/mame/gtmr_bus.txt BUS_TRACE_COUNT=200000
--
-- Compare with tools/pocket/diff_gtmr_trace.py (the gtmr maps, on top of
-- tools/diff_bus_trace.py's reader and rules), or diff_bus_trace.py itself.
--
-- Format, one access per line, exactly tools/mame_bus_trace.lua's:
--     <addr:06x> <R|W> <data:04x> <mask:04x>
-- addr is the byte address of the 16-bit word (even), mask the lanes the
-- 68000 drove (ffff word, ff00 even byte, 00ff odd byte). Lines starting '#'
-- mark frame boundaries ("# frame N" = MAME's vblank_begin of frame N; 3
-- fields, so diff_bus_trace.load() skips them).
--
-- Environment:
--   BUS_TRACE_OUT        output file (default gtmr_bus_trace.txt)
--   BUS_TRACE_COUNT      accesses to record (default 200000)
--   BUS_TRACE_DATA_ONLY  1 = skip instruction fetches: tap only 0ffffe-0fffff
--                        (the wheel, which sits INSIDE the ROM window) and
--                        100000-ffffff. ~5x fewer Lua callbacks.
--
-- FROM POWER-ON, NO SYNTHETIC RESET
--
-- tools/mame_bus_trace.lua had to fake a RESET on the CPU at frame 1 because
-- its taps went on a frame late. With -autoboot_delay 0, MAME 0.289 runs the
-- autoboot script at machine time 0.000, before the 68000 has executed a
-- cycle (measured: PC still 0, frame 0). So the taps go straight on, the first
-- two accesses are the reset vector reads at 000000/000002, and every RAM
-- holds its power-on content (MAME zero-fills), with no reset of any kind
-- in between.
--
-- WHAT THIS BOARD RETURNS THAT A CORE MUST MATCH
--
--   d00000  TOYBOX status: kaneko_toybox mcu_status_r returns 0 ALWAYS — the
--           HLE answers a command instantly, so trap #91 ("wait for bit 0 of
--           d00000 to be 0") never waits. An RTL TOYBOX that is busy for a
--           while reads 1 there and adds loop iterations; that is a real but
--           expected divergence, not a bus bug.
--   a00000  watchdog: reads and writes both kick it (reset16_r / reset16_w).
--   2a0000-2d0000  TOYBOX command writes. MAME's HLE then writes its reply
--           into MCU RAM (200000-20ffff) directly, with no bus cycles — the
--           reply only appears in the trace when the 68000 reads it.
--   0ffffe  wheel (gtmr_wheel_r / gtmr2_wheel_r), inside the ROM window.
--   Interrupts are autovectored: an IRQ shows as the two vector reads at
--   00006c (level 3, line 144), 000070 (level 4, line 64), 000074 (level 5,
--   line 224). There is no IACK cycle on the program bus.
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The file is streamed, so a crashed run keeps what it had.

local MAX  = tonumber(os.getenv("BUS_TRACE_COUNT") or "200000")
local OUT  = os.getenv("BUS_TRACE_OUT") or "gtmr_bus_trace.txt"
local DATA_ONLY = (os.getenv("BUS_TRACE_DATA_ONLY") or "0") ~= "0"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local romname = emu.romname()

local fh = assert(io.open(OUT, "w"))
local n, done, frames = 0, false, 0
local t0 = os.clock()
local fmt = string.format

local function record(rw, offset, data, mask)
  if done then return end
  n = n + 1
  fh:write(fmt("%06x %s %04x %04x\n", offset & 0xffffff, rw, data & 0xffff, mask & 0xffff))
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

local start_pc = cpu.state["PC"].value
print(fmt("bus trace: %s, script at machine time %.6f, PC %06x, %s",
          romname, mach.time:as_double(), start_pc, DATA_ONLY and "data only" or "all accesses"))

local ranges = DATA_ONLY and { { 0x0ffffe, 0x0fffff }, { 0x100000, 0xffffff } }
                          or { { 0x000000, 0xffffff } }
_G.gtmr_taps = {}
for i, r in ipairs(ranges) do
  _G.gtmr_taps[#_G.gtmr_taps + 1] = space:install_read_tap(r[1], r[2], "gtmr_bt_r" .. i,
    function(offset, data, mask) record("R", offset, data, mask) end)
  _G.gtmr_taps[#_G.gtmr_taps + 1] = space:install_write_tap(r[1], r[2], "gtmr_bt_w" .. i,
    function(offset, data, mask) record("W", offset, data, mask) end)
end

-- Finishing happens here, never inside a tap: exiting from a tap tears the
-- machine down under the access in flight, and taps left installed keep
-- costing a Lua call per access after the limit.
_G.gtmr_bt_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames > 3000 then
    for _, t in ipairs(_G.gtmr_taps) do t:remove() end
    fh:flush(); fh:close()
    local secs = os.clock() - t0
    print(fmt("bus trace: %d accesses in %d frames (%.3f s emulated), %.1f s CPU -> %s",
              n, frames, mach.time:as_double(), secs, OUT))
    mach:exit()
  end
end)
