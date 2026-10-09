#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run one of the tools/mame_gtmr_*.lua oracle scripts on a gtmr-board set,
# reproducibly.
#
#   tools/pocket/mame_oracle.sh <script.lua> <set> [VAR=value ...] [-- mame args]
#
#   tools/pocket/mame_oracle.sh tools/mame_gtmr_dump.lua gtmr \
#       DUMP_DIR=build/mame/dump/gtmr DUMP_FRAME=600,1800
#   tools/pocket/mame_oracle.sh tools/mame_gtmr_bus_trace.lua gtmr2u \
#       BUS_TRACE_OUT=build/mame/gtmr2u_bus.txt BUS_TRACE_COUNT=200000
#
# What it fixes, every run:
#   * a FRESH, EMPTY nvram directory — MAME saves the 93C46 at exit and loads
#     it at start, so without this each run starts from the EEPROM the last one
#     left behind and two "identical" runs diverge;
#   * a fresh cfg directory, so no saved DIP or input setting leaks in;
#   * -skip_gameinfo -autoboot_delay 0: without them the script either never
#     loads (warning screen) or installs late;
#   * ROMS (default ~/Downloads) as -rompath; MAME (default mame).
# Relative paths in VAR=value are made absolute (the scripts run with MAME's
# own working directory).

set -eu
[ $# -ge 2 ] || { sed -n '3,12p' "$0"; exit 2; }
script=$1; set_name=$2; shift 2

repo=$(cd "$(dirname "$0")/../.." && pwd)
case $script in /*) ;; *) script=$PWD/$script ;; esac

while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  case $1 in
    *=/*|*=) export "$1" ;;
    *_DIR=*|*_OUT=*) k=${1%%=*}; v=${1#*=}; export "$k=$PWD/$v" ;;
    *=*) export "$1" ;;
    *) echo "mame_oracle.sh: expected VAR=value, got '$1'" >&2; exit 2 ;;
  esac
  shift
done
[ "${1:-}" = "--" ] && shift

mkdir -p "$repo/build/mame/run"
run=$(mktemp -d "$repo/build/mame/run/$set_name.XXXXXX")
trap 'rm -r "$run"' EXIT
mkdir -p "$run/cfg" "$run/nvram" "$run/snap"

start=$(date +%s)
"${MAME:-mame}" -rompath "${ROMS:-$HOME/Downloads}" "$set_name" \
  -autoboot_script "$script" -skip_gameinfo -autoboot_delay 0 \
  -video none -sound none -nothrottle -seconds_to_run 3600 \
  -cfg_directory "$run/cfg" -nvram_directory "$run/nvram" \
  -snapshot_directory "$run/snap" "$@"
echo "mame_oracle.sh: $set_name finished in $(( $(date +%s) - start )) s"
