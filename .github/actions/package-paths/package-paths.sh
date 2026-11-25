#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# package-paths.sh   (changed paths on stdin, one a line)
#
# Prints the paths that can change a package: every path that matches no exempt glob. THE ONE DEFINITION of what a
# change to a package is, for the pull request into devel (devel-bump-check), the merge to devel of a published version
# (release-preflight) and the promotion of a real build (promote-staged): .github/** alone is exempt by default (a
# workflow ships in no package; README.md and docs/ do, %doc README.md). EXEMPT adds globs, space separated: the paths a
# repository shows its packages do not install. A glob matches the whole path, * crossing /; a glob starting **/ also
# matches at the top (**/*.txt matches NOTES.txt).
set -euo pipefail
read -r -a exempt <<< ".github/** ${EXEMPT:-}"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in "${exempt[@]}"; do
        # shellcheck disable=SC2053 # g is a glob on purpose
        if [[ $p == $g ]] || { [[ $g == '**/'* ]] && [[ $p == ${g#'**/'} ]]; }; then continue 2; fi
    done
    printf '%s\n' "$p"
done
