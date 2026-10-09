#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
"""Diff a 68000 bus trace against MAME's on the gtmr board (or census one).

    python3 -I tools/pocket/diff_gtmr_trace.py ours.txt build/mame/gtmr_bus.txt gtmr
    python3 -I tools/pocket/diff_gtmr_trace.py --census build/mame/gtmr2u_bus.txt gtmr2u

The rules are tools/diff_bus_trace.py's, and its reader is used as is (same
file format; '#' marker lines are skipped). Compared in order: every write,
and every read outside the program ROM, lanes masked as there. Two things
differ on this board, which is why this is a separate front end rather than
an edit to the shared tool:

  * the program ROM is 0x000000-0x0ffffd (1 MB), not 0x000000-0x07ffff, so
    instruction fetches up to 0x0ffffd are dropped — and 0x0ffffe, the wheel
    port INSIDE that window, is kept as the data read it is;
  * the region names are gtmr_map / gtmr2_map (kaneko16.cpp), which share
    every window but 0xb00002 (P2 vs gtmr2_IN1_r) and 0xb00006 (UNK / EXTRA).
"""

import os
import sys
from collections import Counter

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import diff_bus_trace as dbt  # noqa: E402  tools/diff_bus_trace.py

ROM_END = 0x0ffffe
WHEEL = 0x0ffffe

GTMR_MAP = [
    (0x0ffffe, 0x100000, "wheel     0ffffe"),
    (0x100000, 0x110000, "work ram  100000-10ffff"),
    (0x200000, 0x210000, "mcu ram   200000-20ffff"),
    (0x2a0000, 0x2a0002, "mcu com0  2a0000"),
    (0x2b0000, 0x2b0002, "mcu com1  2b0000"),
    (0x2c0000, 0x2c0002, "mcu com2  2c0000"),
    (0x2d0000, 0x2d0002, "mcu com3  2d0000"),
    (0x300000, 0x310000, "palette   300000-30ffff"),
    (0x310000, 0x328000, "ram       310000-327fff"),
    (0x400000, 0x402000, "spriteram 400000-401fff"),
    (0x500000, 0x504000, "view2-0 v 500000-503fff"),
    (0x580000, 0x584000, "view2-1 v 580000-583fff"),
    (0x600000, 0x600010, "view2-0 r 600000-60000f"),
    (0x680000, 0x680020, "view2-1 r 680000-68001f"),
    (0x700000, 0x700020, "sprite  r 700000-70001f"),
    (0x800000, 0x800002, "oki1      800001"),
    (0x880000, 0x880002, "oki2      880001"),
    (0x900000, 0x90003a, "hit       900000-900039"),
    (0xa00000, 0xa00002, "watchdog  a00000"),
    (0xb00000, 0xb00002, "P1        b00000"),
    (0xb00002, 0xb00004, "P2        b00002"),
    (0xb00004, 0xb00006, "SYSTEM    b00004"),
    (0xb00006, 0xb00008, "UNK       b00006"),
    (0xb80000, 0xb80002, "lockout   b80000"),
    (0xc00000, 0xc00002, "disp en   c00000"),
    (0xd00000, 0xd00002, "mcu stat  d00000"),
    (0xe00000, 0xe00002, "oki1 bank e00001"),
    (0xe80000, 0xe80002, "oki2 bank e80001"),
]
GTMR2_MAP = [(lo, hi, {0xb00002: "IN1       b00002", 0xb00006: "EXTRA     b00006"}.get(lo, n))
             for lo, hi, n in GTMR_MAP]
MAP_OF = {s: GTMR_MAP for s in ("gtmr", "gtmra", "gtmrb", "gtmro", "gtmre", "gtmrusa")}
MAP_OF.update({s: GTMR2_MAP for s in ("gtmr2", "gtmr2a", "gtmr2u", "gtmr2ua")})


def region_for(setname):
    if setname not in MAP_OF:
        raise SystemExit(f"no gtmr-board map for {setname!r}; known: {', '.join(MAP_OF)}")
    windows = MAP_OF[setname]

    def region(a):
        for lo, hi, name in windows:
            if lo <= a < hi:
                return name
        if a < ROM_END:
            return "rom       000000-0ffffd"
        return f"OTHER     {a & 0xfc0000:06x}"
    return region


def keep(r):
    return r[1] == "W" or r[0] >= ROM_END


def census(path, setname):
    region = region_for(setname)
    recs = dbt.load(path)
    c = Counter((region(r[0]), r[1]) for r in recs)
    print(f"  {path}: {len(recs)} accesses, {sum(1 for r in recs if keep(r))} "
          f"after dropping instruction fetches")
    for (k, rw), v in sorted(c.items()):
        print(f"  {k:<26} {rw} {v:8d}")
    return 0


def diff(ours, mame, setname):
    region = region_for(setname)
    a_all, m_all = dbt.load(ours), dbt.load(mame)
    if not a_all or not m_all:
        print(f"empty trace: ours={len(a_all)} mame={len(m_all)}", file=sys.stderr)
        return 2
    a, m = [r for r in a_all if keep(r)], [r for r in m_all if keep(r)]
    print(f"  ours {len(a_all):7d} accesses, {len(a):7d} after dropping instruction fetches")
    print(f"  mame {len(m_all):7d} accesses, {len(m):7d} after dropping instruction fetches")
    n = min(len(a), len(m))
    first = None
    for i in range(n):
        aa, mm = a[i], m[i]
        if aa[0] != mm[0] or aa[1] != mm[1] or aa[3] != mm[3] or \
                (aa[2] & aa[3]) != (mm[2] & mm[3]):
            first = i
            break
    if first is None:
        print(f"  MATCH over all {n} compared accesses")
    else:
        print(f"\n  FIRST DIVERGENCE at compared access {first} ({region(m[first][0]).strip()})")
        print(f"  {'ours':<22} {'mame':<22}")
        for i in range(max(0, first - 6), min(n, first + 7)):
            print(f"  {dbt.fmt(a[i]):<22} {dbt.fmt(m[i]):<22} {'<<' if i == first else '  '}")
    ca = Counter(region(r[0]) for r in a_all)
    cm = Counter(region(r[0]) for r in m_all)
    print("\n  region                        ours     mame")
    for k in sorted(set(ca) | set(cm)):
        flag = "  <- one side only" if (k not in ca) != (k not in cm) else ""
        print(f"  {k:<28} {ca.get(k, 0):7d}  {cm.get(k, 0):7d}{flag}")
    return 0 if first is None else 1


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--census":
        return census(args[1], args[2])
    if len(args) == 3:
        return diff(*args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
