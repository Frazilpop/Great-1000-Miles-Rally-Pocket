-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): dump MAME's ROM regions for a gtmr-board set, so
-- tools/pocket/verify_rom.py can check the .rom image byte for byte.
--
--   DUMP_DIR=build/mame/regions/gtmr \
--   mame -rompath ~/Downloads gtmr -autoboot_script tools/mame_gtmr_regions.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle
--
-- (verify_rom.py runs this for you.) Writes <region>.bin for maincpu, mcudata,
-- kan_spr, view2_0, view2_1, oki1, oki2, each at MAME's region size, plus
-- regions.txt listing size / endianness / width.
--
-- LOGICAL BYTE ORDER. maincpu is a 16-bit big-endian region and MAME stores
-- it byte-swapped on a little-endian host; memory_region:read_u8/read_u32 undo
-- that (luaengine_mem.cpp region_read applies BYTE8_XOR_BE), so byte 0 here is
-- the high byte of the 68000's first word — the order of the .rom image.
--
-- mcudata IS DECRYPTED HERE: kaneko_toybox_device::device_start runs
-- decrypt_rom() in place before this script can see the region. verify_rom.py
-- decrypts the .rom slice before comparing.

local DIR  = os.getenv("DUMP_DIR") or "."
local mach = manager.machine
local NAMES = { "maincpu", "mcudata", "kan_spr", "view2_0", "view2_1", "oki1", "oki2" }

local function dump(name)
  local r = mach.memory.regions[":" .. name]
  if not r then print("  no region :" .. name); return nil end
  local f = assert(io.open(DIR .. "/" .. name .. ".bin", "wb"))
  -- read_u32 in the region's own endianness gives the next four LOGICAL bytes
  -- as a number; pack it back the same way round.
  local fmt = (r.endianness == "big") and ">I4" or "<I4"
  local size = r.size
  local chunk = {}
  local a = 0
  while a + 4 <= size do
    chunk[#chunk + 1] = string.pack(fmt, r:read_u32(a))
    a = a + 4
    if #chunk >= 8192 then f:write(table.concat(chunk)); chunk = {} end
  end
  while a < size do chunk[#chunk + 1] = string.char(r:read_u8(a)); a = a + 1 end
  f:write(table.concat(chunk))
  f:close()
  print(string.format("  %-8s %8x bytes  %s %d-bit", name, size, r.endianness, r.bitwidth))
  return string.format("%s size=%d endianness=%s bitwidth=%d\n", name, size, r.endianness, r.bitwidth)
end

local meta = assert(io.open(DIR .. "/regions.txt", "w"))
meta:write("set=" .. emu.romname() .. "\n")
for _, n in ipairs(NAMES) do
  local line = dump(n)
  if line then meta:write(line) end
end
meta:close()
mach:exit()
