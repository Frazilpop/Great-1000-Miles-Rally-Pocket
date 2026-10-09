#!/bin/sh
# Kaneko16 for Analogue Pocket — build the bitstream.
#
#   pocket/build.sh            the real board (pocket/src/fpga/board.qip)
#   pocket/build.sh --stub     the stub board (board_stub/): the shell alone
#   pocket/build.sh --clean    empty db/ and incremental_db/ first, so smart
#                              recompilation cannot skip a stage (with either)
#
# Runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1, linux/amd64),
# here under Colima with Rosetta. The WHOLE repository is mounted, because the
# project in pocket/src/fpga reaches ../../../rtl and ../../../third_party.
# Colima shares $HOME only — a checkout under /tmp would mount as empty.
#
# Generated files stay under build/ (the repo's rule): db/, incremental_db/
# and output_files/ in the project directory are symlinks into
# build/pocket/quartus/, made here on first use. The one exception is Analogue's
# own pre-flow script, which rewrites apf/build_id.mif with the build date.
#
# Afterwards: the bit-reversed bitstream the Pocket loads is written to
# pocket/dist/Cores/frazilpop.Kaneko16/bitstream.rbf_r — or, for --stub, to
# build/pocket/quartus/bitstream_stub.rbf_r, because the stub board is a
# traffic generator and must never be packaged — and the fit and the worst
# slack per clock are printed. The script fails if any clock has negative
# slack.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
fpga=$repo/pocket/src/fpga
qb=$repo/build/pocket/quartus
dist=$repo/pocket/dist/Cores/frazilpop.Kaneko16
image=raetro/quartus:21.1

board=real
clean=0
for arg in "$@"; do
    case "$arg" in
        --stub) board=stub ;;
        --clean) clean=1 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

case "$repo" in
    "$HOME"/*) ;;
    *) echo "build.sh: the repository must be under \$HOME ($HOME); Colima shares nothing else." >&2
       exit 1 ;;
esac

for f in "$repo/third_party/pocket-utils/ip/data_loader.sv" "$repo/rtl/mem/kaneko_sdram.sv"; do
    [ -f "$f" ] || { echo "build.sh: missing $f (run tools/bootstrap.sh?)" >&2; exit 1; }
done

# ------------------------------------------------------------ one at a time
# Two Quartus runs in one project write the same db/ and the same log, and
# neither finishes cleanly. The DCMSX Mille Miglia tile and a chat can both
# start this script, so it takes a lock (mkdir is atomic) and refuses while
# another build holds it. A lock left by a killed build is cleared once its
# pid is gone.
lock=$repo/build/pocket/build.lock
mkdir -p "$repo/build/pocket"
if ! mkdir "$lock" 2>/dev/null; then
    other=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "build.sh: another build is running (pid $other); not starting a second." >&2
        exit 1
    fi
    rm -rf "$lock"; mkdir "$lock"
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM

# ---------------------------------------------------- generated -> build/
mkdir -p "$qb/db" "$qb/incremental_db" "$qb/output_files"
for d in db incremental_db output_files; do
    if [ -L "$fpga/$d" ]; then
        :
    elif [ -e "$fpga/$d" ]; then
        echo "build.sh: $fpga/$d is a real directory; move it aside so it can be a link into build/." >&2
        exit 1
    else
        # Relative, so it resolves the same inside the container (/build/...).
        ln -s "../../../build/pocket/quartus/$d" "$fpga/$d"
    fi
done

if [ "$clean" = 1 ]; then
    echo "== clean: emptying $qb/db and $qb/incremental_db"
    find "$qb/db" "$qb/incremental_db" -mindepth 1 -delete
fi

log=$qb/compile.log
echo "== Quartus 21.1 ($image), board: $board"
echo "   log: $log"
start=$(date +%s)
if ! docker run --rm --platform linux/amd64 \
        -v "$repo":/build -w /build/pocket/src/fpga \
        -e KANEKO16_BOARD="$board" \
        "$image" quartus_sh --flow compile ap_core > "$log" 2>&1; then
    echo "== COMPILE FAILED"
    grep -E "^Error|^ *Error \(" "$log" | head -40
    exit 1
fi
echo "   compiled in $(( $(date +%s) - start )) s"

# Critical warnings are worth a look every time; they are where a wrong pin or
# an ignored constraint shows up.
crit=$(grep -c "^Critical Warning" "$log" || true)
if [ "$crit" != "0" ]; then
    echo "== $crit critical warning(s):"
    grep "^Critical Warning" "$log" | sort -u | head -20
fi

# ------------------------------------------------------------- bitstream
rbf=$qb/output_files/ap_core.rbf
[ -f "$rbf" ] || { echo "build.sh: no $rbf" >&2; exit 1; }
if [ "$board" = stub ]; then
    rbf_r=$qb/bitstream_stub.rbf_r
else
    mkdir -p "$dist"
    rbf_r=$dist/bitstream.rbf_r
fi
python3 -I - "$rbf" "$rbf_r" <<'EOF'
import sys
# APF wants every byte of the .rbf bit-reversed (Analogue: Packaging a Core).
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(src, "rb").read()
open(dst, "wb").write(data.translate(table))
print(f"== bitstream: {dst} ({len(data)} bytes)")
EOF

# ------------------------------------------------------------- reports
python3 -I - "$qb/output_files" "$board" <<'EOF'
import os, re, sys
out, board = sys.argv[1], sys.argv[2]

fit = open(os.path.join(out, "ap_core.fit.summary")).read()
print("== fit (5CEBA4F23C8)" + ("  [STUB BOARD: shell only]" if board == "stub" else ""))
for key in ("Logic utilization (in ALMs)", "Total registers", "Total pins",
            "Total block memory bits", "Total RAM Blocks", "Total DSP Blocks",
            "Total PLLs"):
    m = re.search(re.escape(key) + r"\s*:\s*(.+)", fit)
    if m:
        print(f"   {key:<28} {m.group(1).strip()}")

sta = open(os.path.join(out, "ap_core.sta.summary")).read()
worst = {}
for typ, slack in re.findall(r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?[\d.]+)", sta):
    m = re.match(r"(.+?) Model (Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(.+)'", typ)
    if not m:
        continue
    corner, kind, clk = m.groups()
    k = (clk, kind)
    s = float(slack)
    if k not in worst or s < worst[k][0]:
        worst[k] = (s, corner)

names = {
    "general[0]": "clk_core 48",
    "general[1]": "clk_sdram 96",
    "general[2]": "clk_sdram_ps 96/180",
    "general[3]": "clk_vid 6",
    "general[4]": "clk_vid90 6/90",
}
def label(clk):
    for k, v in names.items():
        if k in clk:
            return v
    return clk

print("== timing: worst slack per clock over all corners (ns)")
fail = False
for clk in sorted({c for c, _ in worst}, key=label):
    row = []
    for kind in ("Setup", "Hold", "Recovery", "Removal"):
        if (clk, kind) in worst:
            s, corner = worst[(clk, kind)]
            row.append(f"{kind.lower()} {s:+.3f}")
            if s < 0:
                fail = True
    print(f"   {label(clk):<22} " + "  ".join(row))
if fail:
    print("== NEGATIVE SLACK: timing is not met")
    sys.exit(1)
print("== timing met")
EOF
