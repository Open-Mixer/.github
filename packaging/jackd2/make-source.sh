#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Lay out Debian's own jackd2 source for this Debian release with the jack2 metadata fix as one more quilt patch.
#
#   make-source.sh <dir>
#
# The source is the Debian packaging repository at the commit of the jackd2-<release> line of .github/pins.txt
# (<release> is VERSION_CODENAME of /etc/os-release, or SUITE): Debian's upstream tree, debian/ and patches, untouched.
# patches/*.patch beside this script are appended to debian/patches/series, and a debian/changelog entry
# <Debian version>+omx1 is added on top, so the package sorts above the one it replaces and below Debian's next upload.
# JACKD2_WITHOUT_PATCH=1 lays out the same source and version without the patches: the sabotage arm of
# tests/jackd2-metadata.sh, which must reproduce the leak again (README.md, "Proof").
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pins=$here/../../.github/pins.txt
src=$(readlink -m "${1:?usage: make-source.sh <dir>}")
with_patch=1
[ "${JACKD2_WITHOUT_PATCH:-}" = 1 ] && with_patch=0
suite=${SUITE:-$(. /etc/os-release && echo "${VERSION_CODENAME:-}")}
[ -n "$suite" ] || { echo "no Debian release name in /etc/os-release, set SUITE" >&2; exit 1; }

read -r _ url ref < <(grep "^jackd2-$suite " "$pins") || { echo "jackd2-$suite has no line in pins.txt" >&2; exit 1; }
mkdir -p "$src"
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$url" "$ref"
git -C "$src" checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$ref" ] || { echo "jackd2-$suite is not at $ref" >&2; exit 1; }
rm -rf "$src/.git"

if [ "$with_patch" = 1 ]; then
    for patch in "$here"/patches/*.patch; do
        cp "$patch" "$src/debian/patches/"
        basename "$patch" >>"$src/debian/patches/series"
    done
fi

# the +omx1 entry: what Debian built, plus the fix, for this release
version=$(cd "$src" && dpkg-parsechangelog -S Version)
entry=$(mktemp)
{
    echo "jackd2 ($version+omx1) $suite; urgency=medium"
    echo
    echo "  * OpenMixer build of Debian's jackd2 $version with the jack2 metadata fix"
    echo "    (https://github.com/jackaudio/jack2/issues/988): the server releases"
    echo "    what dead clients leave in the Berkeley DB environment."
    echo
    echo " -- Pau Aliagas <linuxnow@gmail.com>  $(LC_ALL=C date -u -R -d @"${SOURCE_DATE_EPOCH:-1795392000}")"
    echo
    cat "$src/debian/changelog"
} >"$entry"
mv "$entry" "$src/debian/changelog"
echo "jackd2 $version+omx1 for $suite in $src ($([ "$with_patch" = 1 ] && echo with || echo WITHOUT) the metadata fix)"
