#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The jackd2 package carries the jack2 metadata fix (jackaudio/jack2#988): Debian's jackd2 strands 9 Berkeley DB
# mutexes per client that dies without jack_client_close, until no client can open the metadata store (BDB2034), and a
# jackd restart does not clear it. In a Debian container (bookworm or trixie), as root, with the network:
#   - Debian's own jackd2 leaks (packaging/jackd2/check.sh says LEAK: the positive control, a check that never sees
#     the leak proves nothing);
#   - ours, built by the deb-deps action from packaging/jackd2 at the pins.txt commit and installed over it, does not
#     (check.sh says FIXED);
#   - its version sorts above the Debian build it replaces;
#   - the same source built without the patch (JACKD2_WITHOUT_PATCH=1) leaks again: the patch, not the rebuild, is
#     what fixes it.
# DEATHS (default 200) is how many clients each check kills.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
deaths=${DEATHS:-200}
failures=0
ok() { echo "ok      $1"; }
bad() { echo "FAILED  $1"; failures=$((failures + 1)); }
work=$(mktemp -d)

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git dpkg-dev debhelper build-essential lintian \
    jackd2 libjack-jackd2-dev db-util procps >/dev/null
debian_version=$(dpkg-query -W -f='${Version}' jackd2)

# check <name> <expected verdict, 0 FIXED or 1 LEAK>
check() {
    "$here/packaging/jackd2/check.sh" "$deaths" | tee "$work/check.out"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" = "$2" ]; then ok "$1"; else bad "$1 (check.sh exit $rc, wanted $2)"; fi
}

check "Debian's jackd2 $debian_version leaks (positive control)" 1

"$here/.github/actions/deb-deps/build.sh" "$work/ours" jackd2 >"$work/build.log" 2>&1 \
    || { tail -40 "$work/build.log"; bad "our jackd2 builds"; exit 1; }
ours=$(dpkg-query -W -f='${Version}' jackd2)
if dpkg --compare-versions "$ours" gt "$debian_version" && [ "$ours" = "$debian_version+omx1" ]; then
    ok "ours, $ours, sorts above Debian's $debian_version"
else
    bad "ours, $ours, is not $debian_version+omx1 above Debian's"
fi
check "ours releases what dead clients leave" 0

JACKD2_WITHOUT_PATCH=1 "$here/.github/actions/deb-deps/build.sh" "$work/sabotage" jackd2 >"$work/sabotage.log" 2>&1 \
    || { tail -40 "$work/sabotage.log"; bad "the build without the patch builds"; exit 1; }
# the same version as ours: apt keeps the installed one, dpkg puts the sabotage build in its place
dpkg -i "$work"/sabotage/*.deb >/dev/null
check "the same source without the patch leaks again (sabotage)" 1

[ "$failures" = 0 ] && echo "all passed" || echo "$failures failed"
exit $((failures > 0))
