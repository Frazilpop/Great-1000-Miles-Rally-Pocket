#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
"""Build the Pocket's SDRAM image (<set>.rom) for the gtmr board from MAME zips.

    python3 -I tools/pocket/build_rom.py gtmr ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py all  ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py gtmr2u ~/Downloads build/roms --regions

THE CONTRACT is the SDRAM layout table in LAYOUT below. One file per set, 0x1200000 bytes, every region at its fixed
base, every gap zero. The Pocket loads the file at bridge address 0 and the
shell writes byte n to SDRAM byte n.

Region contents are MAME's regions in LOGICAL byte order — byte 0 of maincpu
is the high byte of the 68000's first word, exactly as ROM_LOAD16_BYTE lays it
out — which is the order build_rom_regions.py and the MiSTer MRAs already use.
The one deliberate difference from MAME's in-memory state: mcudata is written
after ROM_LOAD16_WORD_SWAP but BEFORE kaneko_toybox's decrypt_rom(), which
MAME applies in place at device_start. The board decrypts.

FILES ARE FOUND BY CRC32, NOT BY NAME OR PATH. A merged gtmr.zip keeps
gtmrusa's sprite ROMs under gtmre/ and its MCU ROM as gtmre/gtmrusa.u12; a
split set keeps them elsewhere; gtmr2u's MCU ROM is the parent's m2d0x0.u31.
Every zip in ZIPDIR is indexed (central directory only, nothing decompressed
until needed), the set's own zip and its parent's are preferred, and a
directory ZIPDIR/<set>/ of loose files is accepted too. Size and CRC must both
match; zipfile re-checks the CRC as it decompresses.

--regions writes OUTDIR/<set>_<region>.bin for every MAME region at MAME's
region size (view2_1 included, though it is a ROM_COPY of view2_0), plus
<set>_mcudata_decrypted.bin, for the Verilator harness.

Hard rule 2: this reads ROMs named on the command line and writes only where
told — build/ by convention, which is gitignored. No ROM data is baked in
here: the TOYBOX decryption tables are read from MAME's source at run time
(third_party/mame/src/mame/kaneko/kaneko_toybox.cpp), not copied in.
"""

import argparse
import hashlib
import os
import re
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TOYBOX_SRC = os.path.join(REPO, "third_party", "mame", "src", "mame", "kaneko",
                          "kaneko_toybox.cpp")

# --------------------------------------------------------------------- layout
# The SDRAM layout: (region, base, max size). view2 is MAME's
# view2_0; view2_1 is a ROM_COPY of it on every set here and is not stored.
LAYOUT = [
    ("maincpu", 0x0000000, 0x100000),
    ("mcudata", 0x0100000, 0x020000),
    ("view2_0", 0x0200000, 0x440000),
    ("kan_spr", 0x0700000, 0x840000),
    ("oki1",    0x1000000, 0x100000),
    ("oki2",    0x1100000, 0x100000),
]
IMAGE_SIZE = 0x1200000

# ------------------------------------------------------------------ ROM_START
# Transcribed from kaneko16.cpp, ROM_START( gtmr ) .. ROM_START( gtmr2ua ), in
# source order WITHIN each region — order matters where loads overlap (gtmre,
# gtmrusa: the 16-bit pair fills 0x600000-0x7fffff, then gmmu30 / mm-203
# overwrites 0x600000-0x67ffff).
#
#   ("L", name, crc, offset, length)   ROM_LOAD
#   ("B", name, crc, offset, length)   ROM_LOAD16_BYTE: file byte k -> offset+2k
#   ("W", name, crc, offset, length)   ROM_LOAD16_WORD_SWAP: k -> offset+(k^1)
#   ("C", src_region, src_off, dst_off, length)   ROM_COPY
#
# Region: (size, erase) — erase is ROMREGION_ERASExx's value, or None for a
# region with flag 0. MAME zero-fills an unerased region only if it is at most
# 4 MB (romload.cpp); a larger one starts as whatever the allocator returned.
# Only gtmr/gtmra/gtmrb's kan_spr (0x840000, nothing loaded at
# 0x680000-0x7fffff) is affected; the image has zeros there, and verify_rom.py
# reports what MAME holds.


def L(n, c, o, s): return ("L", n, c, o, s)
def B(n, c, o, s): return ("B", n, c, o, s)
def W(n, c, o, s): return ("W", n, c, o, s)
def C(src, so, do, s): return ("C", src, so, do, s)


