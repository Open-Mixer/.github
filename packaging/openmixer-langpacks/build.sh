#!/bin/bash
# Build the OpenMixer meta language packs, one per language omx-contract ships.
#
#   build.sh rpm|deb <languages.json> <output dir> [<owners file>]
#
# <languages.json> is omx-contract's language list (/usr/share/omx-contract/languages.json of omx-contract-data);
# <owners file> defaults to owners.txt beside this script. The subpackages (rpm openmixer-langpack-<lang>, deb
# openmixer-l10n-<lang>) are written into a copy of this directory by langpacks.py meta before the build, so the
# list is read from its declaration and never copied here. The RPM's Version-Release and the DEB's version are one
# release: a build where they differ is refused. rpm runs in a Fedora container with rpm-build and python3; deb in a
# Debian one with dpkg-dev, debhelper, lintian and python3.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
usage='usage: build.sh rpm|deb <languages.json> <output dir> [<owners file>]'
kind=${1:?$usage}
languages=$(readlink -f "${2:?$usage}")
out=$(readlink -m "${3:?$usage}")
owners=$(readlink -f "${4:-$here/owners.txt}")
generator=$here/../../.github/actions/langpacks/langpacks.py
spec=$here/openmixer-langpacks.spec

version=$(sed -n 's/^Version: *//p' "$spec")
release=$(sed -n 's/^Release: *\([0-9][0-9.]*\)%{?dist}$/\1/p' "$spec")
[ -n "$version" ] && [ -n "$release" ] || { echo "no Version or Release N%{?dist} in $spec" >&2; exit 1; }
debver=$(sed -n '1s/^openmixer-langpacks (\([^)]*\)).*/\1/p' "$here/debian/changelog")
[ "$debver" = "$version-$release" ] || { echo "debian/changelog says $debver, the spec $version-$release" >&2; exit 1; }

mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
cp "$spec" "$work/src/"
cp -r "$here/debian" "$work/src/debian"
python3 "$generator" meta --spec "$work/src/openmixer-langpacks.spec" --debian "$work/src/debian" \
    --owners "$owners" --languages "$languages"
case "$kind" in
rpm)
    rpmbuild --define "_topdir $work" -bb "$work/src/openmixer-langpacks.spec"
    find "$work/RPMS" -name 'openmixer-langpack-*.noarch.rpm' -exec cp {} "$out/" \;
    ls "$out"/openmixer-langpack-*.noarch.rpm
    ;;
deb)
    (cd "$work/src" && dpkg-buildpackage -b -uc -us && lintian --fail-on error,warning ../openmixer-langpacks_*.changes)
    cp "$work"/openmixer-l10n-*_all.deb "$out/"
    ls "$out"/openmixer-l10n-*_all.deb
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
