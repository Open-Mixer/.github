#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The devel-base-check action: its self-test is green; a planted step passing devel-channel to add-openmixer without
# devel-base is red and named by file, job and step; the paired step, the build workflows' preflight-output pair and a
# step reading no wave are green where the repository has no devel branch; where it has one (OMX_HAS_DEVEL=true) a bare
# call (no with:, plugin-db#104) and a step reading no wave are red and named too; a base under another condition
# than the channel's is red; this repository's own
# workflows and actions are green; public-sources-check.yml runs the action in every caller with no input to switch it
# off, and this repository's ci.yml reads itself with it. A guard blind to one rule is caught: each sabotaged copy of the
# checker (no missing-base rule, no same-expression rule, no add-openmixer step recognised, composite actions unread,
# no bare-call rule)
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
run() { # checker dir [has-devel] -> rc, output in $tmp/<dir>.out
  local rc=0; OMX_HAS_DEVEL=${3:-false} python3 "$1" "$tmp/$2" > "$tmp/$2.out" 2>&1 || rc=$?; echo "$rc"
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
plant bare .github/workflows/ci.yml 'jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - name: Add the OpenMixer channel
        uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1'

[ "$(run "$chk" missing)" = 1 ] || fail "a step without devel-base is not red"
grep -q "^.github/workflows/ci.yml: job build step 'Add the channel': add-openmixer reads devel-channel .* without devel-base" \
  "$tmp/missing.out" || fail "the refusal does not name the file, the job and the step: $(cat "$tmp/missing.out")"
[ "$(run "$chk" paired)" = 0 ] || fail "a paired step is not green"
[ "$(run "$chk" outputs)" = 0 ] || fail "the preflight-output pair is not green"
[ "$(run "$chk" nowave)" = 0 ] || fail "a step reading no wave is not green"
[ "$(run "$chk" othercond)" = 1 ] || fail "a base under another condition than the channel's is not red"
[ "$(run "$chk" composite)" = 1 ] || fail "a composite action without devel-base is not red"
mkdir -p "$tmp/empty"; [ "$(run "$chk" empty)" = 2 ] || fail "nothing to read is not exit 2"
# a repository with a devel branch: every add-openmixer step reads both, a bare one is refused by name
[ "$(run "$chk" bare false)" = 0 ] || fail "a bare call without a devel branch is not green"
[ "$(run "$chk" bare true)" = 1 ] || fail "a bare call in a repository with a devel branch is not red"
grep -q "^.github/workflows/ci.yml: job test step 'Add the OpenMixer channel': add-openmixer reads no devel-channel and no devel-base" \
  "$tmp/bare.out" || fail "the bare call is not named by file, job and step: $(cat "$tmp/bare.out")"
[ "$(run "$chk" nowave true)" = 1 ] || fail "a step reading no wave in a repository with a devel branch is not red"
[ "$(run "$chk" paired true)" = 0 ] || fail "a paired step in a repository with a devel branch is not green"
[ "$(run "$chk" outputs true)" = 0 ] || fail "the preflight-output pair in a repository with a devel branch is not green"
[ "$(run "$chk" bare maybe)" = 2 ] || fail "OMX_HAS_DEVEL that is not true or false is not exit 2"
# unset, the checker asks the tree's origin: a scratch repository whose origin has a devel branch, and one whose has not
for b in devel main; do
  g=$tmp/origin-$b; git init -q --bare "$g"; w=$tmp/ask-$b; mkdir -p "$w"; cp -r "$tmp/bare/.github" "$w/"
  git -C "$w" init -q -b "$b"; git -C "$w" add .github
  git -C "$w" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m t
  git -C "$w" remote add origin "$g"; git -C "$w" push -q origin "$b"
done
rc=0; env -u OMX_HAS_DEVEL python3 "$chk" "$tmp/ask-devel" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "unset OMX_HAS_DEVEL: an origin with a devel branch did not refuse the bare call (rc $rc)"
rc=0; env -u OMX_HAS_DEVEL python3 "$chk" "$tmp/ask-main" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "unset OMX_HAS_DEVEL: an origin without a devel branch refused the bare call (rc $rc)"
git -C "$tmp/ask-main" remote set-url origin "$tmp/nowhere"
rc=0; env -u OMX_HAS_DEVEL python3 "$chk" "$tmp/ask-main" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unset OMX_HAS_DEVEL: an origin that cannot be read is not exit 2 (rc $rc)"

# this repository (it has a devel branch): every add-openmixer step reads the wave and its base waves
OMX_HAS_DEVEL=true python3 "$chk" "$here" >/dev/null || fail "this repository's own workflows or actions: $(OMX_HAS_DEVEL=true python3 "$chk" "$here" 2>&1)"

# the wiring: every caller of public-sources-check.yml runs the action, with no input that switches it off
w=$here/.github/workflows/public-sources-check.yml
sed -n '/^  devel-base:/,/^  [a-z-]*:$/p' "$w" > "$tmp/job"
grep -q 'devel-base-check@openmixer-v1' "$tmp/job" || fail "public-sources-check.yml has no devel-base job calling the action"
grep -q 'actions/checkout@v4' "$tmp/job" || fail "the devel-base job does not check the caller out"
! grep -q '^    if:' "$tmp/job" || fail "the devel-base job is conditional: every caller must run it"
grep -q 'uses: ./.github/actions/devel-base-check' "$here/.github/workflows/ci.yml" || fail "ci.yml does not read this repository with the action"
grep -q 'tests/devel-base-check.sh' "$here/.github/workflows/ci.yml" || fail "ci.yml does not run this test"

# sabotage: each rule taken out of a copy must turn its self-test red and let the tree it should refuse through
sabotage() { # name sed-expression tree-it-should-refuse [has-devel]
  local s=$tmp/sab-$1.py
  sed -E "$2" "$chk" > "$s"
  cmp -s "$s" "$chk" && fail "sabotage $1 changed nothing (its pattern no longer matches the checker)"
  python3 "$s" --self-test >/dev/null 2>&1 && fail "sabotage $1: the self-test stayed green"
  [ "$(run "$s" "$3" "${4:-false}")" = 0 ] || fail "sabotage $1: the tree $3 is still refused (the sabotage did not blind the rule)"
}
sabotage no-missing-rule 's/^        if db == "":$/        if False:/' composite
sabotage no-same-expression 's/if db != want:/if False:/' othercond
sabotage no-step-recognised 's/return u.endswith\(".github\/actions\/add-openmixer"\)/return False/' missing
sabotage no-bare-rule 's/^            if has_devel:  # a bare call/            if False:  # a bare call/' bare true
sabotage no-composite 's/judge_steps\(rel, "composite action"/(lambda *a: None)(rel, "composite action"/' composite

echo "devel-base-check: GREEN (self-test, 8 planted trees, the devel-branch rule and its origin lookup, this repository, wiring, 5 sabotages)"
