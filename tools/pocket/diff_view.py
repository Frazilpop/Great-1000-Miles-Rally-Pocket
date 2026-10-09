#!/usr/bin/env python3
"""diff_view.py SIM.ppm MAME.png OUT.png : sim | mame | diff (red), 2x"""
import sys
import numpy as np
from PIL import Image
S = Image.open(sys.argv[1]).convert('RGB'); M = Image.open(sys.argv[2]).convert('RGB')
a, b = np.asarray(S, dtype=np.int16), np.asarray(M, dtype=np.int16)
d = np.any(a != b, axis=2)
D = (np.asarray(M) // 3).copy(); D[d] = [255, 0, 0]
w, h = S.size
o = Image.new('RGB', (w * 3, h)); o.paste(S, (0, 0)); o.paste(M, (w, 0)); o.paste(Image.fromarray(D.astype('uint8')), (2 * w, 0))
o.resize((w * 3 * 2 // 2, h)).save(sys.argv[3])
ys, xs = np.nonzero(d)
if len(xs): print("diff bbox x %d-%d y %d-%d, %d px" % (xs.min(), xs.max(), ys.min(), ys.max(), len(xs)))
if len(xs):
    y0, x0 = ys[0], xs[0]
    print("first diff at", x0, y0, "sim", a[y0, x0], "mame", b[y0, x0])
