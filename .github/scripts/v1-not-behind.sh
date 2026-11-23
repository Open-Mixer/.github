#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# v1-not-behind: the rule "openmixer-v1 is fast-forwarded to main after every merge", as a gate. Both branches are
# fetched from the remote into private refs (a failed fetch is refused by name, never compared against a stale or absent
# copy), each is resolved with rev-parse -q --verify (an empty one is refused by name), and openmixer-v1 must contain
# main: equal passes, v1 ahead passes, anything else is refused with how many commits of main it lacks.
#   v1-not-behind.sh [remote [main-branch [v1-branch]]]     defaults: origin main openmixer-v1
# Exit 0 pass, 1 refused (v1 behind), 2 refused (a ref the gate could not read).
set -u
remote=${1-origin}
main_branch=${2-main}
v1_branch=${3-openmixer-v1}
ns=refs/v1-not-behind

refuse() { echo "v1-not-behind: $*" >&2; exit 2; }

[ -n "$remote" ] && [ -n "$main_branch" ] && [ -n "$v1_branch" ] || refuse "an empty remote or branch name is refused"

# Drop what an earlier run left: a failed fetch must leave nothing to compare against.
git update-ref -d "$ns/main" 2>/dev/null
git update-ref -d "$ns/v1" 2>/dev/null

git fetch -q --no-tags "$remote" "+refs/heads/$main_branch:$ns/main" \
  || refuse "fetching $main_branch from $remote failed: refused, never compared against a stale or absent ref"
git fetch -q --no-tags "$remote" "+refs/heads/$v1_branch:$ns/v1" \
  || refuse "fetching $v1_branch from $remote failed (absent or unreachable): refused, never compared against a stale or absent ref"

main_sha=$(git rev-parse -q --verify "$ns/main^{commit}") && [ -n "$main_sha" ] \
  || refuse "$main_branch resolved to nothing: refused"
v1_sha=$(git rev-parse -q --verify "$ns/v1^{commit}") && [ -n "$v1_sha" ] \
  || refuse "$v1_branch resolved to nothing: refused"

if git merge-base --is-ancestor "$main_sha" "$v1_sha"; then
  echo "v1-not-behind: $v1_branch ($v1_sha) contains $main_branch ($main_sha)"
  exit 0
fi
n=$(git rev-list --count "$v1_sha..$main_sha") || refuse "cannot count $v1_branch..$main_branch (shallow checkout?): refused"
echo "$v1_branch is $n commit(s) behind $main_branch: fast-forward it (git push $remote $main_sha:$v1_branch) before merging" >&2
exit 1
