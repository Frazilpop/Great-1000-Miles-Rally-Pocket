#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Great 1000 Miles Rally (Pocket) — MAME's OKI M6295 in Python, standard
# library only. After World Rally (Pocket)'s, for this board's clock and banks.
"""MAME's okim6295 replayed from the game's writes, one chip.

    oki_model.py SET.rom OKI_LOG CHIP FRAMES OUT.chan OUT.ev [--wav OUT.s16]

OKI_LOG is tools/mame_gtmr_oki.lua's ("<frame> <addr> <data> <clock>", the
clock in 48 MHz ticks from power-on). The voices are MAME's (okim6295.cpp,
okiadpcm.cpp at the mamedev/mame pinned in deps.lock): a write acts at once –
a stop silences its voices, a start on a voice not playing reads the phrase
table and plays 2 * (end - start + 1) nibbles from a reset ADPCM state, a start
on a voice playing is ignored, a phrase with start >= end is refused – and each
sample (2 MHz / 165, PIN7 low) adds signal * volume / 2048 from every voice
playing. The samples are the .rom image's oki1 (0x1000000) and oki2
(0x1100000) slots, banked as init_gtmr() installs them.

OUT.chan: each voice's signal (before the volume, 0 when idle) at each sample,
four signed 16-bit words, as sim/sound/tb_gtmr_oki writes jt6295's. OUT.ev: the
same lines as the bench's out.ev, with "ignored" and "invalid" added, for
match_oki_channels.py. --wav: the chip at 0.5, scaled to 16 bits as MAME's WAV,
held to 48 kHz, signed 16-bit mono.
"""
import math
import struct
import sys

TICKS = 3960            # 48 MHz clocks a sample: 165 at 2 MHz
FRAME = 811008          # 48 MHz clocks a frame

INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]
VOLUME = [0x20, 0x16, 0x10, 0x0b, 0x08, 0x06, 0x04, 0x03, 0x02, 0, 0, 0, 0, 0, 0, 0]


def diff_lookup():
    out = []
    for step in range(49):
        sv = math.floor(16.0 * pow(11 / 10, step))
        for nib in range(16):
            s = -1 if nib & 8 else 1
            out.append(s * (sv * ((nib >> 2) & 1) + sv // 2 * ((nib >> 1) & 1)
                            + sv // 4 * (nib & 1) + sv // 8))
    return out


def main(argv):
    args, opts, i = [], {}, 1
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]; i += 2
        else:
            args.append(argv[i]); i += 1
    if len(args) < 6:
        print(__doc__)
        return 2
    chip = int(args[2])
    with open(args[0], "rb") as f:
        f.seek(0x1100000 if chip else 0x1000000)
        rom = f.read(0x100000)
    a_oki, a_bank = (0x880001, 0xe80001) if chip else (0x800001, 0xe00001)
    log = []
    for line in open(args[1]):
        fr, a, d, t = line.split()
        a = int(a, 16)
        if a in (a_oki, a_bank):
            log.append((a, int(d, 16), int(t)))
    frames = int(args[3])
    chan = open(args[4], "wb")
    ev = open(args[5], "w")
    diff = diff_lookup()

    bank = 0

    def rd(a):
        a &= 0x3ffff
        if chip:
            return rom[(bank & 1) * 0x40000 + a]
        if a < 0x30000:
            return rom[a]
        return rom[(0x30000 if bank < 3 else bank * 0x10000) + (a & 0xffff)]

    V = [dict(play=False, base=0, s=0, n=0, vol=0, sig=0, st=0) for _ in range(4)]
    cmd = -1
    n = frames * FRAME // TICKS
    out = []
    li = 0
    for k in range(n):
        t = k * TICKS
        while li < len(log) and log[li][2] <= t:
            a, d, _ = log[li]; li += 1
            if a == a_bank:
                bank = d & (1 if chip else 15)
            elif cmd != -1:
                for v in range(4):
                    if not (d >> (4 + v)) & 1:
                        continue
                    x = V[v]
                    if x["play"]:
                        ev.write(f"ignored {k} {v} {cmd:02x}\n")
                        continue
                    b = cmd * 8
                    s0 = (rd(b) << 16 | rd(b + 1) << 8 | rd(b + 2)) & 0x3ffff
                    s1 = (rd(b + 3) << 16 | rd(b + 4) << 8 | rd(b + 5)) & 0x3ffff
                    if s0 < s1:
                        x.update(play=True, base=s0, s=0, n=2 * (s1 - s0 + 1), sig=0, st=0,
                                 vol=VOLUME[d & 15])
                        ev.write(f"start {k} {v} {cmd:02x} {s0:05x} {s1:05x}\n")
                    else:
                        ev.write(f"invalid {k} {v} {cmd:02x} {s0:05x} {s1:05x}\n")
                cmd = -1
            elif d & 0x80:
                cmd = d & 0x7f
            else:
                for v in range(4):
                    if (d >> (3 + v)) & 1 and V[v]["play"]:
                        ev.write(f"cut {k} {v} {V[v]['s']}\n")
                        V[v]["play"] = False
        acc = 0.0
        cv = [0, 0, 0, 0]
        for v, x in enumerate(V):
            if not x["play"]:
                continue
            nib = rd(x["base"] + x["s"] // 2) >> (((x["s"] & 1) << 2) ^ 4) & 15
            x["sig"] = max(-2048, min(2047, x["sig"] + diff[x["st"] * 16 + nib]))
            x["st"] = max(0, min(48, x["st"] + INDEX_SHIFT[nib & 7]))
            acc += x["sig"] * x["vol"] / 0x20 / 2048
            cv[v] = x["sig"]
            x["s"] += 1
            if x["s"] >= x["n"]:
                x["play"] = False
                ev.write(f"end {k} {v} {x['s']}\n")
        chan.write(struct.pack("<4h", *cv))
        if "--wav" in opts:
            out.append(max(-32768, min(32767, int(acc * 0.5 * 32768))))
    chan.close(); ev.close()
    if "--wav" in opts:
        n48 = n * TICKS // 1000
        o48 = [out[min(n - 1, j * 1000 // TICKS)] for j in range(n48)]
        with open(opts["--wav"], "wb") as f:
            f.write(struct.pack("<%dh" % len(o48), *o48))
    print(f"{n} OKI samples ({n * TICKS / 48e6:.3f} s), {li} writes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
