#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The synthv1 and samplv1 packages: each spec builds the v1.5.1 commit pins.txt pins and carries upstream's teardown
# fix as its own patch, named by the upstream commit; the packages keep Fedora's names; the Release sorts above
# Fedora's builds (0.9.91 on fc44, 1.4.2 on fc45) and above a stock 1.5.1-1, so dnf replaces them in place; the
# spec hands CMake the JACK library, without which the JACK stand-alone is silently not built. Then the .omx is taken
# out of a Release and the sort check must fail. Needs rpm and rpm-build (rpmspec), as in a Fedora container.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

ok() { echo "ok      $1"; }
bad() { echo "FAILED  $1"; failures=$((failures + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# above <evr> <older>...: the spec's EVR sorts above every older one, by rpm's own comparison
above() {
    local evr=$1 old; shift
    for old in "$@"; do
        [ "$(rpm --eval "%{lua: print(rpm.vercmp('$evr', '$old'))}")" = 1 ] || { echo "        $evr does not sort above $old"; return 1; }
    done
}
evr_of() { rpmspec -q --srpm --qf '%{VERSION}-%{RELEASE}\n' --define "dist .fc$2" "$1" 2>/dev/null; }

for n in synthv1 samplv1; do
    case $n in
        synthv1) fix=893c6e5 fedora44=0.9.91-4.fc42 ;;
        samplv1) fix=14e64f7 fedora44=0.9.91-5.fc42 ;;
    esac
    pkg=$here/packaging/$n
    spec=$pkg/$n.spec
    pin=$(sed -n "s/^$n [^ ]* //p" "$here/.github/pins.txt")
    commit=$(sed -n 's/^%global commit0 *//p' "$spec")
    check "$n: the spec builds the pinned commit" test -n "$pin" -a "$pin" = "$commit"
    check "$n: the version is 1.5.1" test "$(sed -n 's/^Version: *//p' "$spec")" = 1.5.1
    check "$n: the fix is a patch of its own, named by upstream's commit $fix" \
        grep -qx "Patch1: %{name}-$fix-sched-teardown.patch" "$spec"
    check "$n: the patch is in overlay/, where the build takes its sources" test -s "$pkg/overlay/$n-$fix-sched-teardown.patch"
    check "$n: the patch is the teardown fix" grep -q "^+.*${n}_sched::sync_cancel" "$pkg/overlay/$n-$fix-sched-teardown.patch"
    check "$n: Fedora's package names, $n and lv2-$n" \
        test "$(rpmspec -q --qf '%{NAME}\n' "$spec" 2>/dev/null | sort | tr '\n' ' ')" = "lv2-$n $n "
    check "$n: CMake is handed the JACK library" grep -q '^%cmake -DJACK_LIBRARY="\$jack_lib"' "$spec"
    e44=$(evr_of "$spec" 44); e45=$(evr_of "$spec" 45)
    check "$n: fc44 $e44 sorts above Fedora's $fedora44 and a stock 1.5.1-1.fc44" above "$e44" "$fedora44" 1.5.1-1.fc44
    check "$n: fc45 $e45 sorts above Fedora's 1.4.2-6.fc45 and a stock 1.5.1-1.fc45" above "$e45" 1.4.2-6.fc45 1.5.1-1.fc45
done

# sabotage: a Release without .omx ties with a stock 1.5.1-1, so the sort check above must refuse it
sed 's/^Release: 1\.omx%{?dist}$/Release: 1%{?dist}/' "$here/packaging/synthv1/synthv1.spec" > "$work/synthv1.spec"
if above "$(evr_of "$work/synthv1.spec" 44)" 1.5.1-1.fc44 >/dev/null; then
    bad "sabotage: a Release without .omx passed the sort check"
else
    ok "sabotage: a Release without .omx does not sort above a stock 1.5.1-1, so the check above is live"
fi

[ "$failures" = 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
