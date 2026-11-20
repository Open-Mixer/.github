#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# fedora-workflow-check [repo-root] | --self-test
#
# Refuses a Fedora release in .github/workflows that is not in the allowed list (env ALLOWED_FEDORA, space or comma
# separated, default 45). The development matrix is Fedora 45 only; the full set returns by widening the list, the one
# place it is written (the action input allowed-fedora), never by editing this script. A release the packages are not
# published for can no longer resolve its build dependencies, so a job on fedora:44, an fc44 cell, or 44 in a fedora
# matrix list is refused. Matched, outside comments: fedora:NN, fcNN, a number (30-59) anywhere on a line that names
# fedora (fedora: [45, 44]), a releases / rpm-releases list ('["44", "45"]'), and an item of a fedora block list.
# fedoraNN, the name of a record set measured on that release (plugin-db-qualification), is data and not a release: it
# is taken out of each line before the match. Logic and planted arms: Open-Mixer/omx-panel#148 @7d4fc3a
# tools/test/workflow-fedora-check.sh, generalised from "44" to "not in the allowed list".
# Exit 0 clean, 1 a hit (each line named), 2 no .github/workflows to check (an empty check proves nothing).
set -eu
self=$0
ALLOWED=${ALLOWED_FEDORA:-45}

check() {
	local wf=$1/.github/workflows
	if [ ! -d "$wf" ]; then
		echo "fedora-workflow-check: no $wf to check (refusing: an empty check proves nothing)" >&2
		return 2
	fi
	local out
	out=$(find "$wf" -type f \( -name '*.yml' -o -name '*.yaml' \) | sort | xargs -r awk -v allowed="$ALLOWED" '
	function bad(n,   i) { for (i in ok) if (ok[i] == n) return 0; return 1 }
	function rel(l, pat, why,   n, r, p, q) { # pat + digits: the release, a whole token (a hex run or digest is never one)
		r = l
		while (match(r, pat "[0-9]+")) {
			n = substr(r, RSTART + length(pat), RLENGTH - length(pat))
			p = (RSTART > 1) ? substr(r, RSTART - 1, 1) : ""
			q = substr(r, RSTART + RLENGTH, 1)
			if (bad(n) && q !~ /[A-Za-z0-9]/ && (pat != "fc" || (p !~ /[A-Za-z0-9]/ && length(n) == 2))) print FILENAME ":" FNR ": " why " " n ": " $0
			r = substr(r, RSTART + RLENGTH)
		}
	}
	# a number 30-59 that is a whole token: no letter, digit or dot beside it (not inside a hex run, a digest or 4.5)
	function nums(l, why,   n) {
		while (match(l, /(^|[^0-9A-Za-z.])[3-5][0-9]([^0-9A-Za-z.]|$)/)) {
			n = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", n)
			if (bad(n)) print FILENAME ":" FNR ": " why " " n ": " $0
			l = substr(l, RSTART + RLENGTH - 1)
		}
	}
	BEGIN { k = split(allowed, tmp, /[ ,]+/); for (i = 1; i <= k; i++) if (tmp[i] != "") ok[i] = tmp[i] }
	FNR == 1 { fed = 0 }
	{
		l = $0
		sub(/^[[:space:]]*#.*/, "", l); sub(/[[:space:]]#.*/, "", l)  # outside comments
		gsub(/fedora[0-9]+/, "", l)                                    # record-set name: data
		rel(l, "fedora:", "image fedora:")                          # rule:image
		rel(l, "fc", "cell fc")                            # rule:fc
		if (l ~ /fedora/) nums(l, "fedora line carries")              # rule:fedoraline
		if (l ~ /releases[^:]*:/) nums(l, "releases list carries")    # rule:releases
		if (l ~ /fedora:[[:space:]]*$/) { fed = FNR; next }
		if (fed && FNR - fed <= 6 && match(l, /^[[:space:]]*-[[:space:]]*["\047]?[0-9][0-9]["\047]?[[:space:]]*$/)) { # rule:block
			n = l; gsub(/[^0-9]/, "", n)
			if (bad(n)) print FILENAME ":" FNR ": fedora block list item " n ": " $0
		}
	}' || true)
	if [ -n "$out" ]; then
		printf '%s\n' "$out" | sort -u
		echo "fedora-workflow-check: a Fedora release outside the allowed list ($ALLOWED) in .github/workflows" >&2
		return 1
	fi
	echo "fedora-workflow-check: no Fedora release outside ($ALLOWED) in .github/workflows"
}

if [ "${1:-}" = "--self-test" ]; then
	t=$(mktemp -d)
	trap 'rm -rf "$t"' EXIT
	fails=0
	plant() { # name, expected rc, yaml body [, allowed list]
		local d=$t/$1 rc=0
		mkdir -p "$d/.github/workflows"
		printf '%s\n' "$3" > "$d/.github/workflows/ci.yml"
		ALLOWED_FEDORA=${4:-45} "$self" "$d" >/dev/null 2>&1 || rc=$?
		if [ "$rc" != "$2" ]; then echo "self-test FAIL $1: rc $rc, want $2" >&2; fails=$((fails + 1)); fi
	}
	# the 12 arms of omx-panel#148 @7d4fc3a, 44 being "not allowed"
	plant clean 0 'jobs:
  a:
    container:
      image: fedora:45'
	plant image44 1 'image: fedora:44'
	plant fc44name 1 'name: omx (fc44, x86_64)'
	plant matrix44last 1 'fedora: [45, 44]'
	plant matrix44mid 1 'fedora: [43, 44, 45]'
	plant blocklist 1 'fedora:
  - 45
  - 44'
	plant blocklistfirst 1 'fedora:
  - 44
  - 45'
	plant not144 0 'fedora: [45, 144]'
	plant rpm44 1 "rpm-releases: '[\"44\", \"45\"]'"
	plant rpm45 0 "rpm-releases: '[\"45\"]'"
	mkdir -p "$t/nodir"
	rc=0; "$self" "$t/nodir" >/dev/null 2>&1 || rc=$?
	if [ "$rc" != 2 ]; then echo "self-test FAIL missing dir: rc $rc, want 2" >&2; fails=$((fails + 1)); fi
	# plugin-db-qualification#32: the record-set name is data, an image on the same line is not
	plant recordset 0 'set: fedora44-x86-64'
	plant recordsetimage 1 'run: measure fedora44 on image: fedora:44'
	# outside comments only
	plant comment 0 '# was fedora:44 and fc44
      image: fedora:45 # not fedora:44 any more'
	# the allowed list is the input: widening it makes the 44 arms green, and 43 stays red
	plant allow44image 0 'image: fedora:44' '44 45'
	plant allow44fc 0 'name: omx (fc44, x86_64)' '44,45'
	plant allow44matrix 0 'fedora: [45, 44]' '44 45'
	plant allow44block 0 'fedora:
  - 44
  - 45' '44 45'
	plant allow44rpm 0 "rpm-releases: '[\"44\", \"45\"]'" '44 45'
	plant allow43 1 'image: fedora:43' '44 45'
	plant only44 1 'image: fedora:45' 44
	plant image29 1 'image: fedora:29'
	# hex SHAs and digests are not releases (B2, reac-pw test.yml): an fc or a number inside an alnum run is not a token
	plant sha 0 'REAC_PROTOCOL_REF: 26b16db9fc844820fed8adc26a342f6b86f3a1ba'
	plant digest 0 'image: quay.io/fedora/fedora-coreos@sha256:0f1a45b9c3d7e2a6b8d4f0c1e5a7b9d3f2c4e6a8b0d1f3a5c7e9b2d4f6a8c0e1'
	plant fc45inname 0 'name: omx (fc45, x86_64) rpm-0.1-1.fc45.x86_64'
	plant fc3digit 0 'name: build-fc144-x'
	plant fedoratag44x 0 'image: fedora:44abc'
	if [ "$fails" != 0 ]; then echo "fedora-workflow-check: self-test $fails red" >&2; exit 1; fi
	echo "fedora-workflow-check: self-test green (12 reference arms + 17)"
	exit 0
fi

rc=0
check "${1:-.}" || rc=$?
exit "$rc"
