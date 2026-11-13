#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the DEBs of a tree from its debian/ directory and lint them.
#
#   build-deb.sh [-C <tree>] [-t <release tag>] [-s <separator>] [-L] <output dir>
#
# The version is the top entry of the tree's debian/changelog, whose body is regenerated from git (commit
# subjects since the previous tag, .github/actions/changelog/changelog.sh); when the tree also carries a packaging/*.spec its Version
# must be the same, one release cannot be two versions. With -t the tag must be v<version> and the tree
# must be that tag's commit; without it the build is a snapshot: the top changelog entry becomes
# <version>~git<commit time>.<short sha>, which sorts below the release; the commit's own time in seconds comes first so
# that the build of a later commit sorts above the build of an earlier one (a short sha alone sorts by chance). Lintian warnings fail the build; a tag that is deliberate carries an
# override with its reason in debian/. -s replaces the snapshot's ~git: +git sorts above the release, so a sibling built
# for another repository's tests (wave-deps) meets a (>= <version>) range; -L skips lintian for such a build, whose own CI
# lints it.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")

tree=.
tag=
sep='~git'
lint=1
while getopts C:t:s:L opt; do
    case $opt in
        C) tree=$OPTARG ;;
        t) tag=$OPTARG ;;
        s) sep=$OPTARG ;;
        L) lint=0 ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
mkdir -p "${1:?usage: build-deb.sh [-C <tree>] [-t <release tag>] [-s <separator>] [-L] <output dir>}"
out=$(readlink -f "$1")
tree=$(readlink -f "$tree")
cd "$tree"

[ -f debian/changelog ] || { echo "$tree has no debian/changelog" >&2; exit 1; }
version=$(dpkg-parsechangelog -S Version)
name=$(dpkg-parsechangelog -S Source)
for spec in packaging/*.spec; do
    [ -f "$spec" ] || continue
    specver=$(sed -n 's/^Version: *//p' "$spec")
    [ "$specver" = "$version" ] || { echo "debian/changelog says $version, $spec says $specver" >&2; exit 1; }
done

short=$(git rev-parse --short HEAD)
stamp=$(git log -1 --format=%ct HEAD).$short
"$here/../changelog/changelog.sh" deb -C . "${tag:-HEAD}"
if [ -n "$tag" ]; then
    [ "$tag" = "v$version" ] || { echo "tag $tag is not v$version, the debian/changelog version" >&2; exit 1; }
    [ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "the tree is not at $tag" >&2; exit 1; }
else
    sed -i "1s/^\\(\\S\\+\\) (\\([^)]*\\))/\\1 ($version$sep$stamp)/" debian/changelog
fi

apt-get build-dep -y --no-install-recommends ./
dpkg-buildpackage -b -uc -us

changes=$(ls ../"${name}"_*.changes)
[ "$lint" = 0 ] || lintian --fail-on error,warning "$changes"

find .. -maxdepth 1 -name '*.deb' ! -name '*-dbgsym_*' -exec cp {} "$out/" \;
ls "$out"/*.deb
