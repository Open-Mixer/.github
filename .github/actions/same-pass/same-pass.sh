#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# same-pass.sh: the reader behind .github/actions/same-pass. It reads the sparse checkout of the caller's repository at
# SAME_PASS_SRC, with LIST (the dispatch input), REF (the commit being built, empty for GITHUB_SHA) and GITHUB_SHA /
# GITHUB_OUTPUT. It is the samepass job every release.yml carried, moved here unchanged except where marked.
set -euo pipefail
cd "${SAME_PASS_SRC:-.}"
f=.github/release-same-pass
# globbing off: a name is validated before it is used, so a '*' in the list or the file must never expand to a path
set -f

# the names of a list: one package per word, a # starts a comment
names_of() { sed -e 's/#.*//' | tr -s ' \t\r\n' '\n' | sed '/^$/d'; }

# the dispatch list, when it names anything, wins over the file
names=$(printf '%s\n' "${LIST:-}" | names_of)
if [ -n "$names" ]; then
  src="the list input"
else
  src=$f
  ref=${REF:-$GITHUB_SHA}
  # a named ref is fetched and its file read from FETCH_HEAD: no checkout is pinned to a ref (make check-no-pins)
  if [ "$ref" != "$GITHUB_SHA" ]; then
    git fetch --quiet --depth=1 origin "$ref" || { echo "::error::cannot fetch source-ref $ref"; exit 1; }
    rm -f "$f"
    # the sparse checkout has no .github at all when HEAD lacks the file: the named ref's copy needs its directory
    mkdir -p .github
    git show "FETCH_HEAD:$f" >"$f" 2>/dev/null || rm -f "$f"
  fi
  if [ ! -f "$f" ]; then
    echo "list=" >>"$GITHUB_OUTPUT"
    echo "no $f at this commit: nothing released in the same pass"
    exit 0
  fi
  names=$(names_of <"$f")
fi
for n in $names; do
  [[ "$n" =~ ^[a-z0-9][a-z0-9.+-]*$ ]] || { echo "::error::$src: '$n' is not a package name"; exit 1; }
done
list=$(paste -sd" " <<<"$names")
echo "list=$list" >>"$GITHUB_OUTPUT"
echo "same pass from $src: ${list:-none}"
