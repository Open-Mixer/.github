#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# commit-identity-check.sh: every commit of a range has the expected author email, the expected committer email, and
# GitHub's .commit.verification.verified true (read with `gh api repos/$GH_REPO/commits/<sha>`, GH_TOKEN in the
# environment). The head is not special: the whole range is read.
#
#   commit-identity-check.sh --author-email A --committer-email C [--upstream-url U] [--head-ref H] <range>
#   commit-identity-check.sh --selftest
#
# Exit 0 clean, 1 a hit (each commit sha, the field and the value are named), 2 a range, flag or API answer that
# cannot be read: a checker that cannot judge is never a pass. The expected emails are flags; an empty flag takes the
# default written in action.yml beside this script, the one place the defaults are written.
# --upstream-url U (default none: no exemption): a fork's range carries its upstream's own commits, authored by others and unverified.
# A commit with an offending field is dropped from the count when ../upstream-exempt/upstream-exempt.sh says U is on the exact list,
# not rewritten, fetched, and the commit an ancestor of it; every other commit, our merge commits included, keeps every field.
# --head-ref H (the pull request's head branch; default none: every commit of the range is judged): a commit of the range
# already reachable from a PUBLIC ref of this repository (refs/remotes/origin/* other than origin/H, and refs/tags/*,
# as a fetch-depth 0 checkout leaves them) is published history folded in by a merge: it was judged when it was pushed,
# so it is named as published and not judged again (#269, omx-clap-core#213). Every commit reachable only from the head
# is judged in full. A range tip that is itself reachable from those refs is exit 2: the head is misnamed or pushed
# under a second name, and nothing of the pull request would be judged.
set -euo pipefail

verified_of() { # sha -> "<verified> <reason>" from the GitHub API
  gh api "repos/$GH_REPO/commits/$1" --jq '"\(.commit.verification.verified) \(.commit.verification.reason)"'
}

ex=$(dirname "${BASH_SOURCE[0]}")/../upstream-exempt/upstream-exempt.sh
UPSTREAM_URL=
HEAD_REF=
ex_state=; ex_reason=
# the public refs of this repository, minus the pull request's own head branch (one per line); nothing without --head-ref
published_refs() {
  [ -n "$HEAD_REF" ] || return 0
  git for-each-ref --format='%(refname)' refs/remotes/origin refs/tags | grep -vxF "refs/remotes/origin/$HEAD_REF" || true
}
# exempt <sha>: the upstream exemption (upstream-exempt.sh, the one source) for a commit that has offending fields; lazy, so a clean
# range fetches nothing, and with no --upstream-url there is no exemption at all
exempt() {
  [ -n "$UPSTREAM_URL" ] || return 1
  if [ -z "$ex_state" ]; then
    if ex_reason=$("$ex" prepare "$UPSTREAM_URL" 2>&1); then ex_state=ok; else ex_state=no; fi
  fi
  [ "$ex_state" = ok ] && "$ex" holds "$1"
}
check() { # author-email committer-email range
  local want_a=$1 want_c=$2 range=$3 shas sha ae ce v reason bad=0 n=0 hits cb exempted=0 published=0 all refs
  all=$(git rev-list "$range") || { echo "commit-identity-check: cannot read range $range" >&2; return 2; }
  shas=$all
  refs=$(published_refs)
  if [ -n "$refs" ] && [ -n "$all" ]; then
    # shellcheck disable=SC2086 # one ref per word: refnames carry no spaces
    shas=$(git rev-list "$range" --not $refs) || { echo "commit-identity-check: cannot read range $range minus the public refs" >&2; return 2; }
    # shellcheck disable=SC2086 # as above
    if [ -z "$(git rev-list -1 "${range##*..}" --not $refs)" ]; then
      echo "commit-identity-check: the head ${range##*..} is reachable from a public ref other than origin/$HEAD_REF: the head ref is misnamed or pushed under a second name, and nothing would be judged" >&2
      return 2
    fi
    for sha in $all; do
      case $'\n'"$shas"$'\n' in *$'\n'"$sha"$'\n'*) ;; *) echo "$sha: published (reachable from a public ref of this repository): judged when it was pushed, not here"; published=$((published + 1)) ;; esac
    done
  fi
  for sha in $shas; do
    n=$((n + 1)); hits=; cb=0
    IFS=' ' read -r ae ce < <(git log -1 --format='%ae %ce' "$sha")
    [ "$ae" = "$want_a" ] || { hits+="$sha: [author-email] $ae (expected $want_a)"$'\n'; cb=$((cb + 1)); }
    [ "$ce" = "$want_c" ] || {
      hits+="$sha: [committer-email] $ce (expected $want_c)"$'\n'; cb=$((cb + 1))
      case "$ce" in
        *@github.com) hits+="$sha: made by GitHub (Update branch?): merge the base into the branch LOCALLY with a plain signed git merge (house author and committer), push plainly; never rebase or force-push"$'\n' ;;
      esac
    }
    v=$(verified_of "$sha") || { echo "commit-identity-check: the API gave no answer for $sha" >&2; return 2; }
    read -r v reason <<<"$v"
    case "$v" in
      true) ;;
      false) hits+="$sha: [verified] false (reason: $reason)"$'\n'; cb=$((cb + 1)) ;;
      *) echo "commit-identity-check: the API answered '$v' for $sha" >&2; return 2 ;;
    esac
    [ "$cb" = 0 ] && continue
    if exempt "$sha"; then exempted=$((exempted + 1)); continue; fi
    printf '%s' "$hits"; bad=$((bad + cb))
    [ -z "$UPSTREAM_URL" ] || [ "$ex_state" != no ] || echo "$sha: no upstream exemption: ${ex_reason#upstream-exempt: }"
  done
  echo "commit-identity-check: $n commits, $bad offending fields$([ "$exempted" = 0 ] || echo ", $exempted upstream commits exempt")$([ "$published" = 0 ] || echo ", $published published commits not judged")"
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
a=; c=; UPSTREAM_URL=
while [ $# -gt 2 ]; do
  case "$1" in
    --author-email) a=$2 ;;
    --committer-email) c=$2 ;;
    --upstream-url) UPSTREAM_URL=$2 ;;
    --head-ref) HEAD_REF=$2 ;;
    *) break ;;
  esac
  shift 2
done
default_of() { sed -n "/^  $1:/,/^  [a-z-]*:\$/p" "$(dirname "${BASH_SOURCE[0]}")/action.yml" | sed -n 's/^    default: //p' | head -1; }
[ $# = 1 ] || { echo "usage: commit-identity-check.sh --author-email A --committer-email C <range> | --selftest" >&2; exit 2; }
[ -n "$a" ] || a=$(default_of author-email)
[ -n "$c" ] || c=$(default_of committer-email)
[ -n "$a" ] && [ -n "$c" ] && [ $# = 1 ] || { echo "usage: commit-identity-check.sh --author-email A --committer-email C <range> | --selftest" >&2; exit 2; }
: "${GH_REPO:?commit-identity-check: GH_REPO (owner/repo) is not set}"
rc=0; check "$a" "$c" "$1" || rc=$?
exit "$rc"