# Shared by gtmr / gtmra / gtmrb, which differ only in program and in one of
# the two small sprite EPROMs.
def _gtmr_body(mcu, s1, s0):
    return {
        "mcudata": (0x020000, None, [W(*mcu, 0x000000, 0x020000)]),
        "kan_spr": (0x840000, None, [
            L("mm-200-402-s0.bin", 0xc0ab3efc, 0x000000, 0x200000),
            L("mm-201-403-s1.bin", 0xcf6b23dc, 0x200000, 0x200000),
            L("mm-202-404-s2.bin", 0x8f27f5d3, 0x400000, 0x200000),
            L("mm-203-405-s3.bin", 0xe9747c8c, 0x600000, 0x080000),
            B(*s1, 0x800001, 0x020000),
            B(*s0, 0x800000, 0x020000),
        ]),
        "view2_0": (0x200000, None, [
            L("mm-300-406-a0.bin", 0xb15f6b7f, 0x000000, 0x200000)]),
        "view2_1": (0x200000, None, [C("view2_0", 0x000000, 0, 0x200000)]),
        "oki1": (0x100000, None, [
            L("mm-100-401-e0.bin", 0xb9cbfbee, 0x000000, 0x100000)]),
        "oki2": (0x100000, 0x00, []),          # ROMREGION_ERASE00, not on board
    }


def _gtmr2_body(s0, s1, oki2):
    return {
        "mcudata": (0x020000, None, [W("m2d0x0.u31", 0x2e1a06ff, 0x000000, 0x020000)]),
        "kan_spr": (0x800000, None, [
            L("m2-200-0.u49", 0x93aafc53, 0x000000, 0x400000),
            L("m2-201-0.u50", 0x39b60a83, 0x400000, 0x200000),
            L("m2-202-0.u51", 0xfd06b339, 0x600000, 0x200000),
            B(*s0, 0x700000, 0x080000),
            B(*s1, 0x700001, 0x080000),
        ]),
        "view2_0": (0x440000, None, [
            L("m2-300-0.u89", 0x4dc42fbb, 0x000000, 0x200000),
            L("m2-301-0.u90", 0xf4e894f2, 0x200000, 0x200000),
            B("m2b0x0.u93", 0xe023d51b, 0x400000, 0x020000),
            B("m2b1x0.u94", 0x03c48bdb, 0x400001, 0x020000),
        ]),
        "view2_1": (0x440000, None, [C("view2_0", 0x000000, 0, 0x440000)]),
        "oki1": (0x100000, None, [
            L("m2-100-0.u48", 0x5250fa45, 0x000000, 0x100000)]),
        "oki2": (0x080000, None, [oki2]),
    }


def _gtmre_body(mcu, s64, s65, s27, s28, s29, s30, a0, e0, e24):
    return {
        "mcudata": (0x020000, None, [W(*mcu, 0x000000, 0x020000)]),
        "kan_spr": (0x800000, None, [
            # "fill the 0x700000-7fffff range first, with the second of the
            # identical halves": the pair covers 0x600000-0x7fffff, and the
            # ROM_LOAD of s30 below then overwrites 0x600000-0x67ffff.
            B(*s64, 0x600000, 0x100000),
            B(*s65, 0x600001, 0x100000),
            L(*s27, 0x000000, 0x200000),
            L(*s28, 0x200000, 0x200000),
            L(*s29, 0x400000, 0x200000),
            L(*s30, 0x600000, 0x080000),
        ]),
        "view2_0": (0x200000, None, [L(*a0, 0x000000, 0x200000)]),
        "view2_1": (0x200000, None, [C("view2_0", 0x000000, 0, 0x200000)]),
        "oki1": (0x100000, None, [L(*e0, 0x000000, 0x100000)]),
        "oki2": (0x100000, None, [L(*e24, 0x000000, 0x100000)]),
    }


def _set(parent, table, game, maincpu, body):
    regions = {"maincpu": (0x100000, None, [B(*maincpu[0], 0x000000, 0x080000),
                                            B(*maincpu[1], 0x000001, 0x080000)])}
    regions.update(body)
    return {"parent": parent, "table": table, "game": game, "regions": regions}


