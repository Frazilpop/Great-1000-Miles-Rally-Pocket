#!/usr/bin/env bash
# Build the whole-board harness. Run from the repository root.
#   sim/gtmr/build.sh [--anz] [extra verilator args]
# --anz (first) builds it with the shell's pocket_analogizer and RndMnkIII's
# module (pocket/src/fpga/analogizer/) on the board's raster, as a model of
# its own (sim/gtmr/anz_top.sv), into build/obj_anz/: tb_gtmr's --anz-*
# options, for tools/pocket/check_analogizer.py.
set -euo pipefail
J=third_party/jt6295/hdl
TOY=rtl/mcu/kaneko_toybox.sv
[ -n "${TOYBOX_STUB:-}" ] && TOY=build/stub/kaneko_toybox_stub.sv
anz=0
if [ "${1:-}" = "--anz" ]; then anz=1; shift; fi
mkdir -p build/tmp build/fx68k
export TMPDIR="$PWD/build/tmp"
# fx68k: hdl/, the very text Quartus builds (board.qip). Verilator wants its
# nanocode struct packed, so a copy with that one change goes into build/;
# --noassert because the ALU's `unique case` is not full in every state.
F=third_party/fx68k/hdl
sed 's/^typedef struct {/typedef struct packed {/' "$F/fx68k.sv" > build/fx68k/fx68k.sv
# pocket_state.sv, the Pocket's side of the save states, as a model of its
# own for --pocket: its two clocks are driven apart from the board's.
if [ $anz = 1 ]; then O="${OBJ:-build/obj_anz}"; else O="${OBJ:-build/obj_gtmr}"; fi
mkdir -p "$O"
verilator --cc --build -j 0 -O2 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style --prefix Vbridge --top-module pocket_state -Mdir "$O/bridge" \
  -CFLAGS -O2 pocket/src/fpga/core/pocket_state.sv third_party/pocket-utils/ip/data_loader.sv \
  sim/gtmr/dcfifo.sv pocket/src/fpga/apf/common.v > "$O/bridge.log" 2>&1 ||
  { grep -E '%Error' "$O/bridge.log" | head -20; exit 1; }
LIBS="$PWD/$O/bridge/Vbridge__ALL.a"
INC="-I$PWD/$O/bridge"
DEFS=""
if [ $anz = 1 ]; then
  A=pocket/src/fpga/analogizer
  T=build/tmp/anz
  mkdir -p "$T"
  # scandoubler.v's colour-depth branch for a remainder it never has here
  # selects zero bits, which Quartus passes over and Verilator refuses: the
  # harness compiles a copy with the width held at one
  sed 's/ -:n\]/ -:(n>0?n:1)]/g' "$A/scandoubler.v" > "$T/scandoubler_sim.v"
  # serlatch_gc.v reads a seventeenth bit from NES and SNES pads into bit 16
  # of a 16-bit register: a write that does nothing (IEEE 1800 11.5.1, and
  # Quartus), which Verilator wraps onto bit 0, the pads' first button
  sed 's/^\( *\)\(p[12]b_r\[((counter>>1)-1)\] <= i_dat[12];\)/\1if (((counter>>1)-1) < 6'"'"'d16) \2/' \
    "$A/serlatch_gc.v" > "$T/serlatch_gc_sim.v"
  verilator --cc --build -j 0 -O2 --x-assign fast --x-initial 0 \
    -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
    --prefix Vanz --top-module anz_top -Mdir "$O/anz" -CFLAGS -O2 \
    sim/gtmr/anz_top.sv pocket/src/fpga/core/pocket_sync.sv pocket/src/fpga/core/pocket_analogizer.sv \
    $(ls "$A"/*.v "$A"/*.sv | grep -v -e scandoubler.v -e serlatch_gc.v) \
    "$T/scandoubler_sim.v" "$T/serlatch_gc_sim.v" > "$O/anz.log" 2>&1 ||
    { grep -E '%Error' "$O/anz.log" | head -20; exit 1; }
  LIBS="$LIBS $PWD/$O/anz/Vanz__ALL.a"
  INC="$INC -I$PWD/$O/anz"
  DEFS="-DANALOGIZER"
fi
# (Verilator's make doesn't relink for a library passed in -LDFLAGS)
for l in $LIBS; do [ "$l" -nt "$O/tb_gtmr" ] && rm -f "$O/tb_gtmr"; done
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 --noassert \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  --top-module kaneko_gtmr --Mdir "$O" -o tb_gtmr \
  -CFLAGS "-O2 $INC $DEFS" -LDFLAGS "$LIBS" "$@" \
  rtl/top/kaneko_gtmr.sv rtl/top/kaneko_state.sv rtl/cpu/kaneko_gtmr_bus.sv rtl/cpu/kaneko_irq.sv \
  rtl/io/kaneko_hit.sv rtl/mem/kaneko_gtmr_vmem.sv \
  rtl/video/kaneko_video_timing.sv rtl/video/kaneko_regs16.sv \
  rtl/video/kaneko_tilerom.sv rtl/video/kaneko_tmap.sv rtl/video/kaneko_tmap_fetch.sv \
  rtl/video/kaneko_tmap_line.sv rtl/video/kaneko_kc002.sv rtl/video/kaneko_gtmr_mixer.sv \
  "$TOY" \
  build/fx68k/fx68k.sv "$F/fx68kAlu.sv" "$F/uaddrPla.sv" \
  $J/jt6295.v $J/jt6295_acc.v $J/jt6295_adpcm.v $J/jt6295_ctrl.v $J/jt6295_rom.v \
  $J/jt6295_serial.v $J/jt6295_sh_rst.v $J/jt6295_timing.v $J/jt12_comb.v $J/jt12_interpol.v \
  sim/gtmr/tb_gtmr.cpp
