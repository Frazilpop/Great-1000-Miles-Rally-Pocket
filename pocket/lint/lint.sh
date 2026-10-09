#!/bin/sh
# Verilator lint of the Pocket shell against the real board, controller and
# agg23 IP, with Intel primitives stubbed (altera_stubs.v). Run from anywhere.
set -e
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fpga=$repo/pocket/src/fpga
tp=$repo/third_party/pocket-utils/ip
# The shell is linted against the stub board (same ports, outputs tied off);
# the real board is linted by its own harness while it is being written.
board=$fpga/board_stub/kaneko_gtmr_stub.sv
verilator --lint-only -Wall --top-module core_top \
  -Wno-DECLFILENAME -Wno-MULTITOP \
  "$here/lint.vlt" \
  "$here/altera_stubs.v" \
  "$fpga/apf/common.v" \
  "$fpga/core/mf_pllbase.v" "$fpga/core/mf_pllbase/mf_pllbase_0002.v" \
  "$fpga/core/pin_ddio_clk.v" \
  "$fpga/core/core_bridge_cmd.v" \
  "$tp/data_loader.sv" "$tp/sync_fifo.sv" "$tp/sound_i2s.sv" "$tp/mem/psram.sv" \
  "$repo/rtl/mem/kaneko_sdram.sv" "$repo/rtl/mem/kaneko_sdram_x2.sv" \
  "$board" \
  "$fpga/core/pocket_sync.sv" "$fpga/core/pocket_rom_loader.sv" \
  "$fpga/core/pocket_sram.sv" "$fpga/core/pocket_fb_psram.sv" \
  "$fpga/core/pocket_video.sv" "$fpga/core/pocket_diag.sv" "$fpga/core/pocket_nvram.sv" \
  "$fpga/core/core_top.v" "$@"
