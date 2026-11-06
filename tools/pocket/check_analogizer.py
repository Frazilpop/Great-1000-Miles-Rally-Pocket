#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hold the Analogizer's output against the board's own picture, mode by mode.

    python3 -I tools/pocket/check_analogizer.py [SET [FRAME]] [--out DIR] [-j N]

Runs build/obj_anz/tb_gtmr (sim/gtmr/build.sh --anz: the board with the
shell's pocket_analogizer and RndMnkIII's module on its raster) once per
setting, each with its own analogizer.bin made as AnalogizerConfigurator makes
it (one 32-bit word, little-endian), and reads what the cartridge pins carry,
as the adapter's DAC would take it, off the harness's anz_NNNNN.raw. Every
video run loads one save state of the board's, taken in a race (made first
if it is not there: SET from power-on through build/mame/play2/plan.txt,
saved at FRAME; default gtmr 1200), at frame 20 and goes on to frame 34, so
each sees the same picture: frame 32, against the run's own frame_00032.ppm.

  RGBS, RGsB  csync on the sync pin the mode uses (active low), the other
              pin high, the blanking pin; the picture where it is set, each
              dot four clocks, against the frame at 6 bits
  YPbPr       Y, Pb, Pr against vga_out's arithmetic on the same frame, and
              its csync, both the same clocks behind RGBS's
  Y/C         the luma against yc_out's sum, the colour burst's frequency
              on every line (3.579545 or 4.43361875 MHz), and the burst over
              and the chroma at rest before the picture starts (the reason
              the adapter has an hsync of its own: pocket_analogizer.sv)
  SC 0-75 %   the scandoubler: hsync every 768 clocks (31.25 kHz), each line
              of the picture twice at two clocks a dot, one of the two dimmed
              by the scanline factor; HQ2x (which this module has not got)
              as SC 0 %
  off         no file, and a file with the Analogizer off: the pins as the
              template's tie-offs on every clock (the harness counts them)
  Pocket off  [14] set: the Pocket's screen black, the adapter's picture on
  SNAC        SNES, NES and DB15 pads on the port, every button pressed in
              turn, under each assignment, from power-on: the two players'
              controls hold the button's bit of cont_key, the Pocket's own
              controls where SNAC does not stand in for them

