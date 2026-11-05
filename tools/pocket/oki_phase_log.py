#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Great 1000 Miles Rally (Pocket): a made-up OKI log, standard library only.
"""Start the set's real phrases at every phase of jt6295's slots.

    oki_phase_log.py SET.rom FRAMES OUT.txt

OUT.txt is in tools/mame_gtmr_oki.lua's format, for sim/sound/tb_gtmr_oki and
tools/pocket/oki_model.py. The game writes a phrase's second byte soon after
its status wait ends, which is soon after a channel's turn, so its own traffic
rarely tries a header fetch that ends on the next turn. Here the second byte
comes 4,000-8,000 clocks after the first, about a sample or more, so ten seconds
of commands is thousands of starts at every phase. Commands stay 12,000 clocks
or more apart, closer than the game's but not by much: any closer and jt6295
can't keep up in ways the game never asks of it.
"""
import random
import sys


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    with open(argv[1], "rb") as f:
        f.seek(0x1000000)
        t = f.read(1024)
    phrases = []
    for p in range(1, 128):
        s0 = t[p * 8] << 16 | t[p * 8 + 1] << 8 | t[p * 8 + 2]
        s1 = t[p * 8 + 3] << 16 | t[p * 8 + 4] << 8 | t[p * 8 + 5]
        if 0 < s0 < s1 and t[p * 8] < 4:
            phrases.append(p)
    random.seed(1)
    now, end, n = 48000000, int(argv[2]) * 811008, 0
    with open(argv[3], "w") as f:
        while now < end:
            c, p, fr = random.randrange(4), random.choice(phrases), now // 811008
            f.write(f"{fr} 800001 {(1 << c) << 3:02x} {now}\n")
            now += random.randrange(150, 600)
            f.write(f"{fr} 800001 {0x80 | p:02x} {now}\n")
            now += random.randrange(4000, 8000)
            f.write(f"{fr} 800001 {(1 << (c + 4)) | 2:02x} {now}\n")
            now += random.randrange(12000, 24000)
            n += 1
    print(n, "starts")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
