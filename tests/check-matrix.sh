#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Check matrices follow the release set (ruling D25, Open-Mixer/.github#59), offline: the check-matrix action, run as
# its action.yml runs it.
# Proves:
#   - with OMX_RELEASE_MATRIX quick, plugin-hostd's full-stack checks (Debian trixie on amd64 and arm64, Fedora 45 on
#     x86_64 and aarch64) render the quick cells alone: trixie arm64, fc45 x86_64; the cells left out are named in the
#     notice; a CI image list (Fedora 44 and 45, Debian trixie) renders fedora:45 and debian:trixie, fc44 skipped;
#   - with full, or the variable unset, the caller's whole matrix, every cell;
#   - the matrix input overrides the variable;
#   - a kind whose matrix holds no quick cell renders no cell while quick (count 0, the job skipped), never the full
#     matrix: a check never runs a cell the set does not build;
#   - a variable that is neither quick nor full fails;
#   - every cell names the runner of its own architecture (an arm64 or aarch64 cell ubuntu-24.04-arm, an x86 cell
#     ubuntu-latest), so a deb job writes runs-on: matrix.cell.runner and never installs an arm64 -dev package in an
#     amd64 container (omx-panel ci 44563540081); while quick, no deb cell is left on an x86 runner; the sabotage, a
#     check-matrix.sh that names ubuntu-latest for every cell, goes red here;
#   - one source: the cells come from release-matrix's quick.txt, through matrix.sh; the action restates no cell, and
#     a quick.txt changed in a copy changes the rendered matrix (the sabotage: a check-matrix.sh that ignores the set
#     renders the caller's cell instead of quick.txt's while quick, and goes red here).
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

# the defaults of the runner inputs, read out of the action file (the script writes no architecture or label)
eval "$(python3 -I - "$actions/check-matrix/action.yml" <<'PY'
import sys, yaml
i = yaml.safe_load(open(sys.argv[1]))["inputs"]
for k in ("arm-arches", "arm-runner", "x86-runner"):
    print("export %s=%r" % (k.upper().replace("-", "_") + "_DEFAULT", i[k]["default"]))
PY
)"
render() { # <wave> <matrix input> <rpm releases> <rpm arches> <deb releases> <deb arches>: key=value lines in $t/out
    : > "$t/out"
    GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$actions/check-matrix WAVE=$1 MATRIX=$2 ARM_ARCHES=$ARM_ARCHES_DEFAULT \
        ARM_RUNNER=$ARM_RUNNER_DEFAULT X86_RUNNER=${X86_RUNNER:-$X86_RUNNER_DEFAULT} \
        RPM_RELEASES=$3 RPM_ARCHES=$4 DEB_RELEASES=$5 DEB_ARCHES=$6 bash "$t/step.sh" > "$t/log" 2>&1
}
out() { sed -n "s/^$1=//p" "$t/out"; }
expect() { # <name> <output> <want>
    local got; got=$(out "$2")
    if [ "$got" = "$3" ]; then yes "$1: $2"; else no "$1: $2 is '$got', want '$3'"; cat "$t/log"; fi
}

PHD_RPM='["45"]' PHD_RPMA='["x86_64", "aarch64"]' PHD_DEB='["trixie"]' PHD_DEBA='["amd64", "arm64"]'

# ---- plugin-hostd's full-stack checks while the wave is quick
render quick '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA" || { no "quick render failed"; cat "$t/log"; }
expect "quick, plugin-hostd" set quick
expect "quick, plugin-hostd" rpm '[{"fedora":"45","arch":"x86_64","image":"fedora:45","runner":"ubuntu-latest"}]'
expect "quick, plugin-hostd" rpm-count 1
expect "quick, plugin-hostd" deb '[{"suite":"trixie","arch":"arm64","image":"debian:trixie","runner":"ubuntu-24.04-arm"}]'
expect "quick, plugin-hostd" deb-count 1
expect "quick, plugin-hostd" images '["fedora:45","debian:trixie"]'
for c in 'fc45 aarch64' 'trixie amd64'; do
    grep -q "skipped while quick:.*$c" "$t/log" && yes "quick: the notice names $c as skipped" || { no "quick: the notice does not name $c as skipped"; cat "$t/log"; }
done

