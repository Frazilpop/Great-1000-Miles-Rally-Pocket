#!/bin/sh
# Build and run tb_shell.sv (Verilator --binary). Build tree under build/.
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fpga=$repo/pocket/src/fpga
out=$repo/build/pocket_tb
mkdir -p "$out"
verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
  --top-module tb_shell -Mdir "$out" \
  "$here/tb_shell.sv" \
  "$repo/sim/models/psram_model.sv" \
  "$fpga/core/pocket_fb_burst.sv" "$fpga/core/pocket_psram_rows.sv" \
  "$fpga/core/pocket_sram.sv" "$fpga/core/pocket_video.sv" \
  > "$out/build.log" 2>&1 || { tail -40 "$out/build.log"; exit 1; }
"$out/Vtb_shell"
