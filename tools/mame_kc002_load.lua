-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 (Pocket): measure the KC-002 sprite load per frame on the gtmr board.
--
--   OUT=build/mame/kc002_load.csv FRAMES=3600 \
--   mame -rompath ~/Downloads gtmr -autoboot_script tools/mame_kc002_load.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle
--
-- For every frame, parses the 1024 sprite records the way kaneko_spr.cpp does
-- (multisprite latching, per-sprite offset registers, global y offset) and
-- reports how many land inside the 320x240 visible area, how many 16-pixel
-- rows those contribute after clipping, and how many of those row pixels are
-- opaque. Opacity needs the sprite ROM, which is read from the kan_spr region.
--
-- Sprite RAM is read from the buffered copy the renderer actually uses is not
-- reachable from Lua, so this reads live sprite RAM at the frame boundary. The
-- count is a load estimate, not a pixel oracle.

local OUT    = os.getenv("OUT") or "kc002_load.csv"
local FRAMES = tonumber(os.getenv("FRAMES") or "3600")

local cpu   = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local spr   = manager.machine.memory.regions[":kan_spr"]
local nelem = spr.size // 256

local f = io.open(OUT, "w")
f:write("frame,visible,rows,pixels,opaque,nonblank,nb_rows,opq_rows\n")

local frame = 0
local blank = {}
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end

local function measure()
  local regs = {}
  for i = 0, 15 do regs[i] = space:read_u16(0x700000 + i * 2) end
  local flipx = (regs[0] & 2) ~= 0
  local flipy = (regs[0] & 1) ~= 0
  local lx, ly, lcode, lcolor, lxo, lyo = 0, 0, 0, 0, 0, 0
  local vis, rows, pix, opq, nb, nbrows, oprows = 0, 0, 0, 0, 0, 0, 0
  for i = 0, 1023 do
    local base = 0x400000 + i * 8
    local attr = space:read_u16(base)
    local code = space:read_u16(base + 2)
    local x    = space:read_u16(base + 4)
    local y    = space:read_u16(base + 6)
    local oi   = (attr >> 11) & 3
    local xo   = regs[8 + oi * 2]
    local yo   = (regs[9 + oi * 2] - regs[1]) & 0xffff
    if (attr & 0x8000) ~= 0 then lcode = lcode + 1; code = lcode else lcode = code end
    if (attr & 0x4000) ~= 0 then xo = lxo; yo = lyo else lxo = xo; lyo = yo end
    if (attr & 0x2000) ~= 0 then x = x + lx; y = y + ly end
    lx, ly = x, y
    local sx = (xo + x) & 0xffff
    local sy = (yo + y) & 0xffff
    if flipx then sx = (0x200 * 64 - sx - 16 * 64) & 0xffff end
    if flipy then sy = (0x200 * 64 - sy - 16 * 64) & 0xffff end
    sx = ((sx & 0x7fc0) - (sx & 0x8000)) // 64
    sy = ((sy & 0x7fc0) - (sy & 0x8000)) // 64
    local x0, x1 = math.max(sx, 0), math.min(sx + 15, 319)
    local y0, y1 = math.max(sy, 0), math.min(sy + 15, 239)
    if x0 <= x1 and y0 <= y1 then
      vis  = vis + 1
      rows = rows + (y1 - y0 + 1)
      pix  = pix + (y1 - y0 + 1) * (x1 - x0 + 1)
      local c = (code + ((y & 1) << 16)) % nelem
      if blank[c] == nil then
        local any = false
        for o = 0, 255 do if spr:read_u8(c * 256 + o) ~= 0 then any = true; break end end
        blank[c] = not any
      end
      if not blank[c] then nb = nb + 1; nbrows = nbrows + (y1 - y0 + 1) end
      for yy = y0, y1 do
        local rowop = false
        for xx = x0, x1 do
          -- 16x16x8 laid out as four 8x8 blocks: 0 1 / 2 3, 64 bytes each
          local px, py = xx - sx, yy - sy
          local blk = ((py >> 3) << 1) | (px >> 3)
          local off = c * 256 + blk * 64 + (py & 7) * 8 + (px & 7)
          if spr:read_u8(off) ~= 0 then opq = opq + 1; rowop = true end
        end
        if rowop then oprows = oprows + 1 end
      end
    end
  end
  f:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d\n", frame, vis, rows, pix, opq, nb, nbrows, oprows))
end

kc002_notifier = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  measure()
  if frame >= FRAMES then f:close(); manager.machine:exit() end
end)
