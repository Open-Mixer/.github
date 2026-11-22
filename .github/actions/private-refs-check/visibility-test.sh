#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The private-refs check runs on every repository unless it opts out, and the opt-out is read from GitHub, live, in one
# lookup: only a repository that is private AND carries the topic stays-private is skipped, with a line naming it. A
# topic never exempts a public repository, a private one without the topic is checked, and a target whose visibility and
# topics cannot be read, a run with no token, or a run that names no target, is refused by name (exit 2), never a pass.
# The lookup needs only bash and python3's standard library: every arm runs on a PATH with no gh and no jq. A file:// API
# stands in for GitHub (GITHUB_API_URL, as urllib reads it): repos/OWNER/REPO is a file holding the answer.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
chk=$here/check.sh
wf=$here/../../workflows/public-sources-check.yml
layout=$here/../public-layout-check/action.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
# a PATH that holds the system's tools but gh and jq
mkdir -p "$tmp/sys"
for d in /usr/local/bin /usr/bin /bin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=${f##*/}; case "$n" in gh|jq) continue ;; esac
    [ -e "$tmp/sys/$n" ] || [ -L "$tmp/sys/$n" ] || ln -s "$f" "$tmp/sys/$n" 2>/dev/null || true
  done
done
NOGH=$tmp/sys
if PATH=$NOGH command -v gh >/dev/null || PATH=$NOGH command -v jq >/dev/null; then echo "FAIL the test PATH still holds gh or jq"; exit 1; fi
API=$tmp/api
answer() { # <json, or the word ABSENT>: what GitHub answers for Open-Mixer/fixture
  mkdir -p "$API/repos/Open-Mixer"; rm -f "$API/repos/Open-Mixer/fixture"
  [ "$1" = ABSENT ] || printf '%s\n' "$1" > "$API/repos/Open-Mixer/fixture"
}
PUB='{"visibility":"public","topics":[]}'
PUB_STAYS='{"visibility":"public","topics":["audio","stays-private"]}'
INT='{"visibility":"internal","topics":[]}'
PRIV='{"visibility":"private","topics":["audio"]}'
STAYS='{"visibility":"private","topics":["audio","stays-private"]}'
# every run starts with no CI repository and no token: the arms set what they need; ANSWER is GitHub's reply
run() { # <expected exit> <name> <output must match, or ''> -- <env...> -- <args...>
  local want=$1 name=$2 pat=$3 envs=() out rc=0 a=$PUB; shift 4
  while [ "$1" != -- ]; do case "$1" in ANSWER=*) a=${1#ANSWER=} ;; *) envs+=("$1") ;; esac; shift; done; shift
  answer "$a"
  out=$(env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u GH_TOKEN -u GITHUB_TOKEN PATH="$NOGH" GITHUB_API_URL="file://$API" \
    "${envs[@]}" bash "$chk" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL $name: exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  if [ -n "$pat" ] && ! grep -qE "$pat" <<<"$out"; then echo "FAIL $name: exit $rc but no line matching [$pat]"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  echo "ok $name (exit $rc)"
}
T=GH_TOKEN=fixture-token
printf 'a change\n\nsee openmixer''-ops for the plan\n' > "$tmp/bad"
printf 'a change\n\nthe pins check: every declared pin still resolves\n' > "$tmp/clean"
skip='Open-Mixer/fixture is private and carries the topic stays-private: the public-repo check does not apply'
R=(--repo Open-Mixer/fixture)

# the message mode: the five arms of the ruling, then the refusals
run 1 "public, a private ref in the message: red"            '' -- $T ANSWER="$PUB" -- "${R[@]}" --msg-file "$tmp/bad"
run 0 "public, clean message: green"                         '' -- $T ANSWER="$PUB" -- "${R[@]}" --msg-file "$tmp/clean"
run 1 "private without the topic is checked: red"            '' -- $T ANSWER="$PRIV" -- "${R[@]}" --msg-file "$tmp/bad"
run 0 "private with stays-private: green, skip line"         "$skip" -- $T ANSWER="$STAYS" -- "${R[@]}" --msg-file "$tmp/bad"
run 1 "public with stays-private is still checked: red"      '' -- $T ANSWER="$PUB_STAYS" -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "the lookup fails: refused by name"                    'REFUSED.*Open-Mixer/fixture' -- $T ANSWER=ABSENT -- "${R[@]}" --msg-file "$tmp/bad"
run 1 "internal is checked: red"                             '' -- $T ANSWER="$INT" -- "${R[@]}" --msg-file "$tmp/bad"
run 1 "a topic that only contains the word is not the topic" '' -- $T ANSWER='{"visibility":"private","topics":["stays-private-not"]}' -- "${R[@]}" --msg-file "$tmp/bad"
run 0 "GITHUB_TOKEN serves when GH_TOKEN is unset"           "$skip" -- GITHUB_TOKEN=fixture-token ANSWER="$STAYS" -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "no token: refused by name"                            'REFUSED.*GH_TOKEN' -- ANSWER="$STAYS" -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "an empty token: refused by name"                      'REFUSED.*GH_TOKEN' -- GH_TOKEN= ANSWER="$STAYS" -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "the lookup answers nothing: refused by name"          'REFUSED.*Open-Mixer/fixture' -- $T ANSWER= -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "the lookup answers no JSON: refused by name"          'REFUSED.*Open-Mixer/fixture' -- $T ANSWER=private -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "the answer is not an object: refused by name"         'REFUSED.*Open-Mixer/fixture' -- $T ANSWER='["private"]' -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "an unknown visibility: refused by name"               'REFUSED.*Open-Mixer/fixture' -- $T ANSWER='{"visibility":"secret","topics":["stays-private"]}' -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "no visibility: refused by name"                       'REFUSED.*Open-Mixer/fixture' -- $T ANSWER='{"topics":["stays-private"]}' -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "topics not a list: refused by name"                   'REFUSED.*Open-Mixer/fixture' -- $T ANSWER='{"visibility":"private","topics":null}' -- "${R[@]}" --msg-file "$tmp/bad"
run 2 "no --repo and no CI repository: refused by name"      'REFUSED.*--repo' -- $T ANSWER="$STAYS" -- --msg-file "$tmp/bad"
run 2 "--repo without a value: refused by name"              'REFUSED.*--repo' -- $T ANSWER="$STAYS" -- --msg-file "$tmp/bad" --repo
run 2 "--repo that is not owner/repo: refused by name"       'REFUSED.*owner/repo' -- $T ANSWER="$STAYS" -- --repo fixture --msg-file "$tmp/bad"
run 0 "--repo after the file is read (the old check ignored it there)" "$skip" -- $T ANSWER="$STAYS" -- --msg-file "$tmp/bad" "${R[@]}"
run 0 "in CI the target is GITHUB_REPOSITORY"                "$skip" -- $T ANSWER="$STAYS" GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --msg-file "$tmp/bad"
run 2 "in CI too, a failing lookup is refused"               'REFUSED' -- $T ANSWER=ABSENT GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --msg-file "$tmp/bad"

# the tree mode and the commit range mode; with no --repo and no CI repository the target is the tree's origin
git init -q "$tmp/t"; g() { git -C "$tmp/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
printf '# x\n\nsee openmixer''-ops\n' > "$tmp/t/a.md"; g add -A; g commit -q -m base; g tag base
g commit -q --allow-empty -m 'a change' -m 'see openmixer''-ops'
run 2 "tree, no --repo and no origin: refused by name"       'REFUSED' -- $T ANSWER="$STAYS" -- "$tmp/t"
g remote add origin https://github.com/Open-Mixer/fixture.git
run 1 "tree, public origin: red"                             '' -- $T ANSWER="$PUB" -- "$tmp/t"
run 1 "tree, private origin without the topic: red"          '' -- $T ANSWER="$PRIV" -- "$tmp/t"
run 0 "tree, private + stays-private: green, skip line"      "$skip" -- $T ANSWER="$STAYS" -- "$tmp/t"
run 1 "tree, public + stays-private: red"                    '' -- $T ANSWER="$PUB_STAYS" -- "$tmp/t"
run 2 "tree, no token: refused by name"                      'REFUSED.*GH_TOKEN' -- ANSWER="$STAYS" -- "$tmp/t"
run 0 "tree, --repo wins over the origin"                    "$skip" -- $T ANSWER="$STAYS" -- "${R[@]}" "$tmp/t"
g remote set-url origin git@github.com:Open-Mixer/fixture
run 0 "tree, an ssh origin without .git is read"             "$skip" -- $T ANSWER="$STAYS" -- "$tmp/t"
g remote set-url origin https://example.invalid/x/y.git
run 2 "tree, an origin that is not GitHub: refused by name"  'REFUSED' -- $T ANSWER="$STAYS" -- "$tmp/t"
g remote set-url origin https://github.com/Open-Mixer/fixture.git
( cd "$tmp/t" || exit 1
  run 1 "messages, public origin: red"                       '' -- $T ANSWER="$PUB" -- --messages base..HEAD
  run 1 "messages, private origin without the topic: red"    '' -- $T ANSWER="$PRIV" -- --messages base..HEAD
  run 0 "messages, private + stays-private: green, skip line" "$skip" -- $T ANSWER="$STAYS" -- --messages base..HEAD
  run 2 "messages, lookup fails: refused by name"            'REFUSED' -- $T ANSWER=ABSENT -- --messages base..HEAD
  [ "$fails" = 0 ] ) || fails=1
# the opt-out alone, for a public repository's other checks (public-layout-check): it reads nothing else
run 0 "applies: public says yes"                             '^applies: yes$' -- $T ANSWER="$PUB" -- --applies "$tmp/t"
run 0 "applies: private without the topic says yes"          '^applies: yes$' -- $T ANSWER="$PRIV" -- --applies "$tmp/t"
run 0 "applies: private + stays-private says no, by name"    "$skip" -- $T ANSWER="$STAYS" -- --applies "$tmp/t"
run 0 "applies: the no is its last line"                     '^applies: no$' -- $T ANSWER="$STAYS" -- --applies "$tmp/t"
run 2 "applies: lookup fails: refused by name"               'REFUSED' -- $T ANSWER=ABSENT -- --applies "$tmp/t"
# the self-test proves the patterns, never the target: it is green in an opted-out repository's CI too, and with no token
run 0 "self-test in an opted-out repository's CI"            'every sabotage red' -- ANSWER="$STAYS" GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --self-test

# the hand exemption is gone: the reusable workflow declares no private-refs input and no job reads one, and the
# public-layout check asks the same opt-out before it reads the tree
if grep -nE '^      private-refs:|inputs\.private-refs' "$wf"; then echo "FAIL public-sources-check.yml still carries the private-refs input"; fails=1
else echo "ok the reusable workflow has no private-refs input"; fi
if grep -q 'private-refs-check/check.sh" --applies' "$layout" && grep -q 'GH_TOKEN: \${{ github.token }}' "$layout"; then echo "ok public-layout-check asks the opt-out with the run's token"
else echo "FAIL public-layout-check does not ask the opt-out with the run's token"; fails=1; fi

[ "$fails" = 0 ] || { echo "private-refs-check visibility: FAILED"; exit 1; }
echo "private-refs-check visibility: every arm as wanted"
