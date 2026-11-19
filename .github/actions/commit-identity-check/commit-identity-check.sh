#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# commit-identity-check.sh: every commit of a range has the expected author email, the expected committer email, and
# GitHub's .commit.verification.verified true (read with `gh api repos/$GH_REPO/commits/<sha>`, GH_TOKEN in the
# environment). The head is not special: the whole range is read.
#
#   commit-identity-check.sh --author-email A --committer-email C <range>
#   commit-identity-check.sh --selftest
#
# Exit 0 clean, 1 a hit (each commit sha, the field and the value are named), 2 a range, flag or API answer that
# cannot be read: a checker that cannot judge is never a pass. The expected emails are flags with no default here;
# action.yml is the one place their defaults are written.
set -euo pipefail

verified_of() { # sha -> "<verified> <reason>" from the GitHub API
  gh api "repos/$GH_REPO/commits/$1" --jq '"\(.commit.verification.verified) \(.commit.verification.reason)"'
}

check() { # author-email committer-email range
  local want_a=$1 want_c=$2 range=$3 shas sha ae ce v reason bad=0 n=0
  shas=$(git rev-list "$range") || { echo "commit-identity-check: cannot read range $range" >&2; return 2; }
  for sha in $shas; do
    n=$((n + 1))
    IFS=' ' read -r ae ce < <(git log -1 --format='%ae %ce' "$sha")
    [ "$ae" = "$want_a" ] || { echo "$sha: [author-email] $ae (expected $want_a)"; bad=$((bad + 1)); }
    [ "$ce" = "$want_c" ] || {
      echo "$sha: [committer-email] $ce (expected $want_c)"; bad=$((bad + 1))
      case "$ce" in
        *@github.com) echo "$sha: made by GitHub (Update branch?): merge the base into the branch LOCALLY with a plain signed git merge (house author and committer), push plainly; never rebase or force-push" ;;
      esac
    }
    v=$(verified_of "$sha") || { echo "commit-identity-check: the API gave no answer for $sha" >&2; return 2; }
    read -r v reason <<<"$v"
    case "$v" in
      true) ;;
      false) echo "$sha: [verified] false (reason: $reason)"; bad=$((bad + 1)) ;;
      *) echo "commit-identity-check: the API answered '$v' for $sha" >&2; return 2 ;;
    esac
  done
  echo "commit-identity-check: $n commits, $bad offending fields"
  [ "$bad" = 0 ]
}

selftest() {
  # the test script beside the repository's other tests holds the fixtures; this one proves the pure reader is not blind
  local t; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  git init -q "$t/r"
  git -C "$t/r" -c user.name=t -c user.email=x@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m base
  GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_EMAIL=wrong@x git -C "$t/r" -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m bad
  mkdir "$t/bin"; printf '#!/bin/sh\necho "true valid"\n' > "$t/bin/gh"; chmod +x "$t/bin/gh"
  cd "$t/r" || return 2
  if PATH="$t/bin:$PATH" GH_REPO=o/r check a@x c@x HEAD~1..HEAD >/dev/null; then echo "selftest: RED, a wrong committer passed"; return 1; fi
  PATH="$t/bin:$PATH" GH_REPO=o/r check a@x wrong@x HEAD~1..HEAD >/dev/null || { echo "selftest: RED, a good commit failed"; return 1; }
  echo "selftest: GREEN"
}

if [ "${1:-}" = --selftest ]; then selftest; exit; fi
a=; c=
while [ $# -gt 2 ]; do
  case "$1" in
    --author-email) a=$2 ;;
    --committer-email) c=$2 ;;
    *) break ;;
  esac
  shift 2
done
[ -n "$a" ] && [ -n "$c" ] && [ $# = 1 ] || { echo "usage: commit-identity-check.sh --author-email A --committer-email C <range> | --selftest" >&2; exit 2; }
: "${GH_REPO:?commit-identity-check: GH_REPO (owner/repo) is not set}"
rc=0; check "$a" "$c" "$1" || rc=$?
exit "$rc"
