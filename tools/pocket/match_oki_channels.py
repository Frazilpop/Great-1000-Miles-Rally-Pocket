#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Great 1000 Miles Rally (Pocket) — jt6295's voices against MAME's, standard
# library only. After World Rally (Pocket)'s.
"""Compare jt6295's four voices with MAME's, phrase by phrase, value for value.

    match_oki_channels.py JT.chan JT.ev MODEL.chan MODEL.ev

JT.* are sim/sound/tb_gtmr_oki's, MODEL.* tools/pocket/oki_model.py's.

Phrases: each voice's starts are paired in order. For each pair: is the end
address as taken the table's; and if MAME played the phrase to its end, how
many samples each played, listed by the difference and by phrase. A phrase the
game stopped (cut) can't say how long it was, so its length isn't compared.

Values: each voice's non-zero values are compared in order, as sequences, with
timing taken out. After a difference the two are put back in step (up to 8
values skipped on either side, then 16 equal); each is listed with the second
it fell in and what was skipped.
"""
import collections
import struct
import sys

SAMPLE = 165 / 2e6      # seconds a sample


def read_chan(path):
    d = open(path, "rb").read()
    v = struct.unpack("<%dh" % (len(d) // 2), d)
    return [v[c::4] for c in range(4)]


def read_ev(path):
    """Per voice, the phrases: dict(k, phrase, s0, s1, how, played)."""
    voices = [[] for _ in range(4)]
    other = collections.Counter()
    refused = set()
    for line in open(path):
        p = line.split()
        if p[0] == "start":
            # MAME refuses start >= end; jt6295 plays a sample or two of it
            if int(p[4], 16) >= int(p[5], 16):
                other["start >= end"] += 1
                refused.add(int(p[2]))
                continue
            refused.discard(int(p[2]))
            voices[int(p[2])].append(dict(k=int(p[1]), phrase=int(p[3], 16), s0=int(p[4], 16),
                                          s1=int(p[5], 16), how=None, played=None))
        elif p[0] in ("end", "cut"):
            if int(p[2]) in refused:
                refused.discard(int(p[2]))
                continue
            v = voices[int(p[2])]
            if v and v[-1]["how"] is None:
                v[-1]["how"], v[-1]["played"] = p[0], int(p[3])
        else:
            other[p[0]] += 1
    return voices, other


def phrases(jt, mo):
    starts = ends = wrong = other = 0
    delta = collections.Counter()
    byphrase = collections.defaultdict(collections.Counter)
    seen = set()
    apart = []
    shown = 0

    def show(text):
        nonlocal shown
        if shown < 8:
            print("    " + text)
        shown += 1

    for c in range(4):
        if len(jt[c]) != len(mo[c]):
            apart.append((c, len(jt[c]), len(mo[c])))
        for a, b in zip(jt[c], mo[c]):
            starts += 1
            seen.add(b["phrase"])
            where = f"voice {c} {b['k'] * SAMPLE:8.3f} s phrase {b['phrase']:02x}:"
            if a["phrase"] != b["phrase"] or a["s0"] != b["s0"]:
                other += 1
                show(f"{where} played {a['phrase']:02x} {a['s0']:05x}-{a['s1']:05x}, "
                     f"the table's {b['s0']:05x}-{b['s1']:05x}")
                continue
            if a["s1"] != b["s1"]:
                wrong += 1
                show(f"{where} end taken {a['s1']:05x}, the table's {b['s1']:05x}")
            if b["how"] == "end":
                ends += 1
                d = (a["played"] - b["played"]) if a["played"] is not None else None
                delta[d] += 1
                byphrase[b["phrase"]][d] += 1
    print(f"phrases: {starts} starts of {len(seen)} different, {other} playing other addresses, "
          f"{wrong} with the wrong end taken, {ends} played to their end in MAME")
    print("  samples against MAME at those ends:", dict(sorted(delta.items(), key=lambda x: str(x[0]))))
    for p, n in sorted(byphrase.items()):
        if set(n) != {0}:
            print(f"    phrase {p:02x}: {dict(n)}")
    if apart:
        print("  voices with different numbers of starts (voice, jt6295, MAME):", apart)
    return other + wrong + sum(n for d, n in delta.items() if d)


def values(jt, mo):
    jt = [jt[(c + 1) % 4] for c in range(4)]
    total = 0
    for c in range(4):
        A = [(i, x) for i, x in enumerate(jt[c]) if x]
        B = [(i, x) for i, x in enumerate(mo[c]) if x]
        i = j = eq = 0
        diffs = []
        while i < len(A) and j < len(B):
            if A[i][1] == B[j][1]:
                eq += 1; i += 1; j += 1
                continue
            best = None
            for di in range(9):
                for dj in range(9):
                    if (di or dj) and i + di + 16 <= len(A) and j + dj + 16 <= len(B) \
                            and all(A[i + di + k][1] == B[j + dj + k][1] for k in range(16)):
                        if best is None or di + dj < sum(best):
                            best = (di, dj)
            diffs.append((B[j][0] * SAMPLE, best))
            if best is None:
                break
            i += best[0]; j += best[1]
        total += len(diffs)
        print(f"voice {c}: jt6295 {len(A)} values, MAME {len(B)}, {eq} equal, {len(diffs)} differences")
        skips = collections.Counter(d[1] for d in diffs)
        print("    skipped (jt6295's, MAME's):", dict(skips))
        for t, best in diffs[:4]:
            print(f"    {t:8.3f} s  " + ("out of step for good" if best is None else
                                         f"skipped {best[0]} of jt6295's, {best[1]} of MAME's"))
    return total


def main(argv):
    if len(argv) < 5:
        print(__doc__)
        return 2
    jt, jo = read_ev(argv[2])
    mo, mm = read_ev(argv[4])
    print("jt6295 also:", dict(jo), " MAME also:", dict(mm))
    bad = phrases(jt, mo)
    bad += values(read_chan(argv[1]), read_chan(argv[3]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