SETS = {
    # 1000 Miglia (Taiwan 94/07/18). Table normal (gtmr machine config).
    "gtmr": _set(None, "normal", 0,
                 [("u2.bin", 0x031799f7), ("u1.bin", 0x6238790a)],
                 _gtmr_body(("mmd0x2.u124.bin", 0x3d7cb329),
                            ("mms1x2.u30.bin", 0xb42b426f),
                            ("mms0x2.u29.bin", 0xbd22b7d2))),
    "gtmra": _set("gtmr", "normal", None,
                  [("mmp0x2.u514.bin", 0xba4a77c8), ("mmp1x2.u513.bin", 0xa2b9034e)],
                  _gtmr_body(("mmd0x2.u124.bin", 0x3d7cb329),
                             ("mms1x2.u30.bin", 0xb42b426f),
                             ("mms0x2.u29.bin", 0xbd22b7d2))),
    "gtmrb": _set("gtmr", "normal", None,
                  [("mmp0x1.u514", 0x6c163f12), ("mmp1x1.u513", 0x424dc7e1)],
                  _gtmr_body(("mmd0x1.u124", 0x3d7cb329),
                             ("mms1x1.u30", 0x9463825c),
                             ("mms0x1.u29", 0xbd22b7d2))),
    # gtmro: sprites and tiles as 16-bit pairs of EPROMs, a different MCU ROM,
    # and an 0x800000 sprite region.
    "gtmro": _set("gtmr", "normal", None,
                  [("u514.bin", 0x2e857685), ("u513.bin", 0xd5003870)], {
        "mcudata": (0x020000, None, [W("mmd0x0.u124", 0xe1f6159e, 0x000000, 0x020000)]),
        "kan_spr": (0x800000, None, [
            B("mm200-e.bin", 0xeb104408, 0x000000, 0x100000),
            B("mm200-o.bin", 0xb6d04e7c, 0x000001, 0x100000),
            B("mm201-e.bin", 0xb8c64e14, 0x200000, 0x100000),
            B("mm201-o.bin", 0x3ecd6c0a, 0x200001, 0x100000),
            B("mm202-e.bin", 0xf0fd5688, 0x400000, 0x100000),
            B("mm202-o.bin", 0xe0fe1b2b, 0x400001, 0x100000),
            B("mm203-e.bin", 0xb9001f28, 0x600000, 0x100000),
            B("mm203-o.bin", 0x2ed6227d, 0x600001, 0x100000),
        ]),
        "view2_0": (0x200000, None, [
            B("mm300-e.u53", 0xf9ee708d, 0x000000, 0x100000),
            B("mm300-o.u54", 0x76299353, 0x000001, 0x100000),
        ]),
        "view2_1": (0x200000, None, [C("view2_0", 0x000000, 0, 0x200000)]),
        "oki1": (0x100000, None, [L("mm-100-401-e0.bin", 0xb9cbfbee, 0x000000, 0x100000)]),
        "oki2": (0x100000, 0x00, []),
    }),
    # Evolution Model (94/09/06). gtmre machine config: table ALT.
    "gtmre": _set("gtmr", "alt", 1,
                  [("gmmu2.bin", 0x36dc4aa9), ("gmmu1.bin", 0x8653c144)],
                  _gtmre_body(("gtmrusa.u12", 0x2e1a06ff),
                              ("gmmu64.bin", 0x57d77b33), ("gmmu65.bin", 0x05b8bdca),
                              ("gmmu27.bin", 0xc0ab3efc), ("gmmu28.bin", 0xcf6b23dc),
                              ("gmmu29.bin", 0x8f27f5d3), ("gmmu30.bin", 0xe9747c8c),
                              ("gmmu52.bin", 0xb15f6b7f), ("gmmu23.bin", 0xb9cbfbee),
                              ("gmmu24.bin", 0x380cdc7c))),
    "gtmrusa": _set("gtmr", "alt", 2,
                    [("mmp0x3.u2", 0x5be615c4), ("mmp1x3.u1", 0xae853e4e)],
                    _gtmre_body(("mmd0x3.u12", 0x2e1a06ff),
                                ("mm-204-564.bin", 0x57d77b33),
                                ("mm-204-406-565.bin", 0x05b8bdca),
                                ("mm-200-402-s0.bin", 0xc0ab3efc),
                                ("mm-201-403-s1.bin", 0xcf6b23dc),
                                ("mm-202-404-s2.bin", 0x8f27f5d3),
                                ("mm-203-405-s3.bin", 0xe9747c8c),
                                ("mm-300-406-a0.bin", 0xb15f6b7f),
                                ("mm-100-401-a0.bin", 0xb9cbfbee),
                                ("mm-101-402-e24.bin", 0x380cdc7c))),
    # Mille Miglia 2 (95/05/24). gtmr2 machine config: gtmr2_map, table ALT.
    # oki2 is a 0x80000 region with the 256K ROM loaded at 0x40000 — the lower
    # half is zero — where gtmr2u/gtmr2ua load a 512K ROM at 0.
    "gtmr2": _set(None, "alt", 3,
                  [("m2p0x1a.u8", 0xc29039fb), ("m2p1x1a.u7", 0x8ef392c4)],
                  _gtmr2_body(("m2s0x1a.u32", 0xa485eec6), ("m2s1x1a.u33", 0xc5b71bb2),
                              L("m2w1x0.u47", 0x1b0513c5, 0x040000, 0x040000))),
    "gtmr2a": _set("gtmr2", "alt", None,
                   [("m2p0x1.u8", 0x525f6618), ("m2p1x1.u7", 0x914683e5)],
                   _gtmr2_body(("m2s0x1.u32", 0x4069d6c7), ("m2s1x1.u33", 0xc53fe269),
                               L("m2w1x0.u47", 0x1b0513c5, 0x040000, 0x040000))),
    "gtmr2u": _set("gtmr2", "alt", 4,
                   [("m2p0a2.u8", 0x1a008ea4), ("m2p1a2.u7", 0xbbf8b43e)],
                   _gtmr2_body(("m2s0a1.u32", 0x98977171), ("m2s1a1.u33", 0xc69a732e),
                               L("m2w1a1.u47", 0x15f25342, 0x000000, 0x080000))),
    "gtmr2ua": _set("gtmr2", "alt", None,
                    [("m2p0a1.u8", 0x813e1d5e), ("m2p1a1.u7", 0xbee63666)],
                    _gtmr2_body(("m2s0a1.u32", 0x98977171), ("m2s1a1.u33", 0xc69a732e),
                                L("m2w1a1.u47", 0x15f25342, 0x000000, 0x080000))),
}
# "game" is the board's game[2:0] id; the four sets without one are not
# targets but build and verify the same way (gtmra/gtmrb/gtmro
# play as gtmr, gtmr2a/gtmr2ua as gtmr2).
REGION_ORDER = ["maincpu", "mcudata", "kan_spr", "view2_0", "view2_1", "oki1", "oki2"]