Prints a line per run and exits non-zero if any check fails. Run from the
repository root; the runs take a few minutes on two cores, the save state
about twenty the first time.
"""

import os
import re
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from statistics import median

TB = "build/obj_anz/tb_gtmr"
GAME = {"gtmr": 0, "gtmre": 1, "gtmrusa": 2, "gtmr2": 3, "gtmr2u": 4}
PLAN = "build/mame/play2/plan.txt"
LINE = 1536                  # clk_anz clocks a line: 384 dots of four
HSYNC = 96                   # the adapter's hsync: 24 dots
CLK = 24e6
N = 32                       # the frame read, in the runs that load the state
LOAD_AT = 20
BIT = {"Up": 0, "Down": 1, "Left": 2, "Right": 3, "A": 4, "B": 5, "X": 6, "Y": 7,
       "L": 8, "R": 9, "Select": 14, "Start": 15}
PADS = {  # SNAC type, and each button's bit in cont_key
    "snes": (3, BIT),
    "nes": (2, BIT),
    "db15": (1, {"A": 4, "B": 5, "C": 6, "D": 7, "E": 8, "F": 9, "Up": 0, "Down": 1,
                 "Left": 2, "Right": 3, "Select": 14, "Start": 15}),
}
CONT = (0x1100, 0x2200)      # the Pocket's own controls, to tell them apart
PAD_FRAMES = 80              # 20 frames, then each button for four


def word(snac=0, on=1, assign=0, video=0, pocket_off=0):
    return snac | on << 5 | assign << 6 | video << 10 | pocket_off << 14


def pins(path):
    raw = open(path, "rb").read()
    b3, b2, b1, misc, b0 = (raw[k::5] for k in range(5))
    return {"r": [x >> 2 for x in b3], "hs": [x >> 1 & 1 for x in b3], "vs": [x & 1 for x in b3],
            "g": [x & 63 for x in b2], "blank": [x >> 6 & 1 for x in b2],
            "b": [(x & 31) << 1 | y >> 7 for x, y in zip(b1, b2)], "n": len(b3)}


def rises(x):
    return [i for i in range(1, len(x)) if x[i] and not x[i - 1]]


def falls(x):
    return [i for i in range(1, len(x)) if x[i - 1] and not x[i]]


def read_ppm(path):
    data = open(path, "rb").read()
    head = data.split(b"\n", 3)
    w, h = map(int, head[1].split())
    px = head[3]
    return [[tuple(px[(y * w + x) * 3:(y * w + x) * 3 + 3]) for x in range(w)] for y in range(h)]


def grid(p):
    """The picture's dots in an RGBS run: the first clock of each, one list
    of 320 a line, for the first picture in the capture."""
    bf, br = rises(p["blank"]), falls(p["blank"])
    br = [i for i in br if i > bf[0]]
    for a, b in zip(bf, br):
        assert b - a == 1280, f"a picture line is {b - a} clocks, not 320 dots"
    starts = [bf[0]]
    for a in bf[1:]:
        if a - starts[-1] != LINE:
            break
        starts.append(a)
    return [[s + 4 * x for x in range(320)] for s in starts]


def ypbpr(rgb):
    """vga_out's Pr, Y, Pb for one dot, 8 bits each."""
    r, g, b = rgb
    out = []
    for v in (32768 + r * 128 - g * 106 - b * 21, r * 77 + g * 150 + b * 29,
              32768 - r * 42 - g * 85 + b * 128):
        v &= (1 << 19) - 1
        out.append(0 if v >> 18 & 1 else 255 if v >> 16 & 1 else v >> 8 & 255)
    return out  # Pr on R, Y on G, Pb on B


def lag(x, ref, hi=40):
    """The clocks x runs behind ref, or None."""
    n = len(ref)
    return next((k for k in range(0, hi) if x[k:] == ref[:n - k]), None)


def best_delay(p, pos, exp, chans, lo=-4, hi=40):
    """exp[ch][y][x] against p[ch] at pos[y][x] + d: the d with fewest misses."""
    best = None
    for d in range(lo, hi):
        bad = 0
        for c, e in zip(chans, exp):
            pc = p[c]
            for row, erow in zip(pos, e):
                bad += sum(pc[i + d] != v for i, v in zip(row, erow))
        if best is None or bad < best[1]:
            best = (d, bad)
        if bad == 0:
            break
    return best


