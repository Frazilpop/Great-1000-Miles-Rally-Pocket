#!/usr/bin/env bash
# Build the three-OKI save-state bench. Run from the repository root.
#   sim/sound/build_oki_state3.sh [extra verilator args]
set -euo pipefail
J="${JT6295:-third_party/jt6295/hdl}"
OBJ="${OBJ:-build/obj_oki_state3}"
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -DSIMULATION \
  --top-module kaneko_oki_state3 --Mdir "$OBJ" -o tb_oki_state3 -CFLAGS -O2 "$@" \
  sim/sound/kaneko_oki_state3.sv sim/sound/kaneko_gtmr_oki.sv rtl/video/kaneko_tilerom.sv \
  $J/jt6295.v $J/jt6295_acc.v $J/jt6295_adpcm.v $J/jt6295_ctrl.v $J/jt6295_rom.v \
  $J/jt6295_serial.v $J/jt6295_sh_rst.v $J/jt6295_timing.v $J/jt12_comb.v $J/jt12_interpol.v \
  sim/sound/tb_oki_state3.cpp
