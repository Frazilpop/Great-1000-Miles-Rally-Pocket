#!/usr/bin/env bash
# Build the gtmr OKI replay bench. Run from the repository root.
#   sim/sound/build_gtmr_oki.sh [extra verilator args]
# JT6295 points at another copy of jt6295's hdl/ (default the patched clone),
# OBJ at another build folder (default build/obj_gtmr_oki). jt6295's own
# SIMULATION block writes jt6295.raw where the bench runs.
set -euo pipefail
J="${JT6295:-third_party/jt6295/hdl}"
OBJ="${OBJ:-build/obj_gtmr_oki}"
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -DSIMULATION \
  --top-module kaneko_gtmr_oki --Mdir "$OBJ" -o tb_gtmr_oki -CFLAGS -O2 "$@" \
  sim/sound/kaneko_gtmr_oki.sv rtl/video/kaneko_tilerom.sv \
  $J/jt6295.v $J/jt6295_acc.v $J/jt6295_adpcm.v $J/jt6295_ctrl.v $J/jt6295_rom.v \
  $J/jt6295_serial.v $J/jt6295_sh_rst.v $J/jt6295_timing.v $J/jt12_comb.v $J/jt12_interpol.v \
  sim/sound/tb_gtmr_oki.cpp
