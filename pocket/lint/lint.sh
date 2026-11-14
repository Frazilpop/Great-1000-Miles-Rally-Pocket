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
# The Analogizer's scandoubler.v selects zero bits in a colour-depth branch
# it never takes here, which Quartus passes over and Verilator refuses: the
# lint reads a copy with the width held at one, as sim/gtmr/build.sh does.
mkdir -p "$repo/build/tmp/anz"
anz_sd=$repo/build/tmp/anz/scandoubler_lint.v
sed 's/ -:n\]/ -:(n>0?n:1)]/g' "$fpga/analogizer/scandoubler.v" > "$anz_sd"
verilator --lint-only -Wall --top-module core_top \
  -Wno-DECLFILENAME -Wno-MULTITOP \
  "$here/lint.vlt" \
  "$here/altera_stubs.v" \
  "$fpga/apf/common.v" \
  "$fpga/core/mf_pllbase.v" "$fpga/core/mf_pllbase/mf_pllbase_0002.v" \
  "$fpga/core/pin_ddio_clk.v" \
  "$fpga/core/core_bridge_cmd.v" \
  "$tp/data_loader.sv" "$tp/sync_fifo.sv" "$tp/sound_i2s.sv" \
  "$repo/rtl/mem/kaneko_sdram.sv" "$repo/rtl/mem/kaneko_sdram_x2.sv" \
  "$board" \
  "$fpga/core/pocket_sync.sv" "$fpga/core/pocket_rom_loader.sv" \
  "$fpga/core/pocket_sram.sv" "$fpga/core/pocket_fb_burst.sv" "$fpga/core/pocket_psram_rows.sv" \
  "$fpga/core/pocket_video.sv" "$fpga/core/pocket_diag.sv" "$fpga/core/pocket_nvram.sv" "$fpga/core/pocket_state.sv" \
  "$fpga/core/pocket_analogizer.sv" $(ls "$fpga"/analogizer/*.v "$fpga"/analogizer/*.sv | grep -v scandoubler.v) \
  "$anz_sd" \
  "$fpga/core/core_top.v" "$@"
