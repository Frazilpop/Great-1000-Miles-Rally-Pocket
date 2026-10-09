#!/usr/bin/env bash
# Build the whole-board harness. Run from the repository root.
#   sim/gtmr/build.sh [extra verilator args]
set -euo pipefail
J=third_party/jt6295/hdl
TOY=rtl/mcu/kaneko_toybox.sv
[ -n "${TOYBOX_STUB:-}" ] && TOY=build/stub/kaneko_toybox_stub.sv
mkdir -p build/obj_gtmr build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  --top-module kaneko_gtmr --Mdir "${OBJ:-build/obj_gtmr}" -o tb_gtmr \
  -CFLAGS -O2 "$@" \
  rtl/top/kaneko_gtmr.sv rtl/cpu/kaneko_gtmr_bus.sv rtl/cpu/kaneko_irq.sv \
  rtl/io/kaneko_hit.sv rtl/mem/kaneko_gtmr_vmem.sv \
  rtl/video/kaneko_video_timing.sv rtl/video/kaneko_regs16.sv \
  rtl/video/kaneko_tilerom.sv rtl/video/kaneko_tmap.sv rtl/video/kaneko_tmap_fetch.sv \
  rtl/video/kaneko_tmap_line.sv rtl/video/kaneko_kc002.sv rtl/video/kaneko_gtmr_mixer.sv \
  "$TOY" \
  third_party/fx68k/hdl/verilator/*.sv \
  $J/jt6295.v $J/jt6295_acc.v $J/jt6295_adpcm.v $J/jt6295_ctrl.v $J/jt6295_rom.v \
  $J/jt6295_serial.v $J/jt6295_sh_rst.v $J/jt6295_timing.v $J/jt12_comb.v $J/jt12_interpol.v \
  sim/gtmr/tb_gtmr.cpp