def check_15k(p, ref, mode):
    """RGBS (0), RGsB (1), YPbPr (2), Y/C (3, 4)."""
    msgs, ok = [], True
    pos, rgb8 = ref["pos"], ref["rgb8"]
    csync_ref = ref["p"]["hs"]
    if mode in (0, 1):
        sync, other = ("hs", "vs") if mode == 0 else ("vs", "hs")
        if any(v != 1 for v in p[other]):
            ok = False; msgs.append(f"{other} pin not held high")
        if p[sync] != csync_ref:
            ok = False; msgs.append("csync differs from RGBS's")
        bad = 0
        for ci, c in enumerate("rgb"):
            pc = p[c]
            for row, erow in zip(pos, rgb8):
                for i, v in zip(row, erow):
                    e = v[ci] >> 2
                    bad += (pc[i] != e) + (pc[i + 1] != e) + (pc[i + 2] != e) + (pc[i + 3] != e)
        dark = sum(1 for i in range(p["n"]) if not p["blank"][i] and (p["r"][i] | p["g"][i] | p["b"][i]))
        if bad or dark:
            ok = False
        msgs.append(f"{bad} dot clocks differ, {dark} lit clocks in blanking")
        if mode == 0:
            # the syncs on the pin: the line, the hsync's width, the picture
            # after it
            hf, hr = falls(csync_ref), rises(csync_ref)
            gaps = [b - a for a, b in zip(hf, hf[1:])]
            line = max(set(gaps), key=gaps.count)
            width = int(median([next(r for r in hr if r > f) - f for f in hf[:200]]))
            msgs.append(f"a line {line} clocks, hsync {width}, the picture {ref['porch']} after it")
            if line != LINE or width != HSYNC:
                ok = False
    elif mode == 2:
        yc = [[ypbpr(v) for v in row] for row in rgb8]
        exp = [[[d[k] >> 2 for d in row] for row in yc] for k in range(3)]
        d, bad = best_delay(p, pos, exp, "rgb")
        ds = lag(p["vs"], csync_ref)
        if bad or d != ds or any(v != 1 for v in p["hs"]):
            ok = False
        msgs.append(f"Y Pb Pr {d} clocks behind, csync {ds}; {bad} dots differ")
    else:
        y = [[((v[0] * 306 + v[1] * 601 + v[2] * 117) >> 10) >> 2 for v in row] for row in rgb8]
        d, bad = best_delay(p, pos, [y], "g")
        ds = lag(p["hs"], csync_ref)
        if bad or any(v != 1 for v in p["vs"]) or any(p["b"]):
            ok = False
        # the burst, on every line with a whole hsync: the chroma from the
        # hsync's end on the pin to where the picture starts (ref["porch"]
        # after it on RGBS's pins, moved by the luma's delay and the sync's);
        # its cycles from the first zero crossing to the last, where it
        # starts and ends, and the clocks of chroma at rest between its end
        # and the picture
        hs, chroma = p["hs"], p["r"]
        porch = ref["porch"] + d - (ds or 0)
        fr, first, last, rest = [], [], [], []
        for e in rises(hs):
            if e + porch > len(hs) or e < HSYNC + 1 or any(hs[e - HSYNC:e]) or not hs[e - HSYNC - 1]:
                continue
            c = [v - 32 for v in chroma[e:e + porch]]
            nz = [i for i, v in enumerate(c) if v]
            if len(nz) < 20:
                continue
            first.append(nz[0]); last.append(nz[-1]); rest.append(porch - 1 - nz[-1])
            x = [nz[k] for k in range(1, len(nz)) if (c[nz[k]] > 0) != (c[nz[k - 1]] > 0)]
            if len(x) > 4:
                fr.append((len(x) - 1) / 2 / ((x[-1] - x[0]) / CLK))
        f = median(fr) / 1e6 if fr else 0
        want = 4.43361875 if mode == 4 else 3.579545
        if not fr or abs(f - want) > 0.05 or not rest or min(rest) < 4:
            ok = False
        msgs.append(f"luma {d} clocks behind, csync {ds}; {bad} dots differ; burst on {len(fr)} lines, "
                    f"{f:.3f} MHz (want {want}), clocks {int(median(first)) if first else 0}-"
                    f"{int(median(last)) if last else 0} after hsync, at rest {min(rest) if rest else 0}+ "
                    f"clocks before the picture (at {porch})")
    return ok, "; ".join(msgs)


