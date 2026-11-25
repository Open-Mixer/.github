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
# package-paths.sh --check (run in the checkout): refuses, naming the glob and the packaged file it covers, an EXEMPT glob
# that matches packaging/ or debian/, a %doc or %license file of a packaging/*.spec (its %files sections), a
# debian/*.docs entry or the source of a debian/*.install entry, or every path: a repository, or a pull request
# changing its own workflow, never exempts what a package installs. Every reader of the exempt list runs it.
set -euo pipefail
matches() { # <path> <glob>
    # shellcheck disable=SC2053 # the glob is a glob on purpose
    [[ $1 == $2 ]] || { [[ $2 == '**/'* ]] && [[ $1 == ${2#'**/'} ]]; }
}
if [ "${1:-}" = --check ]; then
    read -r -a added <<< "${EXEMPT:-}"
    [ "${#added[@]}" -gt 0 ] || exit 0
    packaged=(packaging/x debian/x)
    while IFS= read -r f; do packaged+=("$f"); done < <(git ls-files packaging debian 2>/dev/null || true)
    shopt -s nullglob
    for spec in packaging/*.spec; do
        # the %doc and %license entries of every %files section; macros and absolute paths name no file of the tree
        while read -r -a words; do
            for w in "${words[@]:1}"; do
                case $w in %* | -* | /*) continue ;; esac
                packaged+=("${w%/}"); [ "${w%/}" = "$w" ] || packaged+=("${w%/}/x")
            done
        done < <(awk '/^%files/ {f=1; next} /^%(package|description|prep|build|install|check|changelog|pre|post|preun|postun|pretrans|posttrans|triggerin|triggerun|filetriggerin)([ \t]|$)/ {f=0} f && /^%(doc|license)[ \t]/' "$spec")
    done
    for f in debian/*.docs; do while read -r w _; do [ -z "$w" ] || packaged+=("${w%/}"); done < "$f"; done
    for f in debian/*.install; do while read -r w _; do [ -z "$w" ] || packaged+=("${w%/}"); done < "$f"; done
    bad=0
    for g in "${added[@]}"; do
        if matches x "$g" && matches src/x.c "$g" && matches a/b/c.d "$g"; then
            echo "::error::bump-exempt glob '$g' covers every path: it would exempt every packaged file"; bad=1; continue
        fi
        for p in "${packaged[@]}"; do
            if matches "$p" "$g"; then echo "::error::bump-exempt glob '$g' covers $p, which a package ships or builds from"; bad=1; break; fi
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
