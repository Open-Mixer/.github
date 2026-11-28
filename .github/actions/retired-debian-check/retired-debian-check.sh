#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# retired-debian-check [repo-root] | --self-test
#
# Debian is trixie only (owner ruling 2026-11-28, "we don't do bookworm"; it supersedes D25, bookworm as a full cell).
# Refuses every line outside a comment that names bookworm, in what builds, checks or describes a package:
#   - the workflows, .github/workflows/*.yml|yaml;                                 rule:workflows
#   - the composite actions and their scripts, every file under .github/actions/;   rule:actions
#   - the Debian packaging, every file under a debian/ directory;                   rule:debian
#   - the RPM packaging, every *.spec file and every file under packaging/;         rule:spec
# The history is not a promise: debian/changelog and the %changelog of a spec (every line after it) say what a past
# release did and are never read (rule:changelog). Two paths are exempt, both in Open-Mixer/.github alone: this check's
# own directory (its self-test plants the word) and .github/actions/release-matrix/frozen.txt, the list of releases the
# channel still serves and nothing builds.
# A comment is a line whose first character that is not a space is # or //, and the rest of a line after " #" or " //".
# Exit 0 clean, 1 a hit (each line named), 2 nothing of the above to check (an empty check proves nothing).
set -eu
self=$0

files() { # <root>: the tracked files (every file when <root> is not a git work tree), relative, one per line
	if git -c safe.directory="$1" -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -c safe.directory="$1" -C "$1" ls-files
	else
		(cd "$1" && find . -type f -not -path './.git/*' | sed 's|^\./||')
	fi
}

check() {
	local root=$1 list out
	list=$(files "$root" | awk '
		/^\.github\/actions\/release-matrix\/frozen\.txt$/ { next }  # served, never built
		/^\.github\/actions\/retired-debian-check\// { next }          # this check: its self-test plants the word
		/(^|\/)debian\/changelog$/ { next }                          # rule:changelog
		/^\.github\/workflows\/[^\/]+\.ya?ml$/ { print; next }       # rule:workflows
		/^\.github\/actions\// { print; next }                       # rule:actions
		/(^|\/)debian\// { print; next }                             # rule:debian
		/\.spec$/ || /(^|\/)packaging\// { print; next }             # rule:spec
	')
	if [ -z "$list" ]; then
		echo "retired-debian-check: no workflow, action or packaging file under $root (refusing: an empty check proves nothing)" >&2
		return 2
	fi
	out=$(cd "$root" && printf '%s\n' "$list" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done | xargs -0 -r awk '
	FNR == 1 { hist = 0 }
	FILENAME ~ /\.spec$/ && /^%changelog/ { hist = 1 }  # rule:changelog
	hist { next }
	{
		l = $0
		sub(/^[[:space:]]*(#|\/\/).*/, "", l); sub(/[[:space:]](#|\/\/).*/, "", l)  # rule:comment
		if (tolower(l) ~ /bookworm/) print FILENAME ":" FNR ": " $0
	}' || true)
	if [ -n "$out" ]; then
		printf '%s\n' "$out"
		echo "retired-debian-check: a workflow, action or packaging line names bookworm; Debian is trixie only (owner ruling 2026-11-28)" >&2
		return 1
	fi
	echo "retired-debian-check: no workflow, action or packaging line names bookworm"
}

if [ "${1:-}" = "--self-test" ]; then
	t=$(mktemp -d)
	trap 'rm -rf "$t"' EXIT
	fails=0
	plant() { # name, expected rc, path, body
		local d=$t/$1 rc=0
		mkdir -p "$d/.github/workflows" "$(dirname "$d/$3")"
		printf 'jobs: {}\n' > "$d/.github/workflows/clean.yml"
		printf '%s\n' "$4" > "$d/$3"
		"$self" "$d" >/dev/null 2>&1 || rc=$?
		if [ "$rc" != "$2" ]; then echo "self-test FAIL $1: rc $rc, want $2" >&2; fails=$((fails + 1)); fi
	}
	plant clean 0 .github/workflows/ci.yml "deb-releases: '[\"trixie\"]'"
	plant matrix 1 .github/workflows/ci.yml "deb-releases: '[\"bookworm\", \"trixie\"]'"
	plant image 1 .github/workflows/ci.yml 'image: debian:bookworm'
	plant upper 1 .github/workflows/release.yaml 'name: DEB (Bookworm, amd64)'
	plant suite 1 .github/workflows/ci.yml "if: matrix.suite == 'bookworm'"
	plant action 1 .github/actions/build/action.yml 'default: bookworm'
	plant actionscript 1 .github/actions/build/run.sh 'case $suite in bookworm) floor=1.2 ;; esac'
	plant control 1 debian/control 'Build-Depends: libfoo-dev (>= 1.2) [bookworm]'
	plant rules 1 debian/rules 'SUITES = bookworm trixie'
	plant nested 1 packaging/x-release/debian/rules 'SUITES = bookworm trixie'
	plant spec 1 packaging/x.spec 'BuildRequires: pkgconfig # bookworm floor
%if 0%{?bookworm}'
	plant rootspec 1 x.spec '%global suites bookworm trixie'
	plant packagingdoc 1 packaging/jackd2/README.md 'a jackd2-bookworm pin is all a bookworm build needs'
	plant comment 0 .github/workflows/ci.yml '# bookworm is dropped (owner 2026-11-28)
    deb-releases: x  # was bookworm
    // bookworm once'
	plant changelog 0 debian/changelog '  * built for bookworm and trixie'
	plant nestedchangelog 0 packaging/x-release/debian/changelog '  * The apt source for bookworm and trixie.'
	plant spechistory 0 packaging/x.spec 'Name: x
%changelog
- no bookworm package cells (#99)'
	plant specbeforehistory 1 packaging/x.spec 'Summary: x for bookworm
%changelog
- trixie'
	plant frozen 0 .github/actions/release-matrix/frozen.txt 'deb bookworm'
	plant frozenother 1 .github/actions/release-matrix/frozen-extra.txt 'deb bookworm'
	plant docs 0 docs/history.md 'bookworm was dropped on 2026-11-28'
	plant src 0 src/a.c '/* bookworm */'
	plant self 0 .github/actions/retired-debian-check/retired-debian-check.sh 'plant matrix 1 x "bookworm"'
	plant selfother 1 .github/actions/retired-debian-check-extra/run.sh 'suite=bookworm'
	mkdir -p "$t/empty/docs"; printf 'x\n' > "$t/empty/docs/a.md"
	rc=0; "$self" "$t/empty" >/dev/null 2>&1 || rc=$?
	if [ "$rc" != 2 ]; then echo "self-test FAIL nothing to check: rc $rc, want 2" >&2; fails=$((fails + 1)); fi
	if [ "$fails" != 0 ]; then echo "retired-debian-check: self-test $fails red" >&2; exit 1; fi
	echo "retired-debian-check: self-test green (25 arms)"
	exit 0
fi

rc=0
check "${1:-.}" || rc=$?
exit "$rc"
