# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because fx68k is (see below). This
file lists each dependency and what its licence asks for.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-only | The 68000 main CPU |
| [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3.0-or-later | The two OKI M6295 sound chips |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, I2S audio, sync FIFO |
| [mamedev/mame](https://github.com/mamedev/mame) (`src/mame/kaneko/` only) | BSD-3-Clause (those files) | The reference, and the TOYBOX tables read at run time |

### fx68k – GPL-3.0-only
`deps.lock` pins `jtfpga/fx68k`, which is ijor's code repackaged for jtframe –
`hdl/fx68k.sv` is identical apart from line endings. One local patch,
`tools/patches/fx68k-state.patch`, is applied by the bootstrap: ports for save
states, which stop the 68000 at an instruction boundary and read and load its
registers. Synthesis and simulation both take the patched `hdl/`; the
simulation compiles a copy with the nanocode struct packed, which Verilator
needs. The bootstrap symlinks `microrom.mem` and `nanorom.mem` into the repo
root, where fx68k loads them from.

### jt6295 – GPL-3.0-or-later
Five local patches in `tools/patches/`, applied by the bootstrap in turn (the
build checks they are there):

- `jt6295-busy-on-commit.patch` – the busy flags only change on the tick that
  commits a STOP or START, as in MAME. Without it Great 1000 Miles Rally loses
  STOPs and the 68000 spins on the status after a crash.
- `jt6295-end-byte.patch` – a phrase plays both nibbles of its last byte, as
  MAME's okim6295 does; it used to end one sample short.
- `jt6295-start-on-end-byte.patch` – a voice starts only once the whole of its
  end address has been read, so a slow ROM can't cut a phrase short.
- `jt6295-keep-stops.patch` – a second STOP or a phrase byte no longer wipes a
  pending STOP, so a voice the game stops stays stopped.
- `jt6295-state.patch` – a scan chain through each chip's state, for save
  states.

The or-later clause is in each
`hdl/` file header, and the header counts, not `LICENSE` – re-read it after
every `bootstrap.sh --update`.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. Keep the notice.

### MAME – BSD-3-Clause (these files only)
Everything in `src/mame/kaneko/` is BSD-3-Clause, © Luca Elia, David Haywood
and Sebastien Volpe – `kaneko16.cpp` (board, clocks, memory map),
`kaneko_tmap`, `kaneko_spr` and `kaneko_toybox`. It is the only public
documentation of these chips. `rtl/mcu/kaneko_toybox.sv` and
`rtl/video/kaneko_tmap.sv` are transcribed from it and keep the notice in
their own headers. `tools/pocket/build_rom.py --regions` reads the TOYBOX
decryption tables from `kaneko_toybox.cpp` at run time rather than copying
them in.

MAME as a whole is GPL-2.0, and `src/devices/` and `src/emu/` are a mix, so
check each file's header before transcribing anything else.

## In the tree

### alphanu1/kaneko16-mister – GPL-3.0-or-later
The MiSTer core this is built on, imported at `f175e50`: the files whose
headers carry alphanu1's copyright – the SDRAM controller and its model, the
VIEW2 tilemaps and video timing, the 16-bit register blocks, the interrupt
controller, the OKI banking, the hit chip, the per-module tests and the
tools that grew from upstream's. The SDRAM controller follows meathax's
System 32 controller (GPL-3.0) – keep that note in the file.

### RndMnkIII's Analogizer module – MIT, with GPL parts
`pocket/src/fpga/analogizer/` is the adapter module of RndMnkIII's
[Analogizer](https://github.com/RndMnkIII/Analogizer) (`analogizer/` at
`4b35f83`, © 2024 RndMnkIII, MIT), only the files it uses, as
`analogizer.qip` lists them. Three of them carry their own licences:
`yc_out.sv` (Mike Simone, GPL-2.0-or-later), `scandoubler.v` (Till Harbaum,
from MiST, GPL-3.0-or-later) and `vga_out_sw.v` (MiSTer's `vga_out`, by
Sorgelig, GPL). Two changes are made, marked in the files: the
scandoubler's pixel clock divider set for this board, and the PlayStation
pad reader left out – its `dualshock_controller.v` is free for
non-commercial use only, which the GPL does not allow.

### Analogue openFPGA core template – Analogue's APF Software License Agreement
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`mf_pllbase`, `pin_ddio_clk`,
`mf_datatable`, `mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/`, `sim/`, `tools/` and `pocket/`, under the
licence in each file's header (GPL-3.0-only or GPL-3.0-or-later; the
combination is GPL-3.0-only).

`pocket/art/kaneko16-banner.png`, the platform image, is made from the game's
logo, © Kaneko.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.
