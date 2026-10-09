#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Draw the Pocket's two graphics for this core, in APF's raw format.

  dist/Cores/frazilpop.Kaneko16/icon.bin   36 x 36, "K16"
  dist/Platforms/_images/kaneko16.bin      521 x 165, "KANEKO 16" + subtitle

Format (Analogue: Packaging a Core, Graphical Asset Formats): 16 bits per
pixel, brightness in the upper byte, stored rotated 90 degrees
counter-clockwise. Analogue's own template icon (third_party/pocket-template,
dist/icon.bin) settles the two details the page leaves open, and is copied:
words are big-endian (0xFF00 = bytes FF 00), and the background is ON with
the drawing OFF. The OS recolours the image either way round.

Run from anywhere: python3 pocket/tools/make_images.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, "..", "dist")

# 5x7 glyphs, one string per row, '#' = ink. Only the letters used.
FONT = {
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    " ": ["....."] * 7,
}


def text_width(s, scale):
    return (len(s) * 6 - 1) * scale


def draw_text(canvas, s, x0, y0, scale):
    for i, ch in enumerate(s):
        glyph = FONT[ch]
        for gy, row in enumerate(glyph):
            for gx, c in enumerate(row):
                if c != "#":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        canvas[y0 + gy * scale + dy][x0 + (i * 6 + gx) * scale + dx] = 1


def save(canvas, path):
    """Rotate 90 degrees counter-clockwise and write 16-bit big-endian words."""
    h, w = len(canvas), len(canvas[0])
    out = bytearray()
    for r in range(w):                 # stored row r = original column w-1-r
        x = w - 1 - r
        for y in range(h):             # stored column = original row
            ink = canvas[y][x]
            out += b"\x00\x00" if ink else b"\xff\x00"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)
    print(f"{path}: {w}x{h}, {len(out)} bytes")


def main():
    # Core icon: 36 x 36, drawn at the 2x2 pixel scale Analogue recommends.
    icon = [[0] * 36 for _ in range(36)]
    s, sc = "K16", 2
    draw_text(icon, s, (36 - text_width(s, sc)) // 2, (36 - 7 * sc) // 2, sc)
    save(icon, os.path.join(DIST, "Cores", "frazilpop.Kaneko16", "icon.bin"))

    # Platform image: 521 x 165.
    W, H = 521, 165
    img = [[0] * W for _ in range(H)]
    t1, s1 = "KANEKO 16", 8
    t2, s2 = "GREAT 1000 MILES RALLY", 3
    h1, h2, gap = 7 * s1, 7 * s2, 18
    top = (H - (h1 + gap + h2)) // 2
    draw_text(img, t1, (W - text_width(t1, s1)) // 2, top, s1)
    draw_text(img, t2, (W - text_width(t2, s2)) // 2, top + h1 + gap, s2)
    save(img, os.path.join(DIST, "Platforms", "_images", "kaneko16.bin"))


if __name__ == "__main__":
    main()
