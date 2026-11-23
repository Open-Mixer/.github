#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# v1-not-behind (.github/scripts/v1-not-behind.sh), proven on a fixture remote and clone: v1 == main passes; v1 ahead
# of main passes; v1 behind by 2 is refused by name with N=2 and the push to run; v1 behind with main moved on (diverged)
# is refused; v1 absent is refused by name; a failed fetch (the remote gone) is refused by name even with a stale copy
# of both refs in the clone; sabotage: with the refusal taken out of the script, arm 2 passes, which is the red.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
script=$here/.github/scripts/v1-not-behind.sh
t=$(mktemp -d /var/tmp/v1nb.XXXXXX) || exit 1
trap 'rm -rf "$t"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# expect <name> <want-exit> <want-text> <script> -- runs in $t/clone
expect() {
  local name=$1 want=$2 text=$3 sc=$4 out rc
  out=$(cd "$t/clone" && "$sc" origin main openmixer-v1 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$text"; then ok "$name"
  else bad "$name: exit $rc (want $want), output: $out"; fi
}

fixture() {   # main with 3 commits, v1 at the same commit
  rm -rf "$t/remote.git" "$t/clone" "$t/work"
  git init -q --bare -b main "$t/remote.git"
  git init -q -b main "$t/work"
  ( cd "$t/work" || exit 1
    for i in 1 2 3; do echo $i > f; git add f; git commit -q -m "c$i"; done
    git remote add origin "$t/remote.git"
    git push -q origin main:main main:openmixer-v1 )
  git clone -q "$t/remote.git" "$t/clone"
}
advance() { ( cd "$t/work" || exit 1; for i in "$@"; do echo "$i" > f; git add f; git commit -q -m "$i"; done; git push -q origin main:main ); }

# sabotaged copy: the refusal for a v1 that does not contain main turned into a pass
sab=$t/sabotaged.sh
sed 's/^exit 1$/exit 0/' "$script" > "$sab"; chmod +x "$sab"
cmp -s "$script" "$sab" && bad "sabotage did not change the script"

fixture
expect "1 v1 == main passes" 0 "contains" "$script"

( cd "$t/work" && echo ahead > g && git add g && git commit -q -m ahead && git push -q origin HEAD:openmixer-v1 )
expect "1b v1 ahead of main passes" 0 "contains" "$script"

fixture; advance m4 m5
want_sha=$(git -C "$t/work" rev-parse main)
expect "2 v1 behind by 2 refused with N=2" 1 "openmixer-v1 is 2 commit(s) behind main: fast-forward it (git push origin $want_sha:openmixer-v1) before merging" "$script"
out=$(cd "$t/clone" && "$sab" origin main openmixer-v1 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "2s sabotage: the refusal skipped, arm 2 passes, which is the red the arm guards"
else bad "2s sabotage still refused: $rc $out"; fi

fixture; git -C "$t/work" checkout -q -b side HEAD~1; advance d1; git -C "$t/work" push -q -f origin side:openmixer-v1; advance m4
expect "2c v1 diverged from main refused" 1 "commit(s) behind main" "$script"

fixture; git -C "$t/remote.git" branch -q -D openmixer-v1
expect "3 v1 absent refused by name" 2 "fetching openmixer-v1 from origin failed" "$script"

fixture; git -C "$t/clone" fetch -q origin   # the clone now holds origin/main and origin/openmixer-v1, both stale-able
rm -rf "$t/remote.git"
expect "4 failed fetch refused by name, stale refs not used" 2 "fetching main from origin failed" "$script"

fixture
out=$(cd "$t/clone" && "$script" origin "" openmixer-v1 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF "empty"; then ok "5 an empty branch name refused by name"
else bad "5 empty name: $rc $out"; fi

if [ "$fail" = 0 ]; then echo "v1-not-behind: all arms hold"; else echo "v1-not-behind: RED"; exit 1; fi
