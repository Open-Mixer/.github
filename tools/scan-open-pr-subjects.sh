#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# scan-open-pr-subjects.sh: name every commit of every open pull request whose subject is not followed by a blank line.
#
#   scan-open-pr-subjects.sh [org ...]      default: Open-Mixer FreeREAC
#
# The rule turns such a pull request red once the release line carries it, so the line moves only after this scan is
# clean or its offenders are known. Each repository of each organisation that is not archived, each open pull request,
# each of its commits: the message is judged by commit-message-check.sh --subject-blank-file, the checker's own rule
# (there is no second copy here). One line per offender, "<owner/repo>#<pr> <sha12>: <subject>", then a count line.
# Exit 0 none, 1 an offender, 2 something could not be read (each unread call is named on stderr; never a pass).
# It only reads: gh repo list, gh pr list and GET pulls/<n>/commits. Needs gh (authenticated) and jq.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
chk=$here/.github/actions/commit-message-check/commit-message-check.sh
[ -x "$chk" ] || { echo "scan-open-pr-subjects: no checker at $chk" >&2; exit 2; }
[ "$#" -gt 0 ] || set -- Open-Mixer FreeREAC
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
nrepo=0; npr=0; ncommit=0; nbad=0; unread=0
unreadable() { echo "scan-open-pr-subjects: could not read $1: $(tr '\n' ' ' < "$tmp/err")" >&2; unread=$((unread + 1)); }

for org in "$@"; do
  repos=$(gh repo list "$org" --limit 500 --json nameWithOwner,isArchived 2>"$tmp/err" |
    jq -r '.[] | select(.isArchived | not) | .nameWithOwner' 2>>"$tmp/err") || { unreadable "the repositories of $org"; continue; }
  for repo in $repos; do
    nrepo=$((nrepo + 1))
    prs=$(gh pr list --repo "$repo" --state open --limit 1000 --json number,headRefOid,baseRefName 2>"$tmp/err" |
      jq -r '.[].number' 2>>"$tmp/err") || { unreadable "the open pull requests of $repo"; continue; }
    for pr in $prs; do
      npr=$((npr + 1))
      # sha and message, the message in base64 so its lines stay one record
      rows=$(gh api "repos/$repo/pulls/$pr/commits?per_page=100" --paginate 2>"$tmp/err" |
        jq -r '.[] | .sha + " " + (.commit.message | @base64)' 2>>"$tmp/err") || { unreadable "the commits of $repo#$pr"; continue; }
      n=0
      while read -r sha b64; do
        [ -n "$sha" ] || continue
        n=$((n + 1)); ncommit=$((ncommit + 1))
        base64 -d <<<"$b64" > "$tmp/msg"
        rc=0; "$chk" --subject-blank-file "$tmp/msg" >/dev/null 2>"$tmp/err" || rc=$?
        case $rc in
          0) ;;
          1) nbad=$((nbad + 1)); echo "$repo#$pr ${sha:0:12}: $(grep -m1 . "$tmp/msg")" ;;
          *) unreadable "the verdict on $repo#$pr ${sha:0:12}" ;;
        esac
      done <<<"$rows"
      # the API lists at most 250 commits of a pull request: one that long was not read whole
      if [ "$n" -ge 250 ]; then : > "$tmp/err"; unreadable "every commit of $repo#$pr (the API lists 250 at most)"; fi
    done
  done
done
echo "scan-open-pr-subjects: $nrepo repositories, $npr open pull requests, $ncommit commits, $nbad offenders"
[ "$unread" = 0 ] || { echo "scan-open-pr-subjects: $unread reads failed, so this is not a verdict" >&2; exit 2; }
[ "$nbad" = 0 ]
