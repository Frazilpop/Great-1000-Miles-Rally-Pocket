#!/usr/bin/env python3
"""For each simulated frame (PPM), find the MAME picture (PNG) it matches best.
   match_frames.py SIMDIR MAMEDIR [frames...]"""
import sys, glob, os
import numpy as np
from PIL import Image
sim, mame = sys.argv[1], sys.argv[2]
want = [int(a) for a in sys.argv[3:]]
mf = sorted(glob.glob(os.path.join(mame, 'm*.png')))
M = {int(os.path.basename(p)[1:6]): np.asarray(Image.open(p).convert('RGB'), dtype=np.int16) for p in mf}
for p in sorted(glob.glob(os.path.join(sim, 'frame_*.ppm'))):
    f = int(os.path.basename(p)[6:11])
    if want and f not in want: continue
    S = np.asarray(Image.open(p).convert('RGB'), dtype=np.int16)
    best = min(M, key=lambda k: np.count_nonzero(np.any(M[k] != S, axis=2)))
    d = np.any(M[best] != S, axis=2)
    print(f"sim {f:5d} ~ mame {best:5d}: {np.count_nonzero(d):6d} px differ of 76800")