def check_sd(p, rgb8, lines):
    """The scandoubler, with scanlines 0-3 (0, 25, 50, 75 %)."""
    coeff = [64, 0x3a, 0x2e, 0x1a][lines]
    rgb6 = [[tuple(c >> 2 for c in v) for v in row] for row in rgb8]
    hs, vs = p["hs"], p["vs"]
    hr, hf = rises(hs), falls(hs)
    # its syncs keep the board's polarity: high for the pulse
    gaps = [b - a for a, b in zip(hr, hr[1:])]
    period = max(set(gaps), key=gaps.count)
    width = int(median([next(f for f in hf if f > r) - r for r in hr[:-1]]))
    vsyncs = len(rises(vs))
    # the picture's middle line on an output line, two clocks a dot, at its
    # full level
    mid = len(rgb6) // 2
    target = rgb6[mid]
    hit = None
    for li, s0 in enumerate(hr[:-1]):
        for o in range(0, period - 640 + 1):
            if all(p[ch][s0 + o + 2 * x] == target[x][k] for x in range(320) for k, ch in enumerate("rgb")):
                hit = (li, o)
                break
        if hit:
            break
    head = f"hsync every {period} clocks ({width} high), {vsyncs} vsyncs"
    if not hit:
        return False, head + f"; board line {mid} not found"
    li, o = hit
    # every line twice: the full one, and beside it the same dimmed (or not,
    # at 0 %); which side the dimmed one is on is the scandoubler's
    bads = []
    for side in (1, -1):
        bad = 0
        for y in range(len(rgb6)):
            for k, lvl in ((0, 64), (side, coeff)):
                l = li + 2 * (y - mid) + k
                if not 0 <= l < len(hr):
                    bad += 640
                    continue
                for x in range(320):
                    i = hr[l] + o + 2 * x
                    for ch in range(3):
                        e = (rgb6[y][x][ch] * lvl) >> 6
                        c = p["rgb"[ch]]
                        bad += (c[i] != e) + (c[i + 1] != e)
        bads.append(bad)
    bad = min(bads)
    return period == LINE // 2 and bad == 0, (f"{head}; {bad} dot clocks differ "
                                              f"(scanlines {[0, 25, 50, 75][lines]} %)")


def check_keys(path, pad, assign):
    _, bits = PADS[pad]
    rows = [l.strip().split(",") for l in open(path)][1:]
    bad, seen = 0, 0
    prev = None
    for fr, b1, b2, k1, k2 in rows:
        cur = (b1, b2)
        if cur != prev:            # the first frame of a press: the pads may not have been read yet
            prev = cur
            continue
        s1 = 0 if b1 == "-" else 1 << bits[b1]
        s2 = 0 if b2 == "-" else 1 << bits[b2]
        c1, c2 = CONT
        # 4 gives SNAC to players 3 and 4, which gtmr has not got; 5 gives
        # SNAC 1 and 2 to players 1 and 2
        e = {0: (s1, c2), 1: (c1, s1), 2: (s1, s2), 3: (s2, s1), 4: (c1, c2), 5: (s1, s2)}[assign]
        seen += 1
        if (int(k1, 16), int(k2, 16)) != e:
            bad += 1
    return bad == 0 and seen > 40, f"{seen} frames, {bad} with the controls wrong"