# --------------------------------------------------------------- ROM finding
class RomIndex:
    """Every ROM file under ZIPDIR, keyed by (size, crc32).

    Zips: the central directory gives both without decompressing anything.
    Loose files: only under ZIPDIR/<set>/ for the sets asked about (and their
    parents), hashed on demand — a whole Downloads folder is not read.
    """

    def __init__(self, zipdir):
        self.zipdir = zipdir
        self.entries = {}        # (size, crc) -> [(priority_key, kind, path, member)]
        self._loose_done = set()
        self._zips = []
        for name in sorted(os.listdir(zipdir)):
            path = os.path.join(zipdir, name)
            if name.lower().endswith(".zip") and os.path.isfile(path):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                stem = os.path.splitext(name)[0]
                self._zips.append(stem)
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    self.entries.setdefault((info.file_size, info.CRC), []).append(
                        (stem, "zip", path, info.filename))
                zf.close()

    def _add_loose(self, setname):
        if setname in self._loose_done:
            return
        self._loose_done.add(setname)
        d = os.path.join(self.zipdir, setname)
        if not os.path.isdir(d):
            return
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    data = fh.read()
                self.entries.setdefault((len(data), zlib.crc32(data)), []).append(
                    (setname, "file", p, None))

    def find(self, size, crc, prefer):
        for s in prefer:
            self._add_loose(s)
        cands = self.entries.get((size, crc), [])
        if not cands:
            return None
        rank = {s: i for i, s in enumerate(prefer)}
        return sorted(cands, key=lambda c: (rank.get(c[0], len(prefer)), c[0]))[0]

    def read(self, size, crc, prefer, name):
        hit = self.find(size, crc, prefer)
        if hit is None:
            raise SystemExit(f"missing ROM {name} (size {size:#x}, crc {crc:08x}) "
                             f"in {self.zipdir}: looked in every zip, preferring "
                             f"{', '.join(p + '.zip' for p in prefer)}")
        _, kind, path, member = hit
        if kind == "zip":
            with zipfile.ZipFile(path) as zf:
                data = zf.read(member)      # zipfile checks the CRC as it reads
        else:
            with open(path, "rb") as fh:
                data = fh.read()
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{name}: {path}:{member} does not match its CRC")
        return data, f"{os.path.basename(path)}:{member}" if member else path


