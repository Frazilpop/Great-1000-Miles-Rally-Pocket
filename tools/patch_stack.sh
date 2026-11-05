#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Is a clone's stack of local patches in place?
#   tools/patch_stack.sh <name>     (third_party/<name>, tools/patches/<name>-*.patch)
# Exit 0 if every patch is applied, 1 if not, 2 if there are none.
#
# The patches stack: each is made with `git diff` on top of the ones before it
# in name order, so a later one can touch a line an earlier one wrote, and an
# earlier one then no longer reverses on its own. So the check is the stack's:
# on a copy of the files they touch, each comes off in reverse order, and each
# must come off cleanly.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
name=$1
dest=$ROOT/third_party/$name
shopt -s nullglob
patches=("$ROOT"/tools/patches/"$name"-*.patch)
[ ${#patches[@]} -gt 0 ] || exit 2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in $(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u); do
    [ -f "$dest/$f" ] || exit 1
    mkdir -p "$tmp/$(dirname "$f")"
    cp "$dest/$f" "$tmp/$f"
done
for (( i=${#patches[@]}-1; i>=0; i-- )); do
    (cd "$tmp" && git apply --reverse "${patches[$i]}" 2>/dev/null) || exit 1
done
exit 0
