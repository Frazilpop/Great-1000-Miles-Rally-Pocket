#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# A save state in the board harness: the run that saved against a fresh run
# that loaded its file, from the clock each lets go.
#
#   tools/pocket/state_test.sh <set> <frame> [--plan plan.txt] [--after N]
#                              [--resave] [--sdram-serial N] [--pocket]
#                              [--anz FILE] [--out DIR]
#
# <set> is a ROM image's name in build/pocket (gtmr, gtmre, gtmrusa, gtmr2,
# gtmr2u). The saving run asks for a clean point at <frame>, reads the state
# out and goes on N frames (default 300); the loaded run writes it in at its
# frame 20 and runs the same N. Both write after.txt, one line a frame from
# the let-go: the picture's CRC, and the sound's over every clock. They must
# be the same, every line. With --resave the loaded run also reads the state
# back before it lets go, and that file must be the saved one bar the frame
# number (bytes 0x1C-0x1F). The plan's inputs follow the saving run's frames.
# --pocket makes both through pocket_state.sv as the Pocket drives it, the
# load under the Pocket's reset (tb_gtmr's --pocket, --pocket-reset).
# --anz FILE runs both with the Analogizer beside the board, set by FILE (an
# analogizer.bin), the controls through it: sim/gtmr/build.sh --anz's harness,
# so OBJ defaults to build/obj_anz.
# Needs sim/gtmr/build.sh's harness (OBJ, default build/obj_gtmr).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo"
[ $# -ge 2 ] || { sed -n '3,20p' "$0"; exit 2; }
set_name=$1; frame=$2; shift 2
plan=""; after=300; resave=0; serial=""; out=""; pk=""; pkl=""; anz=""
while [ $# -gt 0 ]; do
    case $1 in
        --plan) plan=$2; shift 2 ;;
        --after) after=$2; shift 2 ;;
        --resave) resave=1; shift ;;
        --sdram-serial) serial="--sdram-serial $2"; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --pocket) pk="--pocket"; pkl="--pocket --pocket-reset"; shift ;;
        --anz) anz="--anz-file $2"; shift 2 ;;
        *) echo "state_test.sh: unknown $1" >&2; exit 2 ;;
    esac
done
case $set_name in
    gtmr) game=0 ;; gtmre) game=1 ;; gtmrusa) game=2 ;; gtmr2) game=3 ;; gtmr2u) game=4 ;;
    *) echo "state_test.sh: no game id for $set_name" >&2; exit 2 ;;
esac
if [ -n "$anz" ]; then tb=${OBJ:-build/obj_anz}/tb_gtmr; else tb=${OBJ:-build/obj_gtmr}/tb_gtmr; fi
rom=build/pocket/$set_name.rom
[ -x "$tb" ] && [ -f "$rom" ] || { echo "state_test.sh: need $tb and $rom" >&2; exit 1; }
out=${out:-build/state/$set_name-$frame}
rm -rf "$out"; mkdir -p "$out"
inputs=""; [ -n "$plan" ] && inputs="--inputs $plan"

# shellcheck disable=SC2086
"$tb" "$rom" $game $((frame + after + 40)) "$out/save" --state-save "$frame" "$out/state.sta" \
    --after "$after" $inputs $serial $pk $anz 2>&1 | grep -v '^frame ' > "$out/save.log"
re=""; [ $resave = 1 ] && re="--resave $out/resave.sta"
# shellcheck disable=SC2086
"$tb" "$rom" $game 100000 "$out/load" --state-load "$out/state.sta" --load-at 20 \
    --after "$after" $re $inputs $serial $pkl $anz 2>&1 | grep -v '^frame ' > "$out/load.log"

grep '^state:' "$out/save.log" | sed 's/^/saved:  /'
grep '^state:' "$out/load.log" | sed 's/^/loaded: /'
a=$out/save/after.txt; b=$out/load/after.txt
na=$(wc -l < "$a" | tr -d ' '); nb=$(wc -l < "$b" | tr -d ' ')
same=$(paste -d'|' "$a" "$b" | awk -F'|' '$1 == $2 { n++ } $1 != $2 { exit } END { print n + 0 }')
ok=1
if [ "$na" -eq "$nb" ] && [ "$same" -eq "$na" ] && [ "$na" -ge "$after" ]; then
    echo "after the let-go: $na frames, every picture and every clock of sound the same"
else
    echo "after the let-go: the same for $same frames of $na saved and $nb loaded"; ok=0
    paste -d'|' "$a" "$b" | awk -F'|' -v s="$same" 'NR > s && NR <= s + 3 { print "  saved " $1 "  loaded " $2 }'
fi
if [ $resave = 1 ]; then
    if cmp -s <(head -c 28 "$out/state.sta") <(head -c 28 "$out/resave.sta") &&
       cmp -s <(tail -c +33 "$out/state.sta") <(tail -c +33 "$out/resave.sta"); then
        echo "read straight back: the same file, bar the frame number"
    else
        echo "read straight back: DIFFERS"; ok=0
        cmp -l "$out/state.sta" "$out/resave.sta" | head -5 | sed 's/^/  /'
    fi
fi
[ $ok = 1 ] && echo PASS || { echo FAIL; exit 1; }
