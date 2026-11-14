#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The commit-message-check action: the checker reads a range, refuses an attributed commit, passes a clean one, and a
# checker without its patterns is not a pass. The list beside the checker is the one list every repository reads.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/commit-message-check
chk=$act/commit-message-check.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$chk" --selftest | grep -q '^selftest: GREEN' || fail "selftest not green"

cd "$tmp"; git init -q r; cd r
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
git commit -q --allow-empty -m base; git branch -M main; git checkout -q -b topic
git commit -q --allow-empty -m "clean change"
"$chk" main..HEAD >/dev/null || fail "a clean commit was refused"
git commit -q --allow-empty -m "change" -m "Co-Authored""-By: Claude <noreply@anthro""pic.com>"
if "$chk" main..HEAD >/dev/null; then fail "an attributed commit passed"; fi

# identity: the author and committer of a commit are published like its message
cn=Cla''ude; ae=noreply@anthro''pic.com; cl=cla''ude; an=anthro''pic
ident() { # name email subject: one empty commit on a fresh topic branch, author = committer unless CN/CE are set
  git checkout -q main; git branch -q -D t 2>/dev/null || true; git checkout -q -b t
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME="${CN:-$1}" GIT_COMMITTER_EMAIL="${CE:-$2}" \
    git commit -q --allow-empty -m "$3"
}
ident "Pau Aliagas" linuxnow@gmail.com "ordinary change"
CE=commits@openmixer.org ident "Pau Aliagas" linuxnow@gmail.com "ordinary change"
"$chk" main..HEAD >/dev/null || fail "ordinary author and committer were refused"
ident GitHub noreply@github.com "Merge pull request #393 from Open-Mixer/hostd-385-fix"
"$chk" main..HEAD >/dev/null || fail "a GitHub merge was refused"
ident "$cn" "$ae" "ordinary change"
if "$chk" main..HEAD >/dev/null; then fail "a commit authored by $cn passed"; fi
CN=$cn CE=$ae ident "Pau Aliagas" linuxnow@gmail.com "ordinary change"
if "$chk" main..HEAD >/dev/null; then fail "a commit committed by $cn passed"; fi
ident "Pau Aliagas" "bot@$an.com" "ordinary change"
if "$chk" main..HEAD >/dev/null; then fail "a commit with an $an.com address passed"; fi
ident GitHub noreply@github.com "Merge pull request #393 from Open-Mixer/${cl}/hostd-385-fix"
if "$chk" main..HEAD >/dev/null; then fail "a merge of a ${cl}/ branch passed"; fi
ident GitHub noreply@github.com "Merge branch '${cl}/x' into main"
if "$chk" main..HEAD >/dev/null; then fail "a local merge of a ${cl}/ branch passed"; fi
ident GitHub noreply@github.com "Merge pull request #5 from Open-Mixer/fix/.${cl}-dir-note"
"$chk" main..HEAD >/dev/null || fail "a branch that only mentions .${cl} was refused"
git checkout -q main

# sabotage: the same commit against an empty pattern list must not read as a hit, and a missing list is exit 2
echo '{"markers": [], "identity": {"pattern": "(?!)"}, "merge-branch": {"pattern": "(?!)"}}' > "$tmp/empty.json"
COMMIT_MESSAGE_PATTERNS="$tmp/empty.json" "$chk" main..HEAD >/dev/null || fail "sabotage setup: empty list should find nothing"
echo "sabotage: the empty list is blind, as the selftest expects"
rc=0; COMMIT_MESSAGE_PATTERNS="$tmp/none.json" "$chk" main..HEAD >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a missing pattern list gave $rc, not 2"

# the stub every repository copies into .githooks/commit-msg carries the licence lines a repository's own SPDX check
# reads in a file's first lines (2026-11-03: omx-panel's make spdx went red on the copy)
head -4 "$act/commit-msg" | grep -q '^# SPDX-License-Identifier: GPL-3.0-or-later$' || fail "the stub has no SPDX line"
head -4 "$act/commit-msg" | grep -q '^# Copyright (C) ' || fail "the stub has no copyright line"

