#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
"""Look at, and cross-check, a frame dumped by tools/mame_gtmr_dump.lua.

    python3 -I tools/pocket/gtmr_dump_view.py build/mame/dump/gtmr/f02100 [...]

Standard library only (zlib PNG reader/writer), so it runs under -I. Writes
beside the dump:

  screen.rgb          screen.png decoded to raw 320x240 RGB24
  palette.png         the 32768-entry palette (xGRB_555), 256 x 128, one
                      pixel per entry, scaled x2
  sprite_layer.png    sprite_bitmap.bin through the palette (index 0x4000 +
                      pen); transparent pixels black

and checks, printing the numbers:

  * file sizes against what the dump script promises;
  * SPRITES vs PICTURE: wherever the sprite bitmap has priority 3 (drawn
    above every tile layer, kaneko_spr.cpp m_priority.sprite[3] = 8) and a
    non-zero pen, MAME's picture must be exactly palette[0x4000 + pen]. This
    ties sprite_bitmap.bin, palette.bin and screen.png to the same instant;
    a one-frame misalignment of any of them shows up as mismatches.
  * TILES OFF (a screen_off_t00_t01_t10_t11.png from LAYERS_OFF): every
    pixel must be the sprite layer over fill pen 0x7f00.
  * if pixels_at_notifier.rgb is present (PIXELS_TOO=1): how far it is from
    this frame's screen.png, and from the previous frame's if that frame was
    dumped too (sibling f<N-1>) — screen:pixels() lags by one picture.
"""

import os
import struct
import sys
import zlib

W, H = 320, 240
SIZES = {
    "view2_0_vram.bin": 0x4000, "view2_1_vram.bin": 0x4000,
    "view2_0_regs.bin": 0x20, "view2_1_regs.bin": 0x20, "spr_regs.bin": 0x20,
    "palette.bin": 0x10000, "spriteram_live.bin": 0x2000,
    "spriteram_next.bin": 0x2000, "spriteram_buffered.bin": 0x2000,
    "workram.bin": 0x10000, "mcuram.bin": 0x10000, "ram310000.bin": 0x18000,
    "sprite_bitmap.bin": W * H * 2,
}


