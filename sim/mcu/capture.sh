#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko16 Pocket: make the MAME side of the TOYBOX test.
#
#   sim/mcu/capture.sh [rompath] [seconds]      default ~/Downloads, 90
#
# For gtmr, gtmrusa and gtmr2u:
#   build/roms/<set>_mcudata.bin           the region, word-swapped, encrypted
#   build/mcu_mame/<set>/cap.bin           every command, RAM/EEPROM before+after
#   build/mcu_mame/<set>/mcudata_dec.bin   MAME's region after decrypt_rom()
# then `make test` (or build/obj_kaneko_toybox/kaneko_toybox) replays them.
#
# Everything here is ROM-derived and stays under build/ (hard rule 2).
#
# The game itself issues five commands, all at boot (02, 03, 04/3d, 42, 02);
# a minute of attract and a race issue none. So once boot and attract have
# been recorded untouched, the Lua script injects commands of its own five
# seconds before the end — every 04 subcommand, 02/42/03/43 and unknowns, with
# the four 0xFFFF writes in varied orders and shapes — and MAME's own mcu_run
# answers them. TBX_INJECT=0 turns that off. TBX_PLAY=1 also drops a coin and
# starts a race (it reaches no further commands on these sets, but would show
# any that a different version issued).
set -eu
ROMPATH=${1:-$HOME/Downloads}
SECS=${2:-90}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SETS=${TBX_SETS:-"gtmr gtmrusa gtmr2u"}

python3 -I "$ROOT/sim/mcu/extract_mcudata.py" "$ROMPATH" "$ROOT/build/roms" $SETS

for s in $SETS; do
    out="$ROOT/build/mcu_mame/$s"
    # A fresh directory per run, never a cleaned one: MAME keeps the EEPROM in
    # nvram/ under its working directory, and a formatted EEPROM takes the game
    # down a different path at boot. Old runs are moved aside, not deleted.
    if [ -e "$out" ]; then mv "$out" "$out.old.$$"; fi
    mkdir -p "$out/run"
    ( cd "$out/run" && TBX_OUT="$out" TBX_INJECT="${TBX_INJECT:-1}" \
        TBX_INJECT_AT=$(( (SECS - 5) * 60 )) mame -rompath "$ROMPATH" "$s" \
        -autoboot_script "$ROOT/sim/mcu/mame_toybox_capture.lua" \
        -skip_gameinfo -autoboot_delay 0 -video none -sound none \
        -nothrottle -seconds_to_run "$SECS" 2>&1 | grep "toybox" ) \
      || { echo "capture failed for $s"; exit 1; }
    python3 -I "$ROOT/sim/mcu/cap_summary.py" "$out/cap.bin"
done