# ---- the same with full, and with the variable unset
for w in full ''; do
    render "$w" '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA" || { no "${w:-unset} render failed"; cat "$t/log"; }
    expect "${w:-unset}, plugin-hostd" set full
    expect "${w:-unset}, plugin-hostd" rpm '[{"fedora":"45","arch":"x86_64","image":"fedora:45","runner":"ubuntu-latest"},{"fedora":"45","arch":"aarch64","image":"fedora:45","runner":"ubuntu-24.04-arm"}]'
    expect "${w:-unset}, plugin-hostd" deb-count 2
    expect "${w:-unset}, plugin-hostd" images '["fedora:45","debian:trixie"]'
done

# ---- the matrix input overrides the variable
render quick full "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"
expect "matrix full over quick" deb-count 2
render full quick "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"
expect "matrix quick over full" deb-count 1

# ---- an ordinary CI image list (D25): fedora:45, debian:trixie while quick; fedora:44 returns with full
render quick '' '["44", "45"]' '["x86_64"]' '["trixie"]' '["arm64"]'
expect "CI images, quick" images '["fedora:45","debian:trixie"]'
render full '' '["44", "45"]' '["x86_64"]' '["trixie"]' '["arm64"]'
expect "CI images, full" images '["fedora:44","fedora:45","debian:trixie"]'

# ---- a kind with no quick cell renders nothing while quick, never its full matrix; an unused kind renders nothing
render quick '' '["44"]' '["x86_64", "aarch64"]' '' ''
expect "fc44 alone, quick" rpm '[]'
expect "fc44 alone, quick" rpm-count 0
expect "fc44 alone, quick" deb '[]'
expect "fc44 alone, quick" deb-count 0
expect "fc44 alone, quick" count 0
expect "fc44 alone, quick" images '[]'
render full '' '["44"]' '["x86_64", "aarch64"]' '' ''
expect "fc44 alone, full" rpm-count 2
# ---- a Debian release outside the full matrix is refused by name, never rendered (owner ruling 2026-11-28)
if render full '' '' '' '["bookworm", "trixie"]' '["amd64"]'; then no "a retired Debian release rendered"; else
    grep -q "::error::Debian release 'bookworm' is not in the full matrix" "$t/log" && yes "a retired Debian release is refused by name" \
        || { no "a retired Debian release failed for another reason"; cat "$t/log"; }
fi

# ---- a variable that is neither quick nor full fails
if render fast '' "$PHD_RPM" "$PHD_RPMA" "$PHD_DEB" "$PHD_DEBA"; then no "OMX_RELEASE_MATRIX=fast passed"; else yes "OMX_RELEASE_MATRIX=fast fails"; fi

# ---- a cell runs on the runner of its own architecture: the dev debs are trixie arm64 only, and apt in an amd64
# container resolves an arm64 package that dpkg then refuses
render quick '' '' '' '["trixie"]' '["amd64", "arm64"]'
expect "runner, quick deb" deb '[{"suite":"trixie","arch":"arm64","image":"debian:trixie","runner":"ubuntu-24.04-arm"}]'
if grep -q '"runner":"ubuntu-latest"' <<< "$(out deb)"; then no "quick: a deb cell is left on an x86 runner"; else yes "quick: no deb cell is on an x86 runner"; fi
render full '' '' '' '["trixie"]' '["amd64", "arm64"]'
expect "runner, full deb" deb '[{"suite":"trixie","arch":"amd64","image":"debian:trixie","runner":"ubuntu-latest"},{"suite":"trixie","arch":"arm64","image":"debian:trixie","runner":"ubuntu-24.04-arm"}]'
# sabotage: no architecture routed to the ARM runner is what omx-panel ci 44563540081 ran (the arm64 cell on an x86
# runner); the arm64 assertion above must go red on it
: > "$t/out"
GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$actions/check-matrix WAVE=quick MATRIX='' RPM_RELEASES='' RPM_ARCHES='' \
    DEB_RELEASES='["trixie"]' DEB_ARCHES='["amd64", "arm64"]' ARM_ARCHES=none ARM_RUNNER=$ARM_RUNNER_DEFAULT \
    X86_RUNNER=$X86_RUNNER_DEFAULT bash "$t/step.sh" > "$t/log" 2>&1
