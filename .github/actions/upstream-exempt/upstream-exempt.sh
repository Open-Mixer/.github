#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# upstream-exempt.sh: the ONE upstream exemption. A fork carries its upstream's history as it is: unsigned, authored by others, with
# messages nobody here can reword (no rebase of upstream history). A commit is exempt from a check ONLY if all three hold:
#   (a) the upstream URL is a line of upstream-allowed.txt beside this script (exact match),
#   (b) git does not rewrite that URL (`git ls-remote --get-url` returns it unchanged: url.*.insteadOf would point it at a repository of
#       our own commits), and the URL is FETCHED into this script's own namespace refs/omx/upstream-exempt/ (never a local branch),
#   (c) the commit is an ancestor of one of those refs.
# Our own commits and merge commits are not upstream's and keep every check.
#   upstream-exempt.sh prepare <url>   exit 0 when (a) and (b) hold and the fetch worked; else say why on stderr and exit 1
#   upstream-exempt.sh holds <commit>  exit 0 when (c) holds; only meaningful after a successful prepare
# The ops pre-push hook carries the same rule for the push path (its own copy of this logic: that repository is private and cannot
# read this one at run time); the list there and the list here name the same URLs.
set -uo pipefail
ns=refs/omx/upstream-exempt
clear() { local r; for r in $(git for-each-ref --format='%(refname)' "$ns/" 2>/dev/null); do git update-ref -d "$r"; done; }
case "${1:-}" in
  prepare)
    url=${2:-}; clear
    [ -n "$url" ] || { echo "upstream-exempt: no upstream URL given" >&2; exit 1; }
    grep -vE '^[[:space:]]*(#|$)' "$(dirname "$0")/upstream-allowed.txt" 2>/dev/null | grep -Fxq -- "$url" || { echo "upstream-exempt: upstream URL $url is not on the upstream list" >&2; exit 1; }   # UPLIST
    [ "$(git ls-remote --get-url "$url" 2>/dev/null)" = "$url" ] || { echo "upstream-exempt: upstream URL $url is rewritten by local url.*.insteadOf config" >&2; exit 1; }   # UPREWRITE
    git fetch -q --no-tags "$url" "+refs/heads/*:$ns/*" >/dev/null 2>&1 </dev/null \
      || { clear; echo "upstream-exempt: upstream $url could not be fetched" >&2; exit 1; }
    exit 0 ;;
  holds)
    [ -n "$(git for-each-ref --count=1 --contains "${2:?commit}" --format=x "$ns/")" ]   # UPANC
    exit $? ;;
  *) echo "usage: upstream-exempt.sh prepare <url> | holds <commit>" >&2; exit 2 ;;
esac