# the stub finds its checker: cloned at v1 on first use, fetched at v1 again once its last fetch is stale, and with no
# checker anywhere it refuses the commit and says so (it exited 127, unnamed, before)
stub=$act/commit-msg
git init -q "$tmp/o"; cp -r "$here/.github" "$tmp/o/"
G="git -C $tmp/o -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false -c tag.gpgsign=false"
# the tag v1 the old stubs read stays on a frozen commit; the release line openmixer-v1 is a branch that moves ahead of it
$G add -A; $G commit -qm frozen; $G tag v1; $G commit -q --allow-empty -m one; $G branch -f openmixer-v1
git clone -q --bare "$tmp/o" "$tmp/o.git"
mkdir -p "$tmp/home" "$tmp/s/r"; git -C "$tmp/s/r" init -q
echo "clean change" > "$tmp/msg"; printf 'change\n\nCo-Authored''-By: Claude <noreply@anthro''pic.com>\n' > "$tmp/bad"
# the house identity: the commit-msg mode judges who commits as well as what the message says
HOUSE=(GIT_AUTHOR_NAME="Pau Aliagas" GIT_AUTHOR_EMAIL=linuxnow@gmail.com GIT_COMMITTER_NAME="Pau Aliagas" GIT_COMMITTER_EMAIL=commits@openmixer.org)
hook() { (cd "$tmp/s/r" && env -u OPENMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB_URL "${HOUSE[@]}" HOME=$tmp/home OPENMIXER_DOTGITHUB_URL=$1 sh "$stub" "$2"); }
rc=0; out=$(hook "$tmp/none.git" "$tmp/msg" 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "with no checker anywhere the stub gave $rc, not 1"
grep -q 'no commit-message checker at' <<<"$out" || fail "with no checker anywhere the stub did not say why: $out"
[ ! -e "$tmp/home/.cache/omx/openmixer-dotgithub" ] || fail "a failed clone left a cache behind"
hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>&1 || fail "the stub did not clone openmixer-v1 and pass a clean message"
cache=$tmp/home/.cache/omx/openmixer-dotgithub
[ "$(git -C "$cache" rev-parse HEAD)" = "$(git -C "$tmp/o" rev-parse openmixer-v1)" ] || fail "the first use did not clone openmixer-v1 (it read the frozen tag v1?)"
if hook "$tmp/o.git" "$tmp/bad" >/dev/null 2>&1; then fail "the stub passed an attributed message"; fi
touch "$tmp/o/moved"; $G add -A; $G commit -qm two; $G branch -f openmixer-v1; git -C "$tmp/o" push -q --force "$tmp/o.git" refs/heads/openmixer-v1
touch -d '20 minutes ago' "$cache/.git/FETCH_HEAD"
hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>&1 || fail "the refreshed stub refused a clean message"
[ "$(git -C "$cache" rev-parse HEAD)" = "$(git -C "$tmp/o" rev-parse openmixer-v1)" ] || fail "a stale cache was not fetched at the moved openmixer-v1"
mv "$tmp/o.git" "$tmp/o.away"; touch -d '20 minutes ago' "$cache/.git/FETCH_HEAD"
rc=0; hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && grep -q 'could not fetch openmixer-v1' "$tmp/err" || fail "an unreachable remote did not fall back to the cached checker and say so (rc $rc)"

# the env var moved to the openmixer name; for one transitional pass the stub also reads the old FREEMIXER_ names, the
# new name winning, the old one read with a one-line notice (the old names are removed in a later pass)
mv "$tmp/o.away" "$tmp/o.git"
for w in new old; do mkdir -p "$tmp/dg$w/.github/actions/commit-message-check"
  printf '#!/bin/sh\necho "checker=%s"\n' "$w" > "$tmp/dg$w/.github/actions/commit-message-check/commit-message-check.sh"
  chmod +x "$tmp/dg$w/.github/actions/commit-message-check/commit-message-check.sh"; done
envhook() { (cd "$tmp/s/r" && env -u OPENMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB -u OPENMIXER_DOTGITHUB_URL -u FREEMIXER_DOTGITHUB_URL "${HOUSE[@]}" HOME=$tmp/home "$@" sh "$stub" "$tmp/msg" 2>"$tmp/err"); }
out=$(envhook OPENMIXER_DOTGITHUB="$tmp/dgnew") || fail "the new OPENMIXER_DOTGITHUB was not read"
[ "$out" = "checker=new" ] && [ ! -s "$tmp/err" ] || fail "the new name gave '$out' / '$(cat "$tmp/err")'"
out=$(envhook FREEMIXER_DOTGITHUB="$tmp/dgold") || fail "the old FREEMIXER_DOTGITHUB was not read"
[ "$out" = "checker=old" ] || fail "the old name gave '$out'"
grep -q 'FREEMIXER_DOTGITHUB is deprecated, use OPENMIXER_DOTGITHUB' "$tmp/err" || fail "the old name was read without a notice"
out=$(envhook OPENMIXER_DOTGITHUB="$tmp/dgnew" FREEMIXER_DOTGITHUB="$tmp/dgold") || fail "both names set: stub failed"
[ "$out" = "checker=new" ] || fail "both names set: the new did not win ('$out')"
rm -rf "$tmp/home/.cache"
envhook FREEMIXER_DOTGITHUB_URL="$tmp/o.git" >/dev/null || fail "the old FREEMIXER_DOTGITHUB_URL was not read"
grep -q 'FREEMIXER_DOTGITHUB_URL is deprecated, use OPENMIXER_DOTGITHUB_URL' "$tmp/err" || fail "the old URL name was read without a notice"
rm -rf "$tmp/home/.cache"
envhook OPENMIXER_DOTGITHUB_URL="$tmp/o.git" FREEMIXER_DOTGITHUB_URL="$tmp/none.git" >/dev/null || fail "both URL names set: the new did not win"

# the stub as git runs it: a real commit in a throwaway repository whose core.hooksPath holds the stub. git exports GIT_DIR
# and GIT_INDEX_FILE to a hook, and the stub's cache commands must not read them as the cache's: before, every fetch ran
# against the committing repository, failed, and every repository kept the checker its cache first cloned
rm -rf "$tmp/home/.cache" "$tmp/w" "$tmp/hooks"; mkdir -p "$tmp/hooks"; cp "$stub" "$tmp/hooks/commit-msg"; chmod +x "$tmp/hooks/commit-msg"
# a linked worktree, as every working branch is: there git exports an ABSOLUTE GIT_DIR (.git/worktrees/<name>); in a plain
# checkout it is a relative .git, which after git -C <cache> happens to name the cache's own
git init -q "$tmp/w"; git -C "$tmp/w" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m base
git -C "$tmp/w" worktree add -q --detach "$tmp/wt"
realcommit() { (cd "$tmp/wt" && env -u OPENMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB_URL "${HOUSE[@]}" \
  HOME=$tmp/home OPENMIXER_DOTGITHUB_URL=$tmp/o.git git -c core.hooksPath="$tmp/hooks" -c commit.gpgsign=false commit -q --allow-empty "$@") 2>"$tmp/rerr"; }
realcommit -m "clean change" || fail "a real commit through the stub refused a clean message: $(cat "$tmp/rerr")"
[ "$(git -C "$cache" rev-parse HEAD 2>/dev/null)" = "$(git -C "$tmp/o" rev-parse openmixer-v1)" ] || fail "the first real commit did not clone openmixer-v1 into the cache"
touch "$tmp/o/moved2"; $G add -A; $G commit -qm three; $G branch -f openmixer-v1; git -C "$tmp/o" push -q --force "$tmp/o.git" refs/heads/openmixer-v1
touch -d '20 minutes ago' "$cache/.git/FETCH_HEAD"
realcommit -m "another clean change" || fail "a real commit after the line moved was refused: $(cat "$tmp/rerr")"
! grep -q 'could not fetch' "$tmp/rerr" || fail "inside a real hook the stub could not fetch: $(cat "$tmp/rerr")"
[ "$(git -C "$cache" rev-parse HEAD)" = "$(git -C "$tmp/o" rev-parse openmixer-v1)" ] || fail "inside a real hook a stale cache was not fetched at the moved openmixer-v1"
[ "$(git -C "$tmp/wt" rev-list --count HEAD)" = 3 ] || fail "the committing worktree is not where the two commits are"
if realcommit -m "change" -m "Co-Authored""-By: Claude <noreply@anthro""pic.com>"; then fail "a real commit with an attributed message passed"; fi

# the commit-msg mode judges a message before the commit exists, so a repository whose lanes push from post-commit never
# publishes one it refuses: the message is also read by private-refs-check (no private repository, issue, machine or path),
# and the commit's author and committer must be the house's (author Pau Aliagas <linuxnow@gmail.com>, committer email
# commits@openmixer.org), the rule each repository's own author hook used to carry
cd "$tmp/r"
printf 'a change\n\nthe pins check: every declared pin still resolves\n' > "$tmp/m-clean"
# the house identity is judged only in a repository whose origin names a house org (Open-Mixer or FreeMixer): a fixture
# repository with no origin, or a foreign one, commits as anyone and the hook says so; message patterns still apply
NOTHOUSE=(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid)
rc=0; env "${NOTHOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/h-err" || rc=$?
[ "$rc" = 0 ] && grep -q 'house: not judged (no house origin)' "$tmp/h-err" || fail "a repository with no origin judged the house identity (rc $rc): $(cat "$tmp/h-err")"
git remote add origin https://github.com/someone/elsewhere.git
rc=0; env "${NOTHOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/h-err" || rc=$?
[ "$rc" = 0 ] && grep -q 'house: not judged (no house origin)' "$tmp/h-err" || fail "a repository with a foreign origin judged the house identity (rc $rc): $(cat "$tmp/h-err")"
git remote set-url origin git@github.com:FreeMixer/house-fixture.git
if env "${NOTHOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>&1; then fail "a FreeMixer origin let a foreign identity commit"; fi
git remote set-url origin https://github.com/Open-Mixer/house-fixture.git
env "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null || fail "a clean message from the house identity was refused"
for line in 'the check in harness''/pins-check.sh' 'see openmixer''#1580' 'built on ms''i overnight'; do
  printf 'a change\n\n%s\n' "$line" > "$tmp/m-bad"
  if env "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-bad" >/dev/null 2>&1; then fail "a message naming [$line] passed the commit-msg mode"; fi
done
if env "${HOUSE[@]}" GIT_AUTHOR_NAME=Someone GIT_AUTHOR_EMAIL=someone@example.invalid "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>&1; then
  fail "a commit authored by someone other than the house's passed the commit-msg mode"; fi
if env "${HOUSE[@]}" GIT_COMMITTER_EMAIL=linuxnow@gmail.com "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>&1; then
  fail "a committer email other than commits@openmixer.org passed the commit-msg mode"; fi
rc=0; env "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-bad" >/dev/null 2>"$tmp/m-err" || rc=$?
[ "$rc" = 1 ] && grep -q 'private' "$tmp/m-err" || fail "a refused message did not say why on stderr (rc $rc): $(cat "$tmp/m-err")"

echo "commit-message-check: ok"
