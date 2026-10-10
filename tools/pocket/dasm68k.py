#!/usr/bin/env python3
"""Disassemble a range of the 68000 program in a Pocket ROM image.

    python3 -I tools/pocket/dasm68k.py build/pocket/gtmr.rom 0xcd00 0xd400

The image's first 1 MB is the maincpu region in MAME's byte order (big
endian), so the words are read as they are. Needs capstone (pip install
--user capstone); the user site is added by hand because -I drops it.
"""
import site, sys
sys.path.append(site.getusersitepackages())
import capstone

def main():
    path, start, end = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
    with open(path, "rb") as f:
        f.seek(start)
        code = f.read(end - start)
    md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
    md.skipdata = True
    for i in md.disasm(code, start):
        words = " ".join("%02x%02x" % (i.bytes[k], i.bytes[k + 1]) for k in range(0, len(i.bytes), 2))
        print("%06x  %-24s %s %s" % (i.address, words, i.mnemonic, i.op_str))

if __name__ == "__main__":
    main()
