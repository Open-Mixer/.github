#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The private-refs check runs on every repository unless it opts out, and the opt-out is read from GitHub, live, in one
# lookup: only a repository that is private AND carries the topic stays-private is skipped, with a line naming it. A
# topic never exempts a public repository, a private one without the topic is checked, and a target whose visibility and
# topics cannot be read, or a run that names no target, is refused by name (exit 2), never a silent pass.
# A stub gh on PATH stands in for GitHub; it answers what STUB_OUT holds, or fails when STUB_FAIL is set.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
chk=$here/check.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fails=0
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || { echo "gh: stubbed failure" >&2; exit 1; }
printf '%s\n' "${STUB_OUT-}"
GH
chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
PUB='{"t":[],"v":"public"}'
PUB_STAYS='{"t":["audio","stays-private"],"v":"public"}'
INT='{"t":[],"v":"internal"}'
PRIV='{"t":["audio"],"v":"private"}'
STAYS='{"t":["audio","stays-private"],"v":"private"}'
# every run starts from no CI repository: the arms that want one set it themselves
run() { # <expected exit> <name> <stdout/stderr must match, or ''> -- <env...> -- <args...>
  local want=$1 name=$2 pat=$3 envs=() out rc=0; shift 4
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/gh.log" \
    "${envs[@]}" bash "$chk" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL $name: exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  if [ -n "$pat" ] && ! grep -qE "$pat" <<<"$out"; then echo "FAIL $name: exit $rc but no line matching [$pat]"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  echo "ok $name (exit $rc)"
}
printf 'a change\n\nsee openmixer''-ops for the plan\n' > "$tmp/bad"
printf 'a change\n\nthe pins check: every declared pin still resolves\n' > "$tmp/clean"
skip='Open-Mixer/fixture is private and carries the topic stays-private: the public-repo check does not apply'

# the message mode
run 1 "public, a private ref in the message: red"            '' -- STUB_OUT="$PUB" -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 0 "public, clean message: green"                         '' -- STUB_OUT="$PUB" -- --repo Open-Mixer/fixture --msg-file "$tmp/clean"
run 1 "internal is checked: red"                             '' -- STUB_OUT="$INT" -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 1 "private without the topic is checked: red"            '' -- STUB_OUT="$PRIV" -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 1 "public with stays-private is still checked: red"      '' -- STUB_OUT="$PUB_STAYS" -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 0 "private with stays-private: green, skip line"         "$skip" -- STUB_OUT="$STAYS" -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
grep -qx "api repos/Open-Mixer/fixture --jq {v:.visibility,t:.topics}" "$tmp/gh.log" ||
  { echo "FAIL visibility and topics were not read in one lookup: $(sort -u "$tmp/gh.log")"; fails=1; }
run 1 "a topic that only contains the word is not the topic" '' -- STUB_OUT='{"t":["stays-private-not"],"v":"private"}' -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "the lookup fails: refused by name"                    'REFUSED.*Open-Mixer/fixture' -- STUB_OUT="$STAYS" STUB_FAIL=1 -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "the lookup answers nothing: refused by name"          'REFUSED.*Open-Mixer/fixture' -- STUB_OUT= -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "the lookup answers no JSON: refused by name"          'REFUSED.*Open-Mixer/fixture' -- STUB_OUT=private -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "an unknown visibility: refused by name"               'REFUSED.*Open-Mixer/fixture' -- STUB_OUT='{"t":["stays-private"],"v":"secret"}' -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "no visibility: refused by name"                       'REFUSED.*Open-Mixer/fixture' -- STUB_OUT='{"t":["stays-private"],"v":null}' -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "topics not a list: refused by name"                   'REFUSED.*Open-Mixer/fixture' -- STUB_OUT='{"t":null,"v":"private"}' -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "no --repo and no CI repository: refused by name"      'REFUSED.*--repo' -- STUB_OUT="$STAYS" -- --msg-file "$tmp/bad"
run 2 "--repo without a value: refused by name"              'REFUSED.*--repo' -- STUB_OUT="$STAYS" -- --msg-file "$tmp/bad" --repo
run 2 "--repo that is not owner/repo: refused by name"       'REFUSED.*owner/repo' -- STUB_OUT="$STAYS" -- --repo fixture --msg-file "$tmp/bad"
run 0 "in CI the target is GITHUB_REPOSITORY"                "$skip" -- STUB_OUT="$STAYS" GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --msg-file "$tmp/bad"
run 2 "in CI too, a failing lookup is refused"               'REFUSED' -- STUB_FAIL=1 GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --msg-file "$tmp/bad"

# the tree mode and the commit range mode; with no --repo and no CI repository the target is the tree's origin
git init -q "$tmp/t"; g() { git -C "$tmp/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
printf '# x\n\nsee openmixer''-ops\n' > "$tmp/t/a.md"; g add -A; g commit -q -m base; g tag base
g commit -q --allow-empty -m 'a change' -m 'see openmixer''-ops'
run 2 "tree, no --repo and no origin: refused by name"       'REFUSED' -- STUB_OUT="$STAYS" -- "$tmp/t"
g remote add origin https://github.com/Open-Mixer/fixture.git
run 1 "tree, public origin: red"                             '' -- STUB_OUT="$PUB" -- "$tmp/t"
run 1 "tree, private origin without the topic: red"          '' -- STUB_OUT="$PRIV" -- "$tmp/t"
run 0 "tree, private + stays-private: green, skip line"      "$skip" -- STUB_OUT="$STAYS" -- "$tmp/t"
run 0 "tree, --repo wins over the origin"                    "$skip" -- STUB_OUT="$STAYS" -- --repo Open-Mixer/fixture "$tmp/t"
g remote set-url origin git@github.com:Open-Mixer/fixture
run 0 "tree, an ssh origin without .git is read"             "$skip" -- STUB_OUT="$STAYS" -- "$tmp/t"
g remote set-url origin https://example.invalid/x/y.git
run 2 "tree, an origin that is not GitHub: refused by name"  'REFUSED' -- STUB_OUT="$STAYS" -- "$tmp/t"
g remote set-url origin https://github.com/Open-Mixer/fixture.git
( cd "$tmp/t" || exit 1
  run 1 "messages, public origin: red"                       '' -- STUB_OUT="$PUB" -- --messages base..HEAD
  run 1 "messages, private origin without the topic: red"    '' -- STUB_OUT="$PRIV" -- --messages base..HEAD
  run 0 "messages, private + stays-private: green, skip line" "$skip" -- STUB_OUT="$STAYS" -- --messages base..HEAD
  run 2 "messages, lookup fails: refused by name"            'REFUSED' -- STUB_FAIL=1 -- --messages base..HEAD
  [ "$fails" = 0 ] ) || fails=1
# the self-test proves the patterns, never the target: it is green in an opted-out repository's CI too
run 0 "self-test in an opted-out repository's CI"            'every sabotage red' -- STUB_OUT="$STAYS" GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture -- --self-test

[ "$fails" = 0 ] || { echo "private-refs-check visibility: FAILED"; exit 1; }
echo "private-refs-check visibility: every arm as wanted"
