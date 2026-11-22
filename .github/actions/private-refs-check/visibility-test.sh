#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The private-refs check applies to a public repository only, and which one the target is comes from GitHub, live:
# a private target is skipped with a line that names it, a public or internal one is checked as before, and a target
# whose visibility cannot be read, or a run that names no target, is refused by name (exit 2), never a silent pass.
# A stub gh on PATH stands in for GitHub; it answers what STUB_VIS holds, or fails when STUB_FAIL is set.
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
printf '%s\n' "${STUB_VIS-}"
GH
chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
# every run starts from no CI context: the arms that want one set it themselves
run() { # <expected exit> <name> <stdout/stderr must match, or ''> -- <env...> -- <args...>
  local want=$1 name=$2 pat=$3 envs=() out rc=0; shift 4
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY -u PRIVATE_REFS_VISIBILITY PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/gh.log" \
    "${envs[@]}" bash "$chk" "$@" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then echo "FAIL $name: exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  if [ -n "$pat" ] && ! grep -qE "$pat" <<<"$out"; then echo "FAIL $name: exit $rc but no line matching [$pat]"; printf '%s\n' "$out" | sed 's/^/  /'; fails=1; return; fi
  echo "ok $name (exit $rc)"
}
printf 'a change\n\nsee openmixer''-ops for the plan\n' > "$tmp/bad"
printf 'a change\n\nthe pins check: every declared pin still resolves\n' > "$tmp/clean"
skip='Open-Mixer/fixture is private: the public-repo check does not apply'

# the message mode
run 1 "public repo, private ref in the message: red"         '' -- STUB_VIS=public -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 0 "public repo, clean message: green"                    '' -- STUB_VIS=public -- --repo Open-Mixer/fixture --msg-file "$tmp/clean"
run 1 "internal repo is treated as public: red"              '' -- STUB_VIS=internal -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 0 "private repo, same message: green, skip line"         "$skip" -- STUB_VIS=private -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
grep -qx 'api repos/Open-Mixer/fixture --jq .visibility' "$tmp/gh.log" || { echo "FAIL the visibility was not read from GitHub: $(cat "$tmp/gh.log")"; fails=1; }
run 2 "the lookup fails: refused by name"                    'REFUSED.*Open-Mixer/fixture' -- STUB_VIS=public STUB_FAIL=1 -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "the lookup answers nothing: refused by name"          'REFUSED.*Open-Mixer/fixture' -- STUB_VIS= -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "the lookup answers an unknown word: refused by name"  'REFUSED.*Open-Mixer/fixture' -- STUB_VIS=secret -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "no --repo and no CI repository: refused by name"      'REFUSED.*--repo' -- STUB_VIS=private -- --msg-file "$tmp/bad"
run 2 "--repo without a value: refused by name"              'REFUSED.*--repo' -- STUB_VIS=private -- --msg-file "$tmp/bad" --repo
run 2 "--repo that is not owner/repo: refused by name"       'REFUSED.*owner/repo' -- STUB_VIS=private -- --repo fixture --msg-file "$tmp/bad"
run 0 "in CI the target is GITHUB_REPOSITORY"                "$skip" -- STUB_VIS=private GITHUB_REPOSITORY=Open-Mixer/fixture -- --msg-file "$tmp/bad"
# in CI the action hands over the Actions context's own visibility; it counts only for the repository the run is in
run 0 "CI context: private, no lookup needed"                "$skip" -- STUB_FAIL=1 GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture PRIVATE_REFS_VISIBILITY=private -- --msg-file "$tmp/bad"
run 1 "CI context: public is checked"                        '' -- STUB_FAIL=1 GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture PRIVATE_REFS_VISIBILITY=public -- --msg-file "$tmp/bad"
run 1 "CI context of another repository is not trusted"      '' -- STUB_VIS=public GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/other PRIVATE_REFS_VISIBILITY=private -- --repo Open-Mixer/fixture --msg-file "$tmp/bad"
run 2 "a context outside CI is not trusted, lookup fails"    'REFUSED' -- STUB_FAIL=1 GITHUB_REPOSITORY=Open-Mixer/fixture PRIVATE_REFS_VISIBILITY=private -- --msg-file "$tmp/bad"

# the tree mode and the commit range mode; with no --repo and no CI repository the target is the tree's origin
git init -q "$tmp/t"; g() { git -C "$tmp/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
printf '# x\n\nsee openmixer''-ops\n' > "$tmp/t/a.md"; g add -A; g commit -q -m base; g tag base
g commit -q --allow-empty -m 'a change' -m 'see openmixer''-ops'
run 2 "tree, no --repo and no origin: refused by name"       'REFUSED' -- STUB_VIS=private -- "$tmp/t"
g remote add origin https://github.com/Open-Mixer/fixture.git
run 1 "tree, public origin: red"                             '' -- STUB_VIS=public -- "$tmp/t"
run 0 "tree, private origin: green, skip line"               "$skip" -- STUB_VIS=private -- "$tmp/t"
run 0 "tree, --repo wins over the origin"                    "$skip" -- STUB_VIS=private -- --repo Open-Mixer/fixture "$tmp/t"
g remote set-url origin git@github.com:Open-Mixer/fixture
run 0 "tree, an ssh origin without .git is read"             "$skip" -- STUB_VIS=private -- "$tmp/t"
g remote set-url origin https://example.invalid/x/y.git
run 2 "tree, an origin that is not GitHub: refused by name"  'REFUSED' -- STUB_VIS=private -- "$tmp/t"
g remote set-url origin https://github.com/Open-Mixer/fixture.git
( cd "$tmp/t" || exit 1
  run 1 "messages, public origin (from the tree's directory): red" '' -- STUB_VIS=public -- --messages base..HEAD
  run 0 "messages, private origin: green, skip line"         "$skip" -- STUB_VIS=private -- --messages base..HEAD
  run 2 "messages, lookup fails: refused by name"            'REFUSED' -- STUB_FAIL=1 -- --messages base..HEAD
  [ "$fails" = 0 ] ) || fails=1
# the self-test proves the patterns, never the target: it is green in a private repository's CI too
run 0 "self-test under a private CI context"                 'every sabotage red' -- STUB_FAIL=1 GITHUB_ACTIONS=true GITHUB_REPOSITORY=Open-Mixer/fixture PRIVATE_REFS_VISIBILITY=private -- --self-test

[ "$fails" = 0 ] || { echo "private-refs-check visibility: FAILED"; exit 1; }
echo "private-refs-check visibility: every arm as wanted"
