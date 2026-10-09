#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko16 Pocket: pull the TOYBOX "mcudata" region out of the MAME zips.
#
#   python3 -I sim/mcu/extract_mcudata.py <rompath> build/roms [set ...]
#
# Writes build/roms/<set>_mcudata.bin as MAME's region holds it after
# ROM_LOAD16_WORD_SWAP and BEFORE decrypt_rom() — the same bytes the SDRAM
# image carries, so the testbench decrypts them
# exactly as the RTL does.
#
# The file is found by CRC, not by name: the gtmr zip is a merged set, and
# gtmrusa's mmd0x3.u12 sits in it as gtmre/gtmrusa.u12. Each ROM_START below is
# copied from kaneko16.cpp; the CRC is checked again on the bytes read.
#
# ROM-derived, so it goes under build/ and is never committed (hard rule 2).
# This is deliberately separate from the Pocket ROM builder: the TOYBOX tests
# should not wait on, or break with, a tool written in parallel.
import os
import sys
import zipfile
import zlib

# set: (zip, name in kaneko16.cpp, CRC32, table)
SETS = {
    "gtmr":    ("gtmr.zip",  "mmd0x2.u124.bin", 0x3D7CB329, "normal"),
    "gtmre":   ("gtmr.zip",  "gtmrusa.u12",     0x2E1A06FF, "alt"),
    "gtmrusa": ("gtmr.zip",  "mmd0x3.u12",      0x2E1A06FF, "alt"),
    "gtmr2":   ("gtmr2.zip", "m2d0x0.u31",      0x2E1A06FF, "alt"),
    "gtmr2u":  ("gtmr2.zip", "m2d0x0.u31",      0x2E1A06FF, "alt"),
}
SIZE = 0x20000


def extract(rompath, outdir, name):
    zname, fname, crc, _ = SETS[name]
    zpath = os.path.join(rompath, zname)
    with zipfile.ZipFile(zpath) as z:
        hits = [i for i in z.infolist() if i.CRC == crc and i.file_size == SIZE]
        if not hits:
            raise SystemExit(f"{name}: no {SIZE:#x}-byte member with CRC "
                             f"{crc:08x} ({fname}) in {zpath}")
        data = z.read(hits[0])
    if zlib.crc32(data) != crc:
        raise SystemExit(f"{name}: {hits[0].filename} fails its CRC")
    # ROM_LOAD16_WORD_SWAP: region byte 2w is file byte 2w+1 and vice versa.
    sw = bytearray(SIZE)
    sw[0::2] = data[1::2]
    sw[1::2] = data[0::2]
    os.makedirs(outdir, exist_ok=True)
    out = os.path.join(outdir, f"{name}_mcudata.bin")
    with open(out, "wb") as f:
        f.write(sw)
    print(f"  {name:8s} {hits[0].filename} crc {crc:08x} -> {out}")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__ or "usage: extract_mcudata.py <rompath> <outdir> [set ...]")
    rompath, outdir = sys.argv[1], sys.argv[2]
    for name in sys.argv[3:] or ["gtmr", "gtmrusa", "gtmr2u"]:
        extract(rompath, outdir, name)


if __name__ == "__main__":
    main()
