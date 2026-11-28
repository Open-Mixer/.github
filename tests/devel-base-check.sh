#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The devel-base-check action: its self-test is green; a planted step passing devel-channel to add-openmixer without
# devel-base is red and named by file, job and step; the paired step, the build workflows' preflight-output pair and a
# step reading no wave are green; a base under another condition than the channel's is red; this repository's own
# workflows and actions are green; public-sources-check.yml runs the action in every caller with no input to switch it
# off, and this repository's ci.yml reads itself with it. A guard blind to one rule is caught: each sabotaged copy of the
# checker (no missing-base rule, no same-expression rule, no add-openmixer step recognised, composite actions unread)
# goes red in its own self-test and green on the tree it should refuse.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/devel-base-check
chk=$act/devel-base-check.py
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "$chk" --self-test | grep -q 'self-test green' || fail "self-test not green"

plant() { # dir file yaml
  mkdir -p "$(dirname "$tmp/$1/$2")"; printf '%s\n' "$3" > "$tmp/$1/$2"
}
run() { # checker dir -> rc, output in $tmp/<dir>.out
  local rc=0; python3 "$1" "$tmp/$2" > "$tmp/$2.out" 2>&1 || rc=$?; echo "$rc"
}
CH="\${{ github.base_ref == 'devel' && vars.OMX_DEVEL_CHANNEL || '' }}"
BA="\${{ github.base_ref == 'devel' && vars.OMX_DEVEL_BASE || '' }}"
step() { # name with-lines
  printf 'jobs:\n  build:\n    steps:\n      - name: %s\n        uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1\n        with:\n%s\n' "$1" "$2"
}
plant missing .github/workflows/ci.yml "$(step 'Add the channel' "          devel-channel: $CH")"
plant paired .github/workflows/ci.yml "$(step 'Add the channel' "          devel-channel: $CH
          devel-base: $BA")"
plant outputs .github/workflows/ci.yml "$(step 'Add the channel' "          devel-channel: \${{ needs.preflight.outputs.devel-channel }}
          devel-base: \${{ needs.preflight.outputs.devel-base }}")"
plant nowave .github/workflows/ci.yml "$(step 'Add the channel' "          staging: 'true'")"
plant othercond .github/workflows/ci.yml "$(step 'Add the channel' "          devel-channel: $CH
          devel-base: \${{ vars.OMX_DEVEL_BASE }}")"
plant composite .github/actions/x/action.yml 'runs:
  using: composite
  steps:
    - name: Add the wave
      uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
      with:
        devel-channel: ${{ inputs.devel-channel }}'

[ "$(run "$chk" missing)" = 1 ] || fail "a step without devel-base is not red"
grep -q "^.github/workflows/ci.yml: job build step 'Add the channel': add-openmixer reads devel-channel .* without devel-base" \
  "$tmp/missing.out" || fail "the refusal does not name the file, the job and the step: $(cat "$tmp/missing.out")"
[ "$(run "$chk" paired)" = 0 ] || fail "a paired step is not green"
[ "$(run "$chk" outputs)" = 0 ] || fail "the preflight-output pair is not green"
[ "$(run "$chk" nowave)" = 0 ] || fail "a step reading no wave is not green"
[ "$(run "$chk" othercond)" = 1 ] || fail "a base under another condition than the channel's is not red"
[ "$(run "$chk" composite)" = 1 ] || fail "a composite action without devel-base is not red"
mkdir -p "$tmp/empty"; [ "$(run "$chk" empty)" = 2 ] || fail "nothing to read is not exit 2"

# this repository: every add-openmixer step reading a wave reads its base waves
python3 "$chk" "$here" >/dev/null || fail "this repository's own workflows or actions: $(python3 "$chk" "$here" 2>&1)"

# the wiring: every caller of public-sources-check.yml runs the action, with no input that switches it off
w=$here/.github/workflows/public-sources-check.yml
sed -n '/^  devel-base:/,/^  [a-z-]*:$/p' "$w" > "$tmp/job"
grep -q 'devel-base-check@openmixer-v1' "$tmp/job" || fail "public-sources-check.yml has no devel-base job calling the action"
grep -q 'actions/checkout@v4' "$tmp/job" || fail "the devel-base job does not check the caller out"
! grep -q '^    if:' "$tmp/job" || fail "the devel-base job is conditional: every caller must run it"
grep -q 'uses: ./.github/actions/devel-base-check' "$here/.github/workflows/ci.yml" || fail "ci.yml does not read this repository with the action"
grep -q 'tests/devel-base-check.sh' "$here/.github/workflows/ci.yml" || fail "ci.yml does not run this test"

# sabotage: each rule taken out of a copy must turn its self-test red and let the tree it should refuse through
sabotage() { # name sed-expression tree-it-should-refuse
  local s=$tmp/sab-$1.py
  sed -E "$2" "$chk" > "$s"
  cmp -s "$s" "$chk" && fail "sabotage $1 changed nothing (its pattern no longer matches the checker)"
  python3 "$s" --self-test >/dev/null 2>&1 && fail "sabotage $1: the self-test stayed green"
  [ "$(run "$s" "$3")" = 0 ] || fail "sabotage $1: the tree $3 is still refused (the sabotage did not blind the rule)"
}
sabotage no-missing-rule 's/^        if db == "":$/        if False:/' composite
sabotage no-same-expression 's/if db != want:/if False:/' othercond
sabotage no-step-recognised 's/return u.endswith\(".github\/actions\/add-openmixer"\)/return False/' missing
sabotage no-composite 's/judge_steps\(rel, "composite action"/(lambda *a: None)(rel, "composite action"/' composite

echo "devel-base-check: GREEN (self-test, 7 planted trees, this repository, wiring, 4 sabotages)"
