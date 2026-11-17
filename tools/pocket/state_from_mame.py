#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A core save state carrying MAME's game state (tools/mame_gtmr_state.lua's).

   state_from_mame.py CORE.state MAMEDIR OUT.state

CORE.state is one of tb_gtmr's (--state-save), of the same set, frozen in
the idle loop with nothing pending: a calm frame such as the stage select
(the race's frames are frozen inside IRQ5's work, which runs past line 241).
Its 68000 microstate, OKIs, EEPROM, TOYBOX command words and raster place
stay; the memories, the VIEW2, sprite and hit-chip registers, the 68000's
registers and the layers' latched scroll become MAME's, and the KC-002's two
lists both MAME's sprite RAM (so only the first frames' sprites can differ).
OUT.state.tb gets MAME's frame and its place in the random numbers, for

   tb_gtmr <set>.rom <game> <frames> <out> --state-load OUT.state \\
       --plan-at <MAME's frame> --inputs <rec>/plan_tb.txt --rand-from <rec>/rand.txt

(gtmrusa, 17 Nov 2026: taken at frame 3400 of a drive played by hand, the
core then showed MAME's road in all 299 frames after, and MAME's picture.)
"""
import struct, sys

core, mdir, out = sys.argv[1:4]
b = bytearray(open(core, 'rb').read())
assert len(b) == 0x58000 and b[0:4] == b'K16S', 'not a version 1 state'

r = {}
for ln in open(f'{mdir}/regs.txt'):
    p = ln.split()
    if len(p) >= 2:
        r[p[0]] = p[1:]
h = lambda k: int(r[k][0], 16)

pc, = struct.unpack('>I', b[0xC4:0xC8])
sr, = struct.unpack('>H', b[0xC8:0xCA])
ssp, = struct.unpack('>I', b[0xC0:0xC4])
pend, = struct.unpack('>H', b[0x4A:0x4C])
idle = h('idle')
if pc != idle + 2 or sr & 0x0700 or pend or ssp != h('SP') or h('SR') != sr:
    sys.exit(f'{core} is not frozen in the idle loop as MAME is: PC {pc:06x} '
             f'(want {idle + 2:06x}), SR {sr:04x}/{h("SR"):04x}, SSP {ssp:x}/{h("SP"):x}, pending {pend}')

def put(off, data):
    b[off:off + len(data)] = data

for name, off, n in [('spr', 0x1000, 0x2000), ('v2w0', 0x4000, 0x4000), ('v2w1', 0x8000, 0x4000),
                     ('wram', 0x10000, 0x10000), ('pal', 0x20000, 0x10000),
                     ('mram', 0x30000, 0x10000), ('xram', 0x40000, 0x18000)]:
    d = open(f'{mdir}/{name}.bin', 'rb').read()
    assert len(d) == n, name
    put(off, d)
spr = open(f'{mdir}/spr.bin', 'rb').read()
put(0xC000, spr)
put(0xE000, spr)

words = lambda k: [int(w, 16) for w in r[k]]
v0, v1 = words('w600000'), words('w680000')
put(0x100, struct.pack('>8H', *v0))
put(0x110, struct.pack('>16H', *v1))
put(0x130, struct.pack('>8H', *(words('w900020') + words('w90002c'))))
put(0x140, struct.pack('>16H', *words('w700000')))
# the layers' scroll as latched at line 240, layer 0 in the bottom word
# (chip 0's registers 2 and 0, then chip 1's)
put(0x58, struct.pack('>4H', v1[0], v1[2], v0[0], v0[2]))
put(0x60, struct.pack('>4H', v1[1], v1[3], v0[1], v0[3]))
# the 68000: D0-D7, A0-A6, USP, SSP
regs = [h(f'D{i}') for i in range(8)] + [h(f'A{i}') for i in range(7)] + [h('USP'), h('SP')]
put(0x80, struct.pack('>17I', *regs))

open(out, 'wb').write(b)
open(out + '.tb', 'w').write(f'{r["frame"][0]} {r["rand"][0]}\n')
print(f'{out}: MAME\'s frame {r["frame"][0]}, random place {r["rand"][0]}')