# ------------------------------------------------------------------ PNG
def png_read(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, hdr = 8, [], None
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    w, h, depth, ctype, _, _, interlace = hdr
    if depth != 8 or ctype not in (2, 6) or interlace:
        raise SystemExit(f"{path}: unsupported PNG (depth {depth}, type {ctype})")
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xff
            elif f == 2:
                line[i] = (line[i] + b) & 0xff
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xff
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        prev = line
        if bpp == 3:
            out[y * w * 3:(y + 1) * w * 3] = line
        else:
            for x in range(w):
                out[(y * w + x) * 3:(y * w + x) * 3 + 3] = line[x * 4:x * 4 + 3]
    return w, h, bytes(out)


def png_write(path, w, h, rgb):
    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    rows = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


# -------------------------------------------------------------- palette
def pal5(v):
    return (v << 3) | (v >> 2)


def palette_rgb(pal_bytes):
    """xGRB_555 (palette_device::xGRB_555): G 14-10, R 9-5, B 4-0."""
    out = []
    for i in range(0, len(pal_bytes), 2):
        v = pal_bytes[i] | (pal_bytes[i + 1] << 8)
        out.append((pal5((v >> 5) & 31), pal5((v >> 10) & 31), pal5(v & 31)))
    return out


def words(b):
    return struct.unpack(f"<{len(b) // 2}H", b)


def view(d):
    print(f"{d}:")
    ok = True
    for name, size in SIZES.items():
        p = os.path.join(d, name)
        if not os.path.exists(p):
            print(f"  {name:<24} missing")
            continue
        n = os.path.getsize(p)
        if n != size:
            ok = False
        print(f"  {name:<24} {n:6d} bytes{'' if n == size else f'  EXPECTED {size}'}")

    pal = palette_rgb(open(os.path.join(d, "palette.bin"), "rb").read())
    img = bytearray()
    for y in range(256):
        row = bytearray()
        for x in range(512):
            row += bytes(pal[(y // 2) * 256 + x // 2])
        img += row
    png_write(os.path.join(d, "palette.png"), 512, 256, bytes(img))
    used = sum(1 for c in pal if c != (0, 0, 0))
    print(f"  palette.png              {used} of 32768 entries non-black")

    spr = words(open(os.path.join(d, "sprite_bitmap.bin"), "rb").read())
    layer = bytearray(W * H * 3)
    for i, v in enumerate(spr):
        if v & 0x3fff:
            layer[i * 3:i * 3 + 3] = bytes(pal[0x4000 + (v & 0x3fff)])
    png_write(os.path.join(d, "sprite_layer.png"), W, H, bytes(layer))
    opaque = sum(1 for v in spr if v & 0x3fff)
    print(f"  sprite_layer.png         {opaque} opaque sprite pixels")

    shots = [f for f in sorted(os.listdir(d)) if f.startswith("screen") and f.endswith(".png")]
    for shot in shots:
        w, h, rgb = png_read(os.path.join(d, shot))
        if (w, h) != (W, H):
            print(f"  {shot}: {w}x{h}, expected {W}x{H}")
            ok = False
            continue
        base = os.path.splitext(shot)[0]
        with open(os.path.join(d, base + ".rgb"), "wb") as f:
            f.write(rgb)
        if shot != "screen.png":
            if all(t in shot for t in ("t00", "t01", "t10", "t11")) and "spr" not in shot:
                # Every tile layer off: the picture is the fill pen (0x7f00 —
                # kaneko16_v.cpp fill_bitmap, KC-002 is sprite type 1) with
                # the whole sprite layer over it, priority irrelevant.
                good = sum(rgb[i * 3:i * 3 + 3] == bytes(pal[0x4000 + (v & 0x3fff)] if v & 0x3fff
                                                         else pal[0x7f00])
                           for i, v in enumerate(spr))
                if good != W * H:
                    ok = False
                print(f"  {shot}: sprite layer over fill pen 0x7f00 matches "
                      f"{good}/{W * H} pixels")
            else:
                print(f"  {shot:<24} decoded")
            continue
        top = same = 0
        for i, v in enumerate(spr):
            if (v >> 14) == 3 and v & 0x3fff:
                top += 1
                same += rgb[i * 3:i * 3 + 3] == bytes(pal[0x4000 + (v & 0x3fff)])
        verdict = "exact" if top == same else f"{top - same} MISMATCH"
        if top != same:
            ok = False
        print(f"  screen.png -> screen.rgb  priority-3 sprite pixels: {top}, "
              f"equal to palette[0x4000+pen] in the picture: {same} ({verdict})")

    pxp = os.path.join(d, "pixels_at_notifier.rgb")
    if os.path.exists(pxp) and os.path.exists(os.path.join(d, "screen.rgb")):
        px = open(pxp, "rb").read()
        here = open(os.path.join(d, "screen.rgb"), "rb").read()
        diff = sum(1 for i in range(0, len(px), 3) if px[i:i + 3] != here[i:i + 3])
        line = f"  pixels() in this notifier vs this frame's screen.png: {diff} pixels differ"
        parent, me = os.path.split(os.path.normpath(d))
        if me.startswith("f") and me[1:].isdigit():
            sib = os.path.join(parent, f"f{int(me[1:]) - 1:05d}", "screen.png")
            if os.path.exists(sib):
                _, _, prv = png_read(sib)
                d2 = sum(1 for i in range(0, len(px), 3) if px[i:i + 3] != prv[i:i + 3])
                line += f"; vs frame {int(me[1:]) - 1}'s screen.png: {d2}"
        print(line)
    return ok


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    ok = True
    for d in sys.argv[1:]:
        ok &= view(d)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
