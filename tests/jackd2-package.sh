#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The jackd2 package, without building it: pins.txt pins Debian's packaging repository for trixie; the
# carried patch has its DEP-3 header (Description, Author, Bug naming jackaudio/jack2#988, Forwarded) and touches only
# jack2's metadata and engine; the release workflow builds trixie, gives the container room in /dev/shm
# and runs the leak check in every cell and the proof before it publishes; and the README says what goes away with
# the patch. tests/jackd2-metadata.sh builds and measures it (packaging/jackd2/README.md, "Proof").
# Then the Bug line is taken out of a copy of the patch and the header check must fail.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pkg=$here/packaging/jackd2
wf=$here/.github/workflows/jackd2-deb.yml
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok      $1"; }
bad() { echo "FAILED  $1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

pinned() { grep -Eq "^jackd2-$1 https://salsa\.debian\.org/multimedia-team/jackd2\.git [0-9a-f]{40}\$" "$here/.github/pins.txt"; }
check "pins.txt pins Debian's jackd2 for trixie" pinned trixie

patches=("$pkg"/patches/*.patch)
check "one patch is carried" test "${#patches[@]}" = 1 -a -f "${patches[0]}"
patch=${patches[0]}

# dep3 <patch>: the header, up to the first ---, carries the fields Debian's DEP-3 asks of a patch not yet upstream
dep3() {
    local head
    head=$(sed '/^---$/q' "$1")
    grep -q '^Description: ' <<<"$head" && grep -q '^Author: ' <<<"$head" \
        && grep -qx 'Bug: https://github.com/jackaudio/jack2/issues/988' <<<"$head" \
        && grep -Eq '^Forwarded: (not-yet|https://github\.com/jackaudio/jack2/pull/[0-9]+)$' <<<"$head"
}
check "the patch has its DEP-3 header" dep3 "$patch"
check "the patch touches jack2's metadata and engine only" \
    test "$(grep '^+++ ' "$patch" | sort | tr '\n' ' ')" = "+++ b/common/JackEngine.cpp +++ b/common/JackMetadata.cpp +++ b/common/JackMetadata.h "

check "make-source.sh and check.sh are executable" test -x "$pkg/make-source.sh" -a -x "$pkg/check.sh"
check "the version is the Debian one plus +omx1" grep -q '(\$version+omx1)' "$pkg/make-source.sh"
check "the workflow builds trixie" grep -q "releases: '\[\"trixie\"\]'" "$wf"
check "the workflow gives jackd room in /dev/shm" test "$(grep -c -- '--shm-size=1g' "$wf")" -ge 2
check "every cell runs the leak check" grep -q 'packaging/jackd2/check.sh' "$wf"
check "nothing publishes before the proof" test "$(grep -c 'needs: \[plan, build, proof\]' "$wf")" = 2
check "the README says the pin goes away with the patch" grep -q 'preferences.d/openmixer-jackd2' "$pkg/README.md"

# sabotage: a copy of the patch with no Bug line must fail the header check
sed '/^Bug: /d' "$patch" >"$work/no-bug.patch"
if dep3 "$work/no-bug.patch"; then bad "a patch without its Bug line fails the header check"; else ok "a patch without its Bug line fails the header check"; fi

[ "$failures" = 0 ] && echo "all passed" || echo "$failures failed"
exit $((failures > 0))
