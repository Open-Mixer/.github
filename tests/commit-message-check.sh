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
# the message mode hands its target repository to private-refs-check, which reads that repository's visibility and
# topics from GitHub through python3's urllib: a file:// API stands in (repos/OWNER/REPO holds the answer), with a token
API=$tmp/api; mkdir -p "$API/repos/Open-Mixer"
ans() { printf '%s\n' "$2" > "$API/repos/Open-Mixer/$1"; }
PUB='{"visibility":"public","topics":[]}'; STAYS='{"visibility":"private","topics":["stays-private"]}'
ans commit-message-fixture "$PUB"; ans house-fixture "$PUB"
export GITHUB_API_URL="file://$API" GH_TOKEN=fixture-token GITHUB_REPOSITORY=Open-Mixer/commit-message-fixture; unset GITHUB_ACTIONS GITHUB_TOKEN
# a PATH with no gh, for the arms that must see no token anywhere
mkdir -p "$tmp/nogh"; for f in /usr/local/bin/* /usr/bin/* /bin/*; do n=${f##*/}; [ "$n" = gh ] || [ -e "$tmp/nogh/$n" ] || ln -s "$f" "$tmp/nogh/$n" 2>/dev/null || true; done

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

# the subject is followed by a blank line: git reads everything up to the first blank line as the subject, so a body
# line directly under the subject publishes a whole paragraph as the subject. Refused by name in both doors (a range, and
# the hook on a message file) through the one checker; a one-line message, git's own trailing newline, the comment lines
# git adds to a message file and the diff below the scissors line of commit -v are not a second line
rule='the subject is not followed by a blank line'
msgcommit() { # file: one empty commit on a fresh topic branch whose message is the file, as git cleans it
  git checkout -q main; git branch -q -D t 2>/dev/null || true; git checkout -q -b t; git commit -q --allow-empty -F "$1"
}
printf 'a change\nits body starts here with no blank line\n' > "$tmp/b-none"
printf 'a change\n\nits body starts after a blank line\n' > "$tmp/b-blank"
printf 'a change\n' > "$tmp/b-one"
printf 'a change' > "$tmp/b-bare"
printf 'Merge pull request #393 from Open-Mixer/hostd-385-fix\n\nthe title of the pull request\n' > "$tmp/b-merge"
printf 'a change\n# Please enter the commit message for your changes.\n#\n# On branch t\n' > "$tmp/b-comments"
printf 'a change\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\ndiff --git a/x b/x\n+x\n' > "$tmp/b-scissors"
printf 'a change\n# a comment line\nits body starts here with no blank line\n' > "$tmp/b-comment-between"
miss=()
msgcommit "$tmp/b-none"; sha=$(git rev-parse --short=12 HEAD)
rc=0; out=$("$chk" main..HEAD 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q "^$sha: .*$rule" <<<"$out" || miss+=("(a) a range: a body line directly under the subject was not refused by name (rc $rc)")
for f in b-blank b-one b-bare b-merge; do
  msgcommit "$tmp/$f"; "$chk" main..HEAD >/dev/null 2>&1 || miss+=("a range: $f was refused")
done
git checkout -q main
rc=0; out=$(hook "$tmp/o.git" "$tmp/b-none" 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q "^commit message: .*$rule" <<<"$out" || miss+=("(d) the hook: a body line directly under the subject was not refused by name (rc $rc)")
rc=0; out=$(hook "$tmp/o.git" "$tmp/b-comment-between" 2>&1) || rc=$?
[ "$rc" = 1 ] && grep -q "$rule" <<<"$out" || miss+=("the hook: a body line under the subject and a comment line was not refused by name (rc $rc)")
for f in b-blank b-one b-bare b-merge b-comments b-scissors; do
  hook "$tmp/o.git" "$tmp/$f" >/dev/null 2>&1 || miss+=("the hook: $f was refused")
done
[ "${#miss[@]}" = 0 ] || fail "the blank line after the subject: $(printf '%s; ' "${miss[@]}")"
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
if realcommit -F "$tmp/b-none"; then fail "a real commit whose subject has no blank line after it passed"; fi
grep -q "$rule" "$tmp/rerr" || fail "a real commit refused for its missing blank line did not say so: $(cat "$tmp/rerr")"
realcommit -F "$tmp/b-blank" || fail "a real commit with a blank line after its subject was refused: $(cat "$tmp/rerr")"

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

# the target is the run's repository in CI, else this repository's GitHub origin (a target the API does not know is
# refused, so a pass proves which one was read); private with the topic stays-private skips the private-refs part by
# name, private without it does not (the attribution and house rules still apply); with no target, or no token, the
# message is not judged (2), never passed
rm -f "$API/repos/Open-Mixer/commit-message-fixture"
env -u GITHUB_REPOSITORY "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/m-err" || fail "a clean message read through the origin was refused: $(cat "$tmp/m-err")"
ans house-fixture "$STAYS"
rc=0; env -u GITHUB_REPOSITORY "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-bad" >/dev/null 2>"$tmp/m-err" || rc=$?
[ "$rc" = 0 ] && grep -q 'Open-Mixer/house-fixture is private and carries the topic stays-private: the public-repo check does not apply' "$tmp/m-err" ||
  fail "an opted-out target did not skip the private-refs part by name (rc $rc): $(cat "$tmp/m-err")"
printf 'a change\n\nCo-Authored''-By: Claude <noreply@anthro''pic.com>\n' > "$tmp/m-attr"
if env -u GITHUB_REPOSITORY "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-attr" >/dev/null 2>&1; then
  fail "an opted-out target let an attributed message pass"; fi
ans house-fixture '{"visibility":"private","topics":[]}'
if env -u GITHUB_REPOSITORY "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-bad" >/dev/null 2>&1; then
  fail "a private target without the topic skipped the private-refs part"; fi
ans house-fixture "$PUB"
rc=0; env -u GITHUB_REPOSITORY -u GH_TOKEN PATH="$tmp/nogh" "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/m-err" || rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSED.*GH_TOKEN' "$tmp/m-err" || fail "no token was not refused by name (rc $rc): $(cat "$tmp/m-err")"
# on a desk gh, when present, is where a token comes from (never on a runner, where the run's token is set)
mkdir -p "$tmp/ghtok"; printf '#!/bin/sh\n[ "$*" = "auth token" ] && echo desk-token\n' > "$tmp/ghtok/gh"; chmod +x "$tmp/ghtok/gh"
env -u GITHUB_REPOSITORY -u GH_TOKEN PATH="$tmp/ghtok:$tmp/nogh" "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/m-err" ||
  fail "a desk token from gh auth token was not used: $(cat "$tmp/m-err")"
git remote remove origin
rc=0; env -u GITHUB_REPOSITORY "${HOUSE[@]}" "$chk" --msg-file "$tmp/m-clean" >/dev/null 2>"$tmp/m-err" || rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSED' "$tmp/m-err" || fail "no target repository was not refused by name (rc $rc): $(cat "$tmp/m-err")"

echo "commit-message-check: ok"
