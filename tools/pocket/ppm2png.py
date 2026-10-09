#!/usr/bin/env python3
"""Convert P6 PPM files to PNG (stdlib only). Usage: ppm2png.py a.ppm [b.ppm ...] [--scale N]"""
import sys, zlib, struct
def read_ppm(p):
    d = open(p, 'rb').read()
    parts = d.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    return w, h, parts[4][:w * h * 3]
def write_png(p, w, h, rgb, scale=1):
    rows = []
    for y in range(h):
        row = rgb[y * w * 3:(y + 1) * w * 3]
        if scale > 1:
            row = b''.join(row[i:i + 3] * scale for i in range(0, len(row), 3))
        for _ in range(scale):
            rows.append(b'\x00' + row)
    raw = b''.join(rows)
    def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    open(p, 'wb').write(png)
args = [a for a in sys.argv[1:] if not a.startswith('--')]
scale = int(sys.argv[sys.argv.index('--scale') + 1]) if '--scale' in sys.argv else 2
for a in args:
    if a.isdigit(): continue
    w, h, rgb = read_ppm(a)
    write_png(a[:-4] + '.png', w, h, rgb, scale)