if [ "$(out deb)" = '[{"suite":"trixie","arch":"arm64","image":"debian:trixie","runner":"ubuntu-24.04-arm"}]' ]; then
    no "sabotage: the arm64 cell on an x86 runner passed"
else yes "sabotage: the arm64 cell on an x86 runner is red"; fi

# ---- the x86 runner is the caller's: a private pool's label reaches every x86 cell and no ARM cell, so a caller that
# writes runs-on: matrix.cell.runner keeps the runner its x86 jobs always had
X86_RUNNER=arc-freemixer render full '' '["45"]' '["x86_64", "aarch64"]' '["trixie"]' '["amd64", "arm64"]'
expect "x86-runner" rpm '[{"fedora":"45","arch":"x86_64","image":"fedora:45","runner":"arc-freemixer"},{"fedora":"45","arch":"aarch64","image":"fedora:45","runner":"ubuntu-24.04-arm"}]'
expect "x86-runner" deb '[{"suite":"trixie","arch":"amd64","image":"debian:trixie","runner":"arc-freemixer"},{"suite":"trixie","arch":"arm64","image":"debian:trixie","runner":"ubuntu-24.04-arm"}]'
# sabotage: a script that ignores X86_RUNNER leaves the private pool's label out of the x86 cells
cp -a "$actions" "$t/ycopy"
sed -i 's/\$X86_RUNNER/ubuntu-latest/' "$t/ycopy/check-matrix/check-matrix.sh"
: > "$t/out"
GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$t/ycopy/check-matrix WAVE=full MATRIX='' RPM_RELEASES='' RPM_ARCHES='' \
    DEB_RELEASES='["trixie"]' DEB_ARCHES='["amd64"]' ARM_ARCHES=$ARM_ARCHES_DEFAULT ARM_RUNNER=$ARM_RUNNER_DEFAULT \
    X86_RUNNER=arc-freemixer bash "$t/step.sh" > "$t/log" 2>&1
if grep -q arc-freemixer <<< "$(out deb)"; then no "sabotage: an ignored x86-runner passed"; else yes "sabotage: an ignored x86-runner is red"; fi
# a label that is not a label is refused
if X86_RUNNER='a b;c' render full '' '' '' '["trixie"]' '["amd64"]'; then no "a runner label with a space passed"; else yes "a runner label with a space is refused"; fi

# ---- one source: no cell restated, and quick.txt is what is read
if grep -nE '\b(bookworm|trixie|x86_64|aarch64|amd64|arm64)\b' "$actions/check-matrix/check-matrix.sh" "$t/step.sh" | grep -v '^[^:]*:[0-9]*:#'; then
    no "check-matrix restates a cell"
else
    yes "check-matrix restates no cell"
fi
cp -a "$actions" "$t/copy"
printf 'rpm 45 x86_64\ndeb trixie amd64\n' > "$t/copy/release-matrix/quick.txt"
: > "$t/out"
GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$t/copy/check-matrix ARM_ARCHES=$ARM_ARCHES_DEFAULT ARM_RUNNER=$ARM_RUNNER_DEFAULT \
    X86_RUNNER=$X86_RUNNER_DEFAULT WAVE=quick MATRIX='' RPM_RELEASES='["44", "45"]' RPM_ARCHES='["x86_64"]' \
    DEB_RELEASES="$PHD_DEB" DEB_ARCHES="$PHD_DEBA" bash "$t/step.sh" > "$t/log" 2>&1
expect "a changed quick.txt" deb '[{"suite":"trixie","arch":"amd64","image":"debian:trixie","runner":"ubuntu-latest"}]'

# sabotage: an architecture written back into the script's code (no exemption) puts the guard red
cp "$actions/check-matrix/check-matrix.sh" "$t/lit.sh"
sed -i 's/for a in \$ARM_ARCHES; do/for a in aarch64 arm64; do/' "$t/lit.sh"
if grep -nE '\b(bookworm|trixie|x86_64|aarch64|amd64|arm64)\b' "$t/lit.sh" "$t/step.sh" | grep -qv '^[^:]*:[0-9]*:#'; then
    yes "sabotage: an architecture literal in the script is red"
else no "sabotage: an architecture literal in the script passed the guard"; fi

[ "$fail" = 0 ] && echo "check-matrix: all passed" || exit 1
