#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
"""Check <set>.rom byte for byte against the regions MAME itself loads.

    python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket

For each set: runs MAME with tools/mame_gtmr_regions.lua (dumps into
build/mame/regions/<set>/, skipped with --no-mame if they are already there),
then compares every slot of the .rom image with MAME's region:

  * maincpu, kan_spr, view2 (against view2_0 AND view2_1), oki1, oki2 — the
    slice [base, base + MAME's region size) must equal MAME's region exactly,
    and the rest of the slot must be zero.
  * mcudata — MAME's region is DECRYPTED in place at device_start
    (kaneko_toybox decrypt_rom, normal table for gtmr/gtmra/gtmrb/gtmro, alt
    for the rest), the .rom slice is not, so the slice is decrypted here first.
  * every byte outside the six slots must be zero.

Exit status 0 only if every set matches.
"""

import argparse
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (our own module, beside this file)

REPO = build_rom.REPO
LUA = os.path.join(REPO, "tools", "mame_gtmr_regions.lua")


def run_mame(setname, zipdir, dumpdir, mame):
    os.makedirs(dumpdir, exist_ok=True)
    work = os.path.join(REPO, "build", "mame", "work")
    env = dict(os.environ, DUMP_DIR=dumpdir)
    cmd = [mame, "-rompath", zipdir, setname,
           "-autoboot_script", LUA, "-skip_gameinfo", "-autoboot_delay", "0",
           "-video", "none", "-sound", "none", "-nothrottle", "-seconds_to_run", "60",
           "-cfg_directory", os.path.join(work, "cfg"),
           "-nvram_directory", os.path.join(work, "nvram"),
           "-snapshot_directory", os.path.join(work, "snap")]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if not os.path.exists(os.path.join(dumpdir, "regions.txt")):
        sys.stdout.write(r.stdout + r.stderr)
        raise SystemExit(f"{setname}: MAME did not dump its regions")


def first_diff(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return None
    lo, hi = 0, n            # binary search on equal prefixes
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid
    return lo if a[lo] != b[lo] else hi - 1


def count_diff(a, b):
    try:
        import numpy as np
        return int(np.count_nonzero(np.frombuffer(a, np.uint8) != np.frombuffer(b, np.uint8)))
    except ImportError:
        return sum(x != y for x, y in zip(a, b))


def verify(setname, romdir, dumpdir):
    img = open(os.path.join(romdir, f"{setname}.rom"), "rb").read()
    ok = True
    lines = []
    if len(img) != build_rom.IMAGE_SIZE:
        return False, [f"  image is {len(img):#x} bytes, expected {build_rom.IMAGE_SIZE:#x}"]
    covered = bytearray(len(img))
    table = build_rom.SETS[setname]["table"]
    for rname, base, maxsize in build_rom.LAYOUT:
        covered[base:base + maxsize] = b"\1" * maxsize
        mames = [rname] + (["view2_1"] if rname == "view2_0" else [])
        for mname in mames:
            mame = open(os.path.join(dumpdir, f"{mname}.bin"), "rb").read()
            n = len(mame)
            mine = img[base:base + n]
            note = ""
            if rname == "mcudata":
                mine = build_rom.toybox_decrypt(mine, table)
                note = f" (slice decrypted, {table} table)"
            d = first_diff(mine, mame)
            tail = img[base + n:base + maxsize]
            tail_ok = not any(tail)
            if d is None and tail_ok:
                lines.append(f"  {mname:<8} @{base:#09x}  {n:#09x} bytes  MATCH{note}"
                             + (f", slot tail {maxsize - n:#x} zero" if maxsize > n else ""))
            else:
                ok = False
                if d is not None:
                    lines.append(f"  {mname:<8} @{base:#09x}  MISMATCH{note}: "
                                 f"{count_diff(mine, mame)} bytes differ, first at +{d:#x} "
                                 f"(rom {mine[d]:02x}, mame {mame[d]:02x})")
                if not tail_ok:
                    lines.append(f"  {mname:<8} slot tail after {n:#x} is not zero")
    stray = sum(1 for i in range(0, len(img), 0x10000)
                if not covered[i] and any(img[i:i + 0x10000]))
    if stray:
        ok = False
        lines.append(f"  {stray} 64K blocks outside the slots are not zero")
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--zipdir", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--mame", default="mame")
    ap.add_argument("--no-mame", action="store_true", help="reuse existing region dumps")
    a = ap.parse_args()

    all_ok = True
    for s in build_rom.expand_sets(a.set):
        d = os.path.join(a.dumpdir, s)
        if not a.no_mame:
            run_mame(s, os.path.expanduser(a.zipdir), d, a.mame)
        ok, lines = verify(s, a.romdir, d)
        print(f"{s}: {'OK' if ok else 'FAIL'}")
        print("\n".join(lines))
        all_ok &= ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
