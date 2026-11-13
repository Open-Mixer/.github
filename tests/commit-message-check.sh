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
$G add -A; $G commit -qm one; $G tag v1
git clone -q --bare "$tmp/o" "$tmp/o.git"
mkdir -p "$tmp/home" "$tmp/s/r"; git -C "$tmp/s/r" init -q
echo "clean change" > "$tmp/msg"; printf 'change\n\nCo-Authored''-By: Claude <noreply@anthro''pic.com>\n' > "$tmp/bad"
hook() { (cd "$tmp/s/r" && env -u OPENMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB_URL HOME=$tmp/home OPENMIXER_DOTGITHUB_URL=$1 sh "$stub" "$2"); }
rc=0; out=$(hook "$tmp/none.git" "$tmp/msg" 2>&1) || rc=$?
[ "$rc" = 1 ] || fail "with no checker anywhere the stub gave $rc, not 1"
grep -q 'no commit-message checker at' <<<"$out" || fail "with no checker anywhere the stub did not say why: $out"
[ ! -e "$tmp/home/.cache/omx/openmixer-dotgithub" ] || fail "a failed clone left a cache behind"
hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>&1 || fail "the stub did not clone v1 and pass a clean message"
cache=$tmp/home/.cache/omx/openmixer-dotgithub
[ "$(git -C "$cache" rev-parse HEAD)" = "$(git -C "$tmp/o" rev-parse v1)" ] || fail "the first use did not clone v1"
if hook "$tmp/o.git" "$tmp/bad" >/dev/null 2>&1; then fail "the stub passed an attributed message"; fi
touch "$tmp/o/moved"; $G add -A; $G commit -qm two; $G tag -f v1 >/dev/null; git -C "$tmp/o" push -q --force "$tmp/o.git" refs/tags/v1
touch -d '20 minutes ago' "$cache/.git/FETCH_HEAD"
hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>&1 || fail "the refreshed stub refused a clean message"
[ "$(git -C "$cache" rev-parse HEAD)" = "$(git -C "$tmp/o" rev-parse v1)" ] || fail "a stale cache was not fetched at the moved v1"
mv "$tmp/o.git" "$tmp/o.away"; touch -d '20 minutes ago' "$cache/.git/FETCH_HEAD"
rc=0; hook "$tmp/o.git" "$tmp/msg" >/dev/null 2>"$tmp/err" || rc=$?
[ "$rc" = 0 ] && grep -q 'could not fetch v1' "$tmp/err" || fail "an unreachable remote did not fall back to the cached checker and say so (rc $rc)"

# the env var moved to the openmixer name; for one transitional pass the stub also reads the old FREEMIXER_ names, the
# new name winning, the old one read with a one-line notice (the old names are removed in a later pass)
mv "$tmp/o.away" "$tmp/o.git"
for w in new old; do mkdir -p "$tmp/dg$w/.github/actions/commit-message-check"
  printf '#!/bin/sh\necho "checker=%s"\n' "$w" > "$tmp/dg$w/.github/actions/commit-message-check/commit-message-check.sh"
  chmod +x "$tmp/dg$w/.github/actions/commit-message-check/commit-message-check.sh"; done
envhook() { (cd "$tmp/s/r" && env -u OPENMIXER_DOTGITHUB -u FREEMIXER_DOTGITHUB -u OPENMIXER_DOTGITHUB_URL -u FREEMIXER_DOTGITHUB_URL HOME=$tmp/home "$@" sh "$stub" "$tmp/msg" 2>"$tmp/err"); }
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

echo "commit-message-check: ok"
