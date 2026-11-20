#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The fedora-workflow-check action: each of the 12 planted arms of omx-panel#148 @7d4fc3a is red or green as there, a clean
# tree is green, widening the allowed list ("44 45") turns the 44 arms green and leaves 43 red (the list is an input, not
# written in the script), the input reaches the script through the environment and is never spliced into a run line, the
# public-sources-check job is wired to it, and a guard blind to one rule is caught: each sabotaged copy of the script
# (no rpm-releases rule, no block-list rule, no fc rule, no image rule, comments read) goes red on its own arm.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/fedora-workflow-check
chk=$act/fedora-workflow-check.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$chk" --self-test | grep -q 'self-test green (12 reference arms' || fail "self-test not green"

plant() { # script name yaml allowed -> rc
  local d=$tmp/$2; mkdir -p "$d/.github/workflows"; printf '%s\n' "$3" > "$d/.github/workflows/ci.yml"
  local rc=0; ALLOWED_FEDORA=${4:-45} "$1" "$d" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
want() { # name want-rc got-rc
  [ "$3" = "$2" ] || fail "$1: rc $3, want $2"
}
# arm table: name|rc|yaml (the 12 of the reference; blocks use \n)
while IFS='|' read -r name rc yaml; do
  want "$name" "$rc" "$(plant "$chk" "$name" "$(printf '%b' "$yaml")")"
done <<'ARMS'
clean|0|jobs:\n  a:\n    container:\n      image: fedora:45
image44|1|image: fedora:44
fc44name|1|name: omx (fc44, x86_64)
matrix44last|1|fedora: [45, 44]
matrix44mid|1|fedora: [43, 44, 45]
blocklist|1|fedora:\n  - 45\n  - 44
blocklistfirst|1|fedora:\n  - 44\n  - 45
not144|0|fedora: [45, 144]
rpm44|1|rpm-releases: '["44", "45"]'
rpm45|0|rpm-releases: '["45"]'
recordset|0|set: fedora44-x86-64
recordsetimage|1|run: measure fedora44 on image: fedora:44
sha|0|REAC_PROTOCOL_REF: 26b16db9fc844820fed8adc26a342f6b86f3a1ba
digest|0|image: quay.io/fedora/fedora-coreos@sha256:0f1a45b9c3d7e2a6b8d4f0c1e5a7b9d3f2c4e6a8b0d1f3a5c7e9b2d4f6a8c0e1
fc45inname|0|name: omx (fc45, x86_64) rpm-0.1-1.fc45.x86_64
ARMS
mkdir -p "$tmp/nodir"; rc=0; "$chk" "$tmp/nodir" >/dev/null 2>&1 || rc=$?; want "no workflows dir" 2 "$rc"

# the allowed list is the input: "44 45" makes the 44 arms green, 43 stays red, "44" alone refuses 45
for y in 'image: fedora:44' 'name: omx (fc44, x86_64)' 'fedora: [45, 44]' "rpm-releases: '[\"44\", \"45\"]'" 'fedora:
  - 44
  - 45'; do
  want "allowed 44 45: $y" 0 "$(plant "$chk" allow "$y" '44 45')"
  want "allowed 45: $y" 1 "$(plant "$chk" deny "$y" 45)"
done
want "43 under '44 45'" 1 "$(plant "$chk" a43 'image: fedora:43' '44 45')"
want "45 under '44'" 1 "$(plant "$chk" a45 'image: fedora:45' 44)"
# the default (no env at all) is 45
d=$tmp/default; mkdir -p "$d/.github/workflows"; echo 'image: fedora:44' > "$d/.github/workflows/ci.yml"
rc=0; env -u ALLOWED_FEDORA "$chk" "$d" >/dev/null 2>&1 || rc=$?; want "default refuses 44" 1 "$rc"
echo 'image: fedora:45' > "$d/.github/workflows/ci.yml"
rc=0; env -u ALLOWED_FEDORA "$chk" "$d" >/dev/null 2>&1 || rc=$?; want "default allows 45" 0 "$rc"

# the list is written once: action.yml's default
[ "$(sed -n '/^  allowed-fedora:/,/^runs:/p' "$act/action.yml" | sed -n 's/^    default: //p')" = '"45"' ] || fail "action.yml default is not 45"
# the input reaches the script by env, never in a run line
grep -q 'ALLOWED_FEDORA: ${{ inputs.allowed-fedora }}' "$act/action.yml" || fail "allowed-fedora does not reach the script by env"
! grep -E '^[[:space:]]+run:|^[[:space:]]{8,}[^#]*"\$\{\{' "$act/action.yml" | grep -q 'inputs\.' || fail "an input is spliced into a run line"
! grep -vE '^[[:space:]]*#' "$act/action.yml" | grep -A6 'run: |' | grep -q 'inputs\.' || fail "an input is spliced into a run block"
# the reusable workflow: an off-by-default boolean, the list passed on as an action input
w=$here/.github/workflows/public-sources-check.yml
sed -n '/^      fedora-workflows:/,/default:/p' "$w" | grep -q 'type: boolean' || fail "fedora-workflows is not a boolean input"
sed -n '/^      fedora-workflows:/,/^      allowed-fedora:/p' "$w" | grep -q 'default: false' || fail "fedora-workflows is not off by default"
sed -n '/^      allowed-fedora:/,/^      runner:/p' "$w" | grep -q "default: '45'" || fail "allowed-fedora does not default to 45"
sed -n '/^  fedora-workflows:/,/^  private-refs:/p' "$w" > "$tmp/job"
grep -q 'if: inputs.fedora-workflows' "$tmp/job" || fail "the job does not wait for the input"
grep -q 'fedora-workflow-check@openmixer-v1' "$tmp/job" || fail "the job does not call the action"
grep -q 'allowed-fedora: ${{ inputs.allowed-fedora }}' "$tmp/job" || fail "the list is not passed to the action"
! grep -vE '^[[:space:]]*#' "$tmp/job" | grep -A3 ' run:' | grep -q 'inputs\.' || fail "the job splices an input into a run line"

# sabotage: a guard blind to one rule must go red on its own arm (the script's own self-test, and the arm here)
sab() { # rule-tag arm-name arm-yaml
  sed "/# rule:$1\$/d" "$chk" > "$tmp/sab-$1.sh"; chmod +x "$tmp/sab-$1.sh"
  cmp -s "$chk" "$tmp/sab-$1.sh" && fail "sabotage $1: nothing removed (the rule tag moved)"
  want "sabotaged $1: arm $2 must read green" 0 "$(plant "$tmp/sab-$1.sh" "sab$1" "$3")"
  rc=0; "$tmp/sab-$1.sh" --self-test >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "sabotaged $1: the script's own self-test stayed green"
}
sab releases rpm44 "rpm-releases: '[\"44\", \"45\"]'"
sab block blocklist 'fedora:
  - 45
  - 44'
sab fc fc44name 'name: omx (fc44, x86_64)'
sab image image29 'image: fedora:29'
sab fedoraline matrix44last 'fedora: [45, 44]'
# a loose fc rule (a letter-only left boundary, any digit count) reads a hex SHA as a cell: the sha arm goes red
sed 's/q !~ \/\[A-Za-z0-9\]\/ \&\& //; s/p !~ \/\[A-Za-z0-9\]\/ \&\& length(n) == 2/p !~ \/[a-z]\//' "$chk" > "$tmp/sab-loose.sh"; chmod +x "$tmp/sab-loose.sh"
cmp -s "$chk" "$tmp/sab-loose.sh" && fail "sabotage loose fc: nothing removed"
want "loose fc rule reads a SHA as a cell" 1 "$(plant "$tmp/sab-loose.sh" sabloose 'REAC_PROTOCOL_REF: 26b16db9fc844820fed8adc26a342f6b86f3a1ba')"
# comments: a guard that reads them refuses a note that mentions fedora:44
sed 's/sub(\/\^\[\[:space:\]\]\*#\.\*\/, "", l); sub(\/\[\[:space:\]\]#\.\*\/, "", l)//' "$chk" > "$tmp/sab-comment.sh"; chmod +x "$tmp/sab-comment.sh"
cmp -s "$chk" "$tmp/sab-comment.sh" && fail "sabotage comment: nothing removed"
want "sabotaged comment: a commented fedora:44 reads red" 1 "$(plant "$tmp/sab-comment.sh" sabcomment '# was fedora:44')"
want "comment read by the real script" 0 "$(plant "$chk" realcomment '# was fedora:44')"
# the shared repository's own workflows are clean at the default
rc=0; "$chk" "$here" >/dev/null 2>&1 || rc=$?; want "this repository's workflows" 0 "$rc"
echo "fedora-workflow-check: GREEN (12 arms, allowed list, env wiring, 7 sabotages)"
