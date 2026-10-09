#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko16 Pocket: list the TOYBOX commands in a capture made by
# sim/mcu/mame_toybox_capture.lua — one line per command, with the words the
# game put at 200010/12/14 and how much RAM/EEPROM the command changed.
#
#   python3 -I sim/mcu/cap_summary.py build/mcu_mame/gtmr/cap.bin
import struct
import sys
from collections import Counter


def read_caps(path):
    b = open(path, "rb").read()
    p = 0
    ram = [0] * 0x8000
    ee = [0] * 64
    out = []
    cur = None

    def diff():
        nonlocal p
        (n,) = struct.unpack_from("<I", b, p); p += 4
        ch = []
        for _ in range(n):
            w, v = struct.unpack_from("<HH", b, p); p += 4
            ram[w] = v; ch.append(w)
        (m,) = struct.unpack_from("<B", b, p); p += 1
        ech = []
        for _ in range(m):
            w, v = struct.unpack_from("<BH", b, p); p += 3
            ee[w] = v; ech.append(w)
        return ch, ech

    while p < len(b):
        t = chr(b[p]); p += 1
        if t == "W":
            p += 5
        elif t == "U":
            p += 8
        elif t == "B":
            frame, dsw = struct.unpack_from("<IH", b, p); p += 6
            diff()
            cur = dict(frame=frame, dsw=dsw, cmd=ram[8], off=ram[9], data=ram[10])
        elif t == "A":
            ch, ech = diff()
            cur["ram_changed"] = len(ch)
            cur["ee_changed"] = len(ech)
            out.append(cur)
        elif t == "E":
            break
        else:
            raise SystemExit(f"bad record {t!r} at {p - 1}")
    return out


def main():
    for path in sys.argv[1:]:
        caps = read_caps(path)
        print(f"{path}: {len(caps)} commands")
        for c in caps:
            print("  frame %5d  cmd %04x off %04x data %04x  dsw %04x  "
                  "ram words changed %5d  ee words changed %2d" %
                  (c["frame"], c["cmd"], c["off"], c["data"], c["dsw"],
                   c["ram_changed"], c["ee_changed"]))
        kinds = Counter("%02x" % (c["cmd"] >> 8) +
                        ("/%02x" % (c["data"] & 0x3f) if c["cmd"] >> 8 == 4 else "")
                        for c in caps)
        print("  by command:", ", ".join(f"{k} x{v}" for k, v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
