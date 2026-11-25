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
# read at): refuses, naming the glob and the file it covers, an EXEMPT glob that matches packaging/ or debian/, a %doc or
# %license file of a packaging/*.spec (its %files sections), a debian/*.docs entry or the source of a debian/*.install
# entry, every path, or any TRACKED file outside the allow-list: .github/**, tests/** when no package ships it, and docs
# (docs/, doc/, *.md, *.rst, *.adoc) that are not packaged (.github#296). A build source (src/**, *.c, include/**,
# CMakeLists.txt, meson.build, Makefile) is never exempt. Every reader of the exempt list runs it.
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
    packaged=(packaging/x debian/x)
    for f in "${files[@]}"; do case $f in packaging/* | debian/*) packaged+=("$f") ;; esac; done
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
    shipped() { local p; for p in "${packaged[@]}"; do [[ $1 == "$p" || $1 == "$p"/* ]] || matches "$1" "$p" && return 0; done; return 1; }
    # the allow-list of tracked files a glob may cover (.github#296): .github/**, tests/** when no package ships it, and
    # docs (docs/, doc/, *.md, *.rst, *.adoc) that are not %doc, %license or debian/*.docs entries; never a build source
    allowed() {
        case $1 in
            .github/*) return 0 ;;
            tests/*) ! shipped "$1" && ! shipped tests ;;
            docs/* | doc/* | *.md | *.rst | *.adoc) ! shipped "$1" ;;
            *) return 1 ;;
        esac
    }
    bad=0
    for g in "${added[@]}"; do
        if matches x "$g" && matches src/x.c "$g" && matches a/b/c.d "$g"; then
            echo "::error::bump-exempt glob '$g' covers every path: it would exempt every packaged file"; bad=1; continue
        fi
        hit=
        for p in "${packaged[@]}"; do
            if matches "$p" "$g"; then echo "::error::bump-exempt glob '$g' covers $p, which a package ships or builds from"; bad=1 hit=1; break; fi
        done
        [ -z "$hit" ] || continue
        for f in "${files[@]}"; do
            if matches "$f" "$g" && ! allowed "$f"; then
                echo "::error::bump-exempt glob '$g' covers $f, a tracked file outside the allow-list (.github/**, unshipped tests/**, uninstalled docs)"; bad=1; break
            fi
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
