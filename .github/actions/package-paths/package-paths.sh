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
#
# package-paths.sh --check (run in the checkout, judging the tree at CHECK_AT when set: the commit the exempt list was
# read at): an EXEMPT glob names only paths UNDER .github/ (.github#296). A glob that does not start with .github/, or
# that climbs out of it (..), is refused by name, whatever the tree holds: a glob matching nothing yet would let the
# first source added there escape, and whether a directory ships is not guessed. A glob under .github/ that covers a
# file a package ships (a %doc or %license entry of a packaging/*.spec's %files, a debian/*.docs entry or the source
# of a debian/*.install entry) is refused too, naming the glob and the file. Every reader of the exempt list runs it.
set -euo pipefail
matches() { # <path> <glob>
    # shellcheck disable=SC2053 # the glob is a glob on purpose
    [[ $1 == $2 ]] || { [[ $2 == '**/'* ]] && [[ $1 == ${2#'**/'} ]]; }
}
if [ "${1:-}" = --check ]; then
    read -r -a added <<< "${EXEMPT:-}"
    [ "${#added[@]}" -gt 0 ] || exit 0
    # the tree judged: CHECK_AT, the commit the exempt list was read at (base-exempt.sh), else the checkout
    if [ -n "${CHECK_AT:-}" ]; then
        tracked() { git ls-tree -r --name-only "$CHECK_AT"; }
        content() { git show "$CHECK_AT:$1" 2>/dev/null; }
    else
        # a directory that is no git checkout (a test tree) is read as it is
        tracked() { git ls-files 2>/dev/null || find . -type f ! -path './.git/*' | sed 's|^\./||'; }
        content() { cat "$1" 2>/dev/null; }
    fi
    mapfile -t files < <(tracked || { echo "::error::the tracked files at ${CHECK_AT:-the checkout} cannot be listed" >&2; exit 1; })
    packaged=()
    for spec in "${files[@]}"; do
        case $spec in packaging/*.spec) ;; *) continue ;; esac
        # the %doc and %license entries of every %files section; macros and absolute paths name no file of the tree
        while read -r -a words; do
            for w in "${words[@]:1}"; do
                case $w in %* | -* | /*) continue ;; esac
                packaged+=("${w%/}"); [ "${w%/}" = "$w" ] || packaged+=("${w%/}/x")
            done
        done < <(content "$spec" | awk '/^%files/ {f=1; next} /^%(package|description|prep|build|install|check|changelog|pre|post|preun|postun|pretrans|posttrans|triggerin|triggerun|filetriggerin)([ \t]|$)/ {f=0} f && /^%(doc|license)[ \t]/')
    done
    for f in "${files[@]}"; do
        case $f in debian/*.docs | debian/*.install) ;; *) continue ;; esac
        while read -r w _; do [ -z "$w" ] || packaged+=("${w%/}"); done < <(content "$f")
    done
    bad=0
    for g in "${added[@]}"; do
        if [[ $g != .github/* || /$g/ == */../* ]]; then
            echo "::error::bump-exempt glob '$g' is not under .github/: bump-exempt may name only paths under .github/ (.github#296)"; bad=1; continue
        fi
        for p in "${packaged[@]}"; do
            if matches "$p" "$g"; then echo "::error::bump-exempt glob '$g' covers $p, which a package ships"; bad=1; break; fi
        done
    done
    exit "$bad"
fi
read -r -a exempt <<< ".github/** ${EXEMPT:-}"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in "${exempt[@]}"; do
        if matches "$p" "$g"; then continue 2; fi
    done
    printf '%s\n' "$p"
done
