#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Check matrices follow the release set (ruling D25, Open-Mixer/.github#59), offline: the check-matrix action, run as
# its action.yml runs it.
# Proves:
#   - with OMX_RELEASE_MATRIX quick, plugin-hostd's full-stack checks (Debian bookworm and trixie on amd64 and arm64,
#     Fedora 44 on x86_64 and aarch64) render the quick cells alone: trixie amd64, trixie arm64, fc44 x86_64; the cells
#     left out are named in the notice; a CI image list (Fedora 44 and 45, Debian bookworm and trixie) renders
#     fedora:44, fedora:45 and debian:trixie, bookworm skipped;
#   - with full, or the variable unset, the caller's whole matrix, every cell;
#   - the matrix input overrides the variable;
#   - a kind whose matrix holds no quick cell renders no cell while quick (count 0, the job skipped), never the full
#     matrix: a check never runs a cell the set does not build;
#   - a variable that is neither quick nor full fails;
#   - one source: the cells come from release-matrix's quick.txt, through matrix.sh; the action restates no cell, and
#     a quick.txt changed in a copy changes the rendered matrix (the sabotage: a check-matrix.sh that ignores the set
#     renders bookworm while quick, and goes red here).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${CHECK_MATRIX_ACTIONS:-$here/.github/actions}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }

[ -f "$actions/check-matrix/action.yml" ] || { echo "FAIL there is no check-matrix action"; exit 1; }
# the step script, read out of the action file and run with the env it maps
python3 -I - "$actions/check-matrix/action.yml" "$t/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
s = [s for s in steps if s.get("id") == "matrix"]
assert s, "no step with id matrix"
open(sys.argv[2], "w").write(s[0]["run"])
PY

render() { # <wave> <matrix input> <rpm releases> <rpm arches> <deb releases> <deb arches>: key=value lines in $t/out
    : > "$t/out"
    GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$actions/check-matrix WAVE=$1 MATRIX=$2 \
        RPM_RELEASES=$3 RPM_ARCHES=$4 DEB_RELEASES=$5 DEB_ARCHES=$6 bash "$t/step.sh" > "$t/log" 2>&1
}
out() { sed -n "s/^$1=//p" "$t/out"; }
expect() { # <name> <output> <want>
    local got; got=$(out "$2")
    if [ "$got" = "$3" ]; then yes "$1: $2"; else no "$1: $2 is '$got', want '$3'"; cat "$t/log"; fi
}

PHD_RPM='["44"]' PHD_RPMA='["x86_64", "aarch64"]' PHD_DEB='["bookworm", "trixie"]' PHD_DEBA='["amd64", "arm64"]'

# ---- plugin-hostd's full-stack checks while the wave is quick
render quick '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA" || { no "quick render failed"; cat "$t/log"; }
expect "quick, plugin-hostd" set quick
expect "quick, plugin-hostd" rpm '[{"fedora":"44","arch":"x86_64","image":"fedora:44"}]'
expect "quick, plugin-hostd" rpm-count 1
expect "quick, plugin-hostd" deb '[{"suite":"trixie","arch":"amd64","image":"debian:trixie"},{"suite":"trixie","arch":"arm64","image":"debian:trixie"}]'
expect "quick, plugin-hostd" deb-count 2
expect "quick, plugin-hostd" images '["fedora:44","debian:trixie"]'
for c in 'fc44 aarch64' 'bookworm amd64' 'bookworm arm64'; do
    grep -q "skipped while quick:.*$c" "$t/log" && yes "quick: the notice names $c as skipped" || { no "quick: the notice does not name $c as skipped"; cat "$t/log"; }
done

# ---- the same with full, and with the variable unset
for w in full ''; do
    render "$w" '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA" || { no "${w:-unset} render failed"; cat "$t/log"; }
    expect "${w:-unset}, plugin-hostd" set full
    expect "${w:-unset}, plugin-hostd" rpm '[{"fedora":"44","arch":"x86_64","image":"fedora:44"},{"fedora":"44","arch":"aarch64","image":"fedora:44"}]'
    expect "${w:-unset}, plugin-hostd" deb-count 4
    expect "${w:-unset}, plugin-hostd" images '["fedora:44","debian:bookworm","debian:trixie"]'
done

# ---- the matrix input overrides the variable
render quick full "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"
expect "matrix full over quick" deb-count 4
render full quick "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"
expect "matrix quick over full" deb-count 2

# ---- an ordinary CI image list (D25): fedora:44, fedora:45, debian:trixie while quick; bookworm returns with full
render quick '' '["44", "45"]' '["x86_64"]' '["bookworm", "trixie"]' '["amd64"]'
expect "CI images, quick" images '["fedora:44","fedora:45","debian:trixie"]'
render full '' '["44", "45"]' '["x86_64"]' '["bookworm", "trixie"]' '["amd64"]'
expect "CI images, full" images '["fedora:44","fedora:45","debian:bookworm","debian:trixie"]'

# ---- a kind with no quick cell renders nothing while quick, never its full matrix; an unused kind renders nothing
render quick '' '' '' '["bookworm"]' '["amd64", "arm64"]'
expect "bookworm alone, quick" deb '[]'
expect "bookworm alone, quick" deb-count 0
expect "bookworm alone, quick" rpm '[]'
expect "bookworm alone, quick" rpm-count 0
expect "bookworm alone, quick" count 0
expect "bookworm alone, quick" images '[]'
render full '' '' '' '["bookworm"]' '["amd64", "arm64"]'
expect "bookworm alone, full" deb-count 2

# ---- a variable that is neither quick nor full fails
if render fast '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"; then no "OMX_RELEASE_MATRIX=fast passed"; else yes "OMX_RELEASE_MATRIX=fast fails"; fi

# ---- one source: no cell restated, and quick.txt is what is read
if grep -nE '\b(bookworm|trixie|x86_64|aarch64|amd64|arm64)\b' "$actions/check-matrix/check-matrix.sh" "$t/step.sh" | grep -v '^[^:]*:[0-9]*:#'; then
    no "check-matrix restates a cell"
else
    yes "check-matrix restates no cell"
fi
cp -a "$actions" "$t/copy"
printf 'rpm 45 x86_64\ndeb bookworm arm64\n' > "$t/copy/release-matrix/quick.txt"
: > "$t/out"
GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$t/copy/check-matrix WAVE=quick MATRIX='' RPM_RELEASES='["44", "45"]' RPM_ARCHES='["x86_64"]' \
    DEB_RELEASES="$PHD_DEB" DEB_ARCHES="$PHD_DEBA" bash "$t/step.sh" > "$t/log" 2>&1
expect "a changed quick.txt" images '["fedora:45","debian:bookworm"]'

[ "$fail" = 0 ] && echo "check-matrix: all passed" || exit 1
