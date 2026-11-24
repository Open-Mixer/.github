#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The commit-identity-check action over a range: a committer of linuxnow@gmail.com and an unverified commit are both
# named, a good range passes, a bad commit that is not the head is still found (a head-only reader is blind to it), and
# the expected emails are written once, in action.yml. GitHub is a fake `gh` that answers from a fixture file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/commit-identity-check
chk=$act/commit-identity-check.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$chk" --selftest | grep -q '^selftest: GREEN' || fail "selftest not green"

# the defaults live in action.yml alone
A=$(sed -n '/^  author-email:/,/^  committer-email:/p' "$act/action.yml" | sed -n 's/^    default: //p')
C=$(sed -n '/^  committer-email:/,/^  token:/p' "$act/action.yml" | sed -n 's/^    default: //p')
[ "$A" = linuxnow@gmail.com ] && [ "$C" = commits@openmixer.org ] || fail "action.yml defaults are '$A' '$C'"
! grep -v '^# ' "$chk" | grep -qE 'linuxnow@gmail|commits@openmixer' || fail "the script hard-codes an expected email"

# fake gh: `gh api repos/o/r/commits/<sha> --jq ...` -> "<verified> <reason>" from $GHFIX/<sha>, absent = no answer
mkdir "$tmp/bin" "$tmp/fix"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/sh
sha=${2##*/}
[ -f "$GHFIX/$sha" ] && cat "$GHFIX/$sha" || { echo "gh: HTTP 404" >&2; exit 1; }
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GHFIX="$tmp/fix" GH_REPO=o/r

git init -q "$tmp/r"; cd "$tmp/r" || exit 1
git config user.name t; git config commit.gpgsign false
mk() { # author-email committer-email verified(true|false) subject -> sha in $sha
  GIT_AUTHOR_EMAIL=$1 GIT_COMMITTER_EMAIL=$2 git commit -q --allow-empty -m "$4"
  sha=$(git rev-parse HEAD)
  if [ "$3" = true ]; then echo "true valid" > "$tmp/fix/$sha"; else echo "false bad_email" > "$tmp/fix/$sha"; fi
}
A=linuxnow@gmail.com; C=commits@openmixer.org
run() { "$chk" --author-email "$A" --committer-email "$C" "$@"; }
mk x@example.invalid x@example.invalid true base; git branch -M main; git checkout -q -b topic

# a good range
mk $A $C true one; mk $A $C true two
run main..HEAD >"$tmp/out" || fail "a good range was refused: $(cat "$tmp/out")"

# the committer is linuxnow@gmail.com, and one commit is unverified: both named, neither is the head
mk $A $A true wrong-committer; wc=$sha
mk $A $C false unverified; uv=$sha
mk $A $C true head-is-good
rc=0; run main..HEAD >"$tmp/out" || rc=$?
[ "$rc" = 1 ] || fail "a bad range gave $rc, not 1"
grep -q "^$wc: \[committer-email\] $A (expected $C)" "$tmp/out" || fail "the wrong committer is not named: $(cat "$tmp/out")"
grep -q "^$uv: \[verified\] false" "$tmp/out" || fail "the unverified commit is not named: $(cat "$tmp/out")"
! grep -q "^$(git rev-parse HEAD):" "$tmp/out" || fail "the good head was named"

# a wrong author is named too
git checkout -q main; git checkout -q -b t1
mk other@example.invalid $C true wrong-author
run main..HEAD >"$tmp/out" && fail "a wrong author passed"
grep -q "^$sha: \[author-email\] other@example.invalid" "$tmp/out" || fail "the wrong author is not named"

# a base that moved on: a good topic still passes, and what the base gained since is not charged to it
git checkout -q main; git checkout -q -b t3; mk $A $C true mine
git checkout -q main; mk wrong@example.invalid wrong@example.invalid false base-gained-after
git checkout -q t3
run main..HEAD >/dev/null || fail "a good range on a moved base was refused"

# no answer from the API is exit 2, never a pass
git checkout -q t3; mk $A $C true ghost; rm "$tmp/fix/$sha"
rc=0; run main..HEAD >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unanswered API gave $rc, not 2"
# an unreadable range is exit 2
rc=0; run nosuch..HEAD >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unreadable range gave $rc, not 2"

# empty flags take the defaults from action.yml: the house pair passes, a wrong committer is red
git checkout -q topic~0
"$chk" --author-email "" --committer-email "" "main..$wc~1" >/dev/null || fail "empty flags did not take the action defaults"
rc=0; "$chk" --author-email "" --committer-email "" "main..$wc" >/dev/null || rc=$?
[ "$rc" = 1 ] || fail "empty flags with a wrong committer gave $rc, not 1"

# the workflow's inputs reach the action, the switch is ON by default (.github#190) and false skips the job, the action takes env not a splice
python3 -I - "$here" <<'PY' || fail "workflow wiring"
import sys, yaml
h = sys.argv[1]
w = yaml.safe_load(open(h + "/.github/workflows/public-sources-check.yml"))
i = w[True]["workflow_call"]["inputs"]
assert i["commit-identity"]["default"] is True, "the gate is on everywhere: the switch must default on (.github#190)"
assert i["author-email"]["default"] == "" and i["committer-email"]["default"] == "", "no second copy of the emails"
j = w["jobs"]["commit-identity"]
assert "inputs.commit-identity" in j["if"], "the job is not skipped when off"
st = [s for s in j["steps"] if "commit-identity-check" in s.get("uses", "")][0]["with"]
assert st["author-email"] == "${{ inputs.author-email }}" and st["committer-email"] == "${{ inputs.committer-email }}", st
a = open(h + "/.github/actions/commit-identity-check/action.yml").read()
assert "'${{ inputs.author-email }}'" not in a and "'${{ inputs.committer-email }}'" not in a, "inputs spliced into the script"
assert 'AUTHOR_EMAIL: ${{ inputs.author-email }}' in a and 'COMMITTER_EMAIL: ${{ inputs.committer-email }}' in a
PY

# a GitHub-made merge commit is named with the fix: a local signed merge, not a rebase
git checkout -q -b t5 topic~3 2>/dev/null || git checkout -q -b t5 main
mk noreply@github.com noreply@github.com true "Merge branch main into t5"
rc=0; run main..HEAD >"$tmp/out" || rc=$?
grep -q 'merge the base into the branch LOCALLY with a plain signed git merge' "$tmp/out" || fail "a GitHub-made commit got no local-merge advice: $(cat "$tmp/out")"
! grep -qi 'rebase' <(grep -v 'never rebase' "$tmp/out") || fail "the advice names a rebase"

# sabotage: the checker with a head-only reader (rev-list -1) is green on a range whose bad commits are not the head,
# which the real one names; the assertion that both are named goes red on it
git checkout -q topic
sed 's/git rev-list "\$range"/git rev-list -1 "$range"/' "$chk" > "$tmp/head-only.sh"; chmod +x "$tmp/head-only.sh"
grep -q 'rev-list -1' "$tmp/head-only.sh" || fail "sabotage setup: the head-only copy was not made"
"$tmp/head-only.sh" --author-email "$A" --committer-email "$C" main..HEAD >"$tmp/out" || fail "sabotage setup: the head-only reader should read clean"
if grep -q "^$wc:" "$tmp/out" && grep -q "^$uv:" "$tmp/out"; then fail "the head-only reader named both bad commits"; fi
echo "sabotage: a head-only reader is blind to both bad commits (red on the naming assertion), the range reader names them"
# ---- the UPSTREAM EXEMPTION (../upstream-exempt, the one source): a fork's range holds its upstream's own commits, authored by others and
# unverified. They pass ONLY when --upstream-url is an exact listed URL, git does not rewrite it, it is fetched, and the commit is an ancestor
# of the fetched ref. The test fetches file:// URLs of its own bare repos, from a COPY of the actions whose list names them (no insteadOf).
mkdir -p "$tmp/act"; cp -r "$here/.github/actions/commit-identity-check" "$here/.github/actions/upstream-exempt" "$tmp/act/"
chk2=$tmp/act/commit-identity-check/commit-identity-check.sh
UPU=file://$tmp/up.git
printf '%s\n' "$UPU" > "$tmp/act/upstream-exempt/upstream-allowed.txt"
mkup() { # <bare dir>: two commits of a third party, unverified
  rm -rf "$tmp/$1" "$tmp/$1-w"; git init -q -b main "$tmp/$1-w"; git -C "$tmp/$1-w" config user.name t; git -C "$tmp/$1-w" config commit.gpgsign false
  for i in 1 2; do GIT_AUTHOR_EMAIL=third@example.org GIT_COMMITTER_EMAIL=third@example.org git -C "$tmp/$1-w" commit -q --allow-empty -m "upstream $1 $i"
    echo "false unsigned" > "$tmp/fix/$(git -C "$tmp/$1-w" rev-parse HEAD)"; done
  git clone -q --bare "$tmp/$1-w" "$tmp/$1"; rm -rf "$tmp/$1-w"
}
mkup up.git; mkup evil.git; git clone -q --bare "$tmp/up.git" "$tmp/up3.git"   # up3: the same commits at an URL NOT on the list
# fork <name> <source bare>: main (house base), a branch of one own commit plus our signed merge of the source's history
fork() {
  rm -rf "$tmp/$1"; git init -q -b main "$tmp/$1"; cd "$tmp/$1" || exit 1; git config user.name t; git config commit.gpgsign false
  mk $A $C true "fork base"
  git fetch -q "$tmp/$2" main:upmain; git checkout -q -b topic; mk $A $C true "own one"
  GIT_AUTHOR_EMAIL=$A GIT_COMMITTER_EMAIL=$C git merge -q --allow-unrelated-histories --no-ff upmain -m "own merge of upstream"
  echo "true valid" > "$tmp/fix/$(git rev-parse HEAD)"
}
runx() { "${CHK:-$chk2}" --author-email "$A" --committer-email "$C" --upstream-url "$1" main..HEAD; }
fork f1 up.git
runx "$UPU" >"$tmp/out" || fail "an upstream history in the range was refused with the listed URL: $(cat "$tmp/out")"
grep -q 'upstream commits exempt' "$tmp/out" || fail "the exempt count is not said"
rc=0; "$chk2" --author-email "$A" --committer-email "$C" main..HEAD >"$tmp/out" || rc=$?
[ "$rc" = 1 ] || fail "without --upstream-url the upstream commits passed (rc $rc)"
# our own commit with a wrong author, and our own merge with a wrong committer, on top of upstream: named, nothing else
mk wrong@example.invalid $C true "own wrong author"; ow=$sha
rc=0; runx "$UPU" >"$tmp/out" || rc=$?
[ "$rc" = 1 ] && grep -q "^$ow: \[author-email\] wrong@example.invalid" "$tmp/out" && [ "$(grep -c '^[0-9a-f]\{40\}: \[' "$tmp/out")" = 1 ] || fail "our own wrong-author commit was not the only offence: $(cat "$tmp/out")"
git reset -q --hard HEAD~1
GIT_AUTHOR_EMAIL=$A GIT_COMMITTER_EMAIL=$A git commit -q --allow-empty -m "own bad merge-shaped commit"; echo "true valid" > "$tmp/fix/$(git rev-parse HEAD)"; ob=$(git rev-parse HEAD)
git checkout -q -b mt HEAD~1; GIT_AUTHOR_EMAIL=$A GIT_COMMITTER_EMAIL=$A git merge -q --no-ff -m "own wrong-committer merge" topic 2>/dev/null || true
git checkout -q topic; git checkout -q -B bm topic; git branch -q -f side main; git checkout -q side; mk $A $C true "side"
git checkout -q bm; GIT_AUTHOR_EMAIL=$A GIT_COMMITTER_EMAIL=$A git merge -q --no-ff -m "own wrong-committer merge" side; echo "true valid" > "$tmp/fix/$(git rev-parse HEAD)"; om=$(git rev-parse HEAD)
rc=0; runx "$UPU" >"$tmp/out" || rc=$?
[ "$rc" = 1 ] && grep -q "^$om: \[committer-email\]" "$tmp/out" || fail "our own merge with a wrong committer was exempted: $(cat "$tmp/out")"
# a URL not on the list, and look-alikes: no exemption, and the refusal says why
for bad in "file://$tmp/up3.git" "$UPU.evil" "$UPU/" "${UPU%.git}" "x$UPU" "$tmp/up.git"; do
  fork f2 up.git; rc=0; runx "$bad" >"$tmp/out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q 'no upstream exemption' "$tmp/out" || fail "URL $bad was exempted or silent: $(cat "$tmp/out")"
done
# a listed URL that url.*.insteadOf rewrites to a repository of our own unsigned commits: refused, and the sabotage copy passes them
fork f3 evil.git; git config "url.$tmp/evil.git.insteadOf" "$UPU"
rc=0; runx "$UPU" >"$tmp/out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -q 'rewritten by local url' "$tmp/out" || fail "a rewritten URL was trusted: $(cat "$tmp/out")"
# SABOTAGE: each check removed from a copy turns its arm red (the bad case passes)
sab() { # <marker> <label>: a copy of the action with that line removed or neutered
  rm -rf "$tmp/sab"; mkdir "$tmp/sab"; cp -r "$tmp/act/." "$tmp/sab/"
  case $1 in UPANC) sed -i 's/^\(.*\)# UPANC$/    exit 0   # UPANC/' "$tmp/sab/upstream-exempt/upstream-exempt.sh" ;; *) sed -i "/# $1\$/d" "$tmp/sab/upstream-exempt/upstream-exempt.sh" ;; esac
  grep -q "$1" "$tmp/sab/upstream-exempt/upstream-exempt.sh" && [ "$1" != UPANC ] && fail "sabotage $2: the sed did not remove the line"
  CHK=$tmp/sab/commit-identity-check/commit-identity-check.sh
}
fork f4 up.git; mk wrong@example.invalid $C true "own wrong author"
sab UPANC ancestor; runx "$UPU" >/dev/null 2>&1 && : || fail "sabotage: with the ancestor test removed our wrong-author commit should (wrongly) pass"
fork f5 up.git; sab UPLIST list; runx "file://$tmp/up3.git" || fail "sabotage: with the list check removed an unlisted URL should (wrongly) pass"
fork f6 evil.git; git config "url.$tmp/evil.git.insteadOf" "$UPU"; sab UPREWRITE rewrite; runx "$UPU" >/dev/null 2>&1 || fail "sabotage: with the rewrite check removed the rewritten URL should (wrongly) pass"
CHK=
echo "upstream exemption: the listed upstream's commits pass; ours (commit, merge), unlisted, look-alike and rewritten URLs are refused; each check removed turns its arm red"
echo PASS
