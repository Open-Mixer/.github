#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The channel serves openmixer-release in every Fedora release the set builds: fedora/<release>/noarch of the tree lists
# it, at the release the packaging carries when one is named. A Fedora release the quick set builds whose repodata
# lacks the package is red, by name: a machine of that release that installs the stable name gets the repository but
# never an update of it (fc45, 2026-11-15: the fc44 build alone was served, dnf on fc45 found no openmixer-release in
# openmixer-noarch).
#
#   served-check.sh [<base url>=https://www.openmixer.org] [<Version-Release>]
#
# The releases come from the quick set (.github/actions/release-matrix/quick.txt, the one list), never from here.
# Needs curl and zstd (or gzip/xz for an older index). Exit 0 when every release serves it, 1 when one does not, 2 when
# the channel could not be read.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
base=${1:-https://www.openmixer.org}
evr=${2:-}
quick=$here/../../.github/actions/release-matrix/quick.txt
releases=$(awk '$1 == "rpm" && !/^#/ {print $2}' "$quick" | sort -un)
[ -n "$releases" ] || { echo "served-check: no rpm cell in $quick" >&2; exit 2; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
for rel in $releases; do
    url=$base/rpm/fedora/$rel/noarch
    primary=$(curl -fsSL --retry 3 --connect-timeout 20 "$url/repodata/repomd.xml" | sed -n 's/.*href="\(repodata\/[^"]*primary\.xml[^"]*\)".*/\1/p' | head -1) ||
        { echo "served-check: fedora/$rel/noarch: no repomd.xml at $url" >&2; exit 2; }
    [ -n "$primary" ] || { echo "served-check: fedora/$rel/noarch: repomd.xml names no primary index" >&2; exit 2; }
    curl -fsSL --retry 3 --connect-timeout 20 -o "$t/primary" "$url/$primary" || { echo "served-check: fedora/$rel/noarch: cannot read $primary" >&2; exit 2; }
    case $primary in
    *.zst) zstd -dqc "$t/primary" ;;
    *.gz) gzip -dc "$t/primary" ;;
    *.xz) xz -dc "$t/primary" ;;
    *) cat "$t/primary" ;;
    esac > "$t/primary.xml"
    # one <package> at a time: its name and its version element
    served=$(tr -d '\n' < "$t/primary.xml" | grep -o '<package type="rpm">.*' | sed 's/<\/package>/\n/g' |
        grep '<name>openmixer-release</name>' | sed -n 's/.*<version [^>]*ver="\([^"]*\)"[^>]*rel="\([^"]*\)".*/\1-\2/p' | sort -u | tr '\n' ' ' || true)
    if [ -z "$served" ]; then
        echo "RED fedora/$rel/noarch serves no openmixer-release"; fail=1
    elif [ -n "$evr" ] && ! grep -q " $evr\.fc$rel " <<< " $served"; then
        echo "RED fedora/$rel/noarch serves openmixer-release $served, not $evr.fc$rel"; fail=1
    else
        echo "ok  fedora/$rel/noarch serves openmixer-release $served"
    fi
done
exit $fail
