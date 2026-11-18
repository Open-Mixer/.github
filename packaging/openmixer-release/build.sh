#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build openmixer-release, the package that adds the OpenMixer repository, with the key file the channel serves.
#
#   build.sh rpm|deb <key file> <output dir>
#
# The package ships ONE key: the release signing key committed to this repository (channel-keys.sh ship), not the
# channel's bytes. <key file> is the file the channel serves to the package manager the package is for
# (rpm/RPM-GPG-KEY-openmixer, deb/openmixer.asc), fetched by the caller; build.sh only refuses a served file that
# holds a key this repository does not pin, and ships none of its content. The RPM's Version-Release and the DEB's
# version are one release: a build where they differ is refused. rpm runs in a Fedora container with rpm-build
# and gnupg2; deb in a Debian one with dpkg-dev, debhelper, lintian and gnupg, as root.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
usage='usage: build.sh rpm|deb <key file> <output dir>'
kind=${1:?$usage}
key=$(readlink -f "${2:?$usage}")
out=$(readlink -m "${3:?$usage}")
spec=$here/openmixer-release.spec

version=$(sed -n 's/^Version: *//p' "$spec")
release=$(sed -n 's/^Release: *\([0-9][0-9.]*\)%{?dist}$/\1/p' "$spec")
[ -n "$version" ] && [ -n "$release" ] || { echo "no Version or Release N%{?dist} in $spec" >&2; exit 1; }
debver=$(sed -n '1s/^openmixer-release (\([^)]*\)).*/\1/p' "$here/debian/changelog")
[ "$debver" = "$version-$release" ] || { echo "debian/changelog says $debver, the spec $version-$release" >&2; exit 1; }

primaries=$(gpg --batch --with-colons --import-options show-only --import < "$key" 2>/dev/null |
    awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
[ -n "$primaries" ] || { echo "no public key readable from $key" >&2; exit 1; }
# the channel serves that file and its writers could replace it: only a file of pinned primaries is shipped
"$here/../../.github/actions/import-gpg-key/channel-keys.sh" pinned "$key" ||
    { echo "$key holds a key this repository does not pin: not shipping it" >&2; exit 1; }

mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# what ships is the ONE release signing key, the one committed to this repository (channel-keys.sh ship, which
# refuses anything but exactly one key with the release uid), whatever the served file still holds
"$here/../../.github/actions/import-gpg-key/channel-keys.sh" ship "$key" > "$work/keys.asc"
"$here/../../.github/actions/import-gpg-key/channel-keys.sh" single "$work/keys.asc" > /dev/null
primaries=$(gpg --batch --with-colons --import-options show-only --import < "$work/keys.asc" 2>/dev/null |
    awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
key=$work/keys.asc
echo "openmixer-release $version-$release ($kind) ships $(tr '\n' ' ' <<< "$primaries")"
case "$kind" in
rpm)
    mkdir -p "$work/SOURCES"
    cp "$here/openmixer.repo" "$work/SOURCES/"
    cp "$key" "$work/SOURCES/RPM-GPG-KEY-openmixer"
    rpmbuild --define "_topdir $work" -bb "$spec"
    find "$work/RPMS" -name 'openmixer-release-*.noarch.rpm' -exec cp {} "$out/" \;
    ls "$out"/openmixer-release-*.noarch.rpm
    ;;
deb)
    mkdir -p "$work/src"
    cp -r "$here/debian" "$work/src/debian"
    cp "$key" "$work/src/debian/openmixer-archive-keyring.asc"
    (cd "$work/src" && dpkg-buildpackage -b -uc -us && lintian --fail-on error,warning ../openmixer-release_*.changes)
    cp "$work"/openmixer-release_*_all.deb "$out/"
    ls "$out"/openmixer-release_*_all.deb
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