def main():
    args, out, jobs = [], None, 2
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--out":
            out = next(it)
        elif a == "-j":
            jobs = int(next(it))
        else:
            args.append(a)
    setname, sf = (args + ["gtmr", "1200"][len(args):])[:2]
    sf = int(sf)
    game = str(GAME[setname])
    out = out or f"build/anz/{setname}"
    rom = f"build/pocket/{setname}.rom"
    os.makedirs(out, exist_ok=True)
    ck = os.path.join(out, f"ck{sf}.sta")
    if not os.path.exists(ck):
        print(f"making the save state: {setname} to frame {sf}", flush=True)
        d = os.path.join(out, "ck")
        os.makedirs(d, exist_ok=True)
        subprocess.run([TB, rom, game, str(sf + 10), d, "--state-save", str(sf), ck,
                        "--inputs", PLAN, "--after", "1"], check=True, stderr=subprocess.DEVNULL)

    runs = {"rgbs": word(video=0), "rgsb": word(video=1), "ypbpr": word(video=2),
            "yc_ntsc": word(video=3), "yc_pal": word(video=4),
            "sc0": word(video=5), "sc25": word(video=6), "sc50": word(video=7), "sc75": word(video=8),
            "hq2x": word(video=9), "pocket_off": word(video=0, pocket_off=1),
            "file_off": word(on=0, video=0, snac=3), "no_file": None}
    for pad in PADS:
        for a in range(6):
            runs[f"{pad}_a{a}"] = word(snac=PADS[pad][0], assign=a)

    def run(name):
        d = os.path.join(out, name)
        os.makedirs(d, exist_ok=True)
        pad = name.split("_a")[0] if "_a" in name else None
        if pad:
            cmd = [TB, rom, game, str(PAD_FRAMES), d,
                   "--anz-pad", pad, "--anz-cont", ",".join(f"{c:x}" for c in CONT)]
        else:
            cmd = [TB, rom, game, str(N + 2), d, str(N), "--state-load", ck, "--load-at", str(LOAD_AT),
                   "--after", "0", "--inputs", PLAN, "--anz-raw", str(N)]
        if runs[name] is not None:
            open(os.path.join(d, "analogizer.bin"), "wb").write(struct.pack("<I", runs[name]))
            cmd += ["--anz-file", os.path.join(d, "analogizer.bin")]
        return subprocess.run(cmd, capture_output=True, text=True)

    with ThreadPoolExecutor(jobs) as pool:
        res = dict(zip(runs, pool.map(run, runs)))

    def anz_line(name):
        return next((l for l in res[name].stderr.splitlines() if l.startswith("analogizer:")), "?")

    fails = 0
    lg = re.search(r"let go at frame (\d+)", res["rgbs"].stderr)
    if not lg or int(lg.group(1)) > N - 3:
        print(f"the save state was not let go in time: {lg.group(0) if lg else 'never'}")
        sys.exit(1)
    raw = lambda name: os.path.join(out, name, f"anz_{N:05d}.raw")
    rp = pins(raw("rgbs"))
    pos = grid(rp)
    rgb8 = read_ppm(os.path.join(out, "rgbs", f"frame_{N:05d}.ppm"))[:len(pos)]
    hr = rises(rp["hs"])
    bf = rises(rp["blank"])
    ref = {"p": rp, "pos": pos, "rgb8": rgb8,
           "porch": bf[5] - [h for h in hr if h < bf[5]][-1]}
    colours = len({v for row in rgb8 for v in row})
    print(f"{setname}, its state of frame {sf} let go at {lg.group(1)}, frame {N}: "
          f"{len(pos)} picture lines in the capture, {colours} colours")
    if colours < 32:
        print("the picture is nearly blank: not the race")
        fails += 1
    for name in runs:
        r = res[name]
        line = anz_line(name)
        want = runs[name]
        if r.returncode != 0:
            ok, msg = False, f"harness exit {r.returncode}: {r.stderr.strip().splitlines()[-1:]}"
        elif "word taken" in line and want is not None and f"word taken {want:08x}" not in line:
            ok, msg = False, f"word not taken as written: {line}"
        elif name in ("no_file", "file_off"):
            off_bad = line.split("template's on ")[1].split(" of ")[0]
            edges = int(line.split(" of ")[1].split(" ")[0])
            ok, msg = off_bad == "0" and edges > 0, line.split("analogizer: ")[1]
        elif "_a" in name:
            pad, a = name.split("_a")
            ok, msg = check_keys(os.path.join(out, name, "anz_keys.csv"), pad, int(a))
        else:
            frame = read_ppm(os.path.join(out, name, f"frame_{N:05d}.ppm"))[:len(pos)]
            if frame != rgb8:
                ok, msg = False, "the board's picture differs from the RGBS run's"
            else:
                p = pins(raw(name))
                mode = (want >> 10) & 15
                if mode <= 4:
                    ok, msg = check_15k(p, ref, mode)
                else:
                    ok, msg = check_sd(p, rgb8, (mode - 5) if mode <= 8 else 0)
            if name == "pocket_off":
                ok = ok and "Pocket screen off" in line
                msg += "; " + ("Pocket screen off" if "Pocket screen off" in line else "POCKET SCREEN STILL ON")
            elif "Pocket screen on" not in line:
                ok = False; msg += "; Pocket screen off"
        fails += not ok
        print(f"{name:11} {'ok  ' if ok else 'FAIL'} {msg}", flush=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