# ------------------------------------------------------------- region build
def build_regions(setname, index, log=print):
    """MAME's regions for a set, in logical byte order, mcudata NOT decrypted."""
    spec = SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    out = {}
    for rname in REGION_ORDER:
        size, erase, ops = spec["regions"][rname]
        buf = bytearray([erase or 0]) * size
        for op in ops:
            kind = op[0]
            if kind == "C":
                _, src, so, do, n = op
                buf[do:do + n] = out[src][so:so + n]
                log(f"    {rname:<8} {do:#09x} ROM_COPY {src}+{so:#x} len {n:#x}")
                continue
            _, name, crc, off, length = op
            data, where = index.read(length, crc, prefer, name)
            if kind == "L":
                end = off + length
                if end > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:end] = data
            elif kind == "B":
                end = off + 2 * length - 1
                if end > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:end:2] = data
            elif kind == "W":
                if off & 1 or length & 1:
                    raise SystemExit(f"{setname}:{rname}: odd WORD_SWAP load")
                sw = bytearray(length)
                sw[0::2] = data[1::2]
                sw[1::2] = data[0::2]
                buf[off:off + length] = sw
            else:
                raise AssertionError(kind)
            log(f"    {rname:<8} {off:#09x} {kind} {name:<20} {crc:08x} <- {where}")
        out[rname] = bytes(buf)
    return out


def build_image(regions):
    img = bytearray(IMAGE_SIZE)
    for rname, base, maxsize in LAYOUT:
        data = regions[rname]
        if len(data) > maxsize:
            raise SystemExit(f"{rname} is {len(data):#x}, over its {maxsize:#x} slot")
        img[base:base + len(data)] = data
    return bytes(img)


# ------------------------------------------------------------------ TOYBOX
_TABLES = None


def toybox_tables(src=TOYBOX_SRC):
    """decryption_table and decryption_table_alt, parsed from MAME's source."""
    global _TABLES
    if _TABLES is None:
        if not os.path.exists(src):
            raise SystemExit(f"need {src} for the TOYBOX tables (tools/bootstrap.sh)")
        text = open(src, encoding="utf-8", errors="replace").read()
        tabs = {}
        for key, ident in (("normal", "decryption_table"), ("alt", "decryption_table_alt")):
            m = re.search(r"static const uint8_t " + ident + r"\[0x100\]\s*=\s*\{(.*?)\};",
                          text, re.S)
            if not m:
                raise SystemExit(f"{ident} not found in {src}")
            vals = [int(v, 16) for v in re.findall(r"0x[0-9a-fA-F]{2}", m.group(1))]
            if len(vals) != 256:
                raise SystemExit(f"{ident}: {len(vals)} entries, expected 256")
            tabs[key] = vals
        _TABLES = tabs
    return _TABLES


def toybox_decrypt(data, table):
    """kaneko_toybox_device::decrypt_rom: byte i += table[(i ^ 1) & 0xff]."""
    t = toybox_tables()[table]
    return bytes((b + t[(i ^ 1) & 0xff]) & 0xff for i, b in enumerate(data))


# -------------------------------------------------------------------- main
def expand_sets(arg):
    if arg == "all":
        return list(SETS)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(SETS)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="directory holding the MAME zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    ap.add_argument("--regions", action="store_true",
                    help="write <set>_<region>.bin per MAME region instead of <set>.rom")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    index = RomIndex(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    log = (lambda *x: None) if a.quiet else print
    for s in expand_sets(a.set):
        print(f"{s}: table {SETS[s]['table']}, game id {SETS[s]['game']}")
        regions = build_regions(s, index, log)
        if a.regions:
            for rname in REGION_ORDER:
                p = os.path.join(a.outdir, f"{s}_{rname}.bin")
                with open(p, "wb") as f:
                    f.write(regions[rname])
                print(f"  {p}  {len(regions[rname]):#x}")
            p = os.path.join(a.outdir, f"{s}_mcudata_decrypted.bin")
            with open(p, "wb") as f:
                f.write(toybox_decrypt(regions["mcudata"], SETS[s]["table"]))
            print(f"  {p}  {len(regions['mcudata']):#x}")
        else:
            img = build_image(regions)
            p = os.path.join(a.outdir, f"{s}.rom")
            with open(p, "wb") as f:
                f.write(img)
            print(f"  {p}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
