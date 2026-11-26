#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the DEBs of a tree from its debian/ directory and lint them.
#
#   build-deb.sh [-C <tree>] [-t <release tag> | -r] [-s <separator>] [-L] <output dir>
#
# The version is the top entry of the tree's debian/changelog, whose body is regenerated from git (commit
# subjects since the previous tag, .github/actions/changelog/changelog.sh); when the tree also carries a packaging/*.spec its Version
# must be the same, one release cannot be two versions. With -t the tag must be v<version> and the tree
# must be that tag's commit; without it the build is a snapshot: the top changelog entry becomes
# <version>~git<commit time>.<short sha>, which sorts below the release; the commit's own time in seconds comes first so
# that the build of a later commit sorts above the build of an earlier one (a short sha alone sorts by chance). Lintian warnings fail the build; a tag that is deliberate carries an
# override with its reason in debian/. A snapshot build alone suppresses package-has-long-file-name: its name carries the commit
# time and sha by design, so a source with a long name draws it on the .changes and .buildinfo file names, which no package
# override covers; a tag build has no suffix and lints in full, and no other tag is suppressed. -s replaces the snapshot's ~git: +git sorts above the release, so a sibling built
# for another repository's tests (wave-deps) meets a (>= <version>) range; -L skips lintian for such a build, whose own CI
# lints it. -r builds the changelog's own version at HEAD with no tag and no snapshot suffix, and lints in full: a merge
# to devel builds the real package once (.github#289). After the build, every bare Depends/Pre-Depends of an OpenMixer
# package installed in the build root gets its floor, (>= <upstream version>), in the BUILT .debs, and a built package
# depending on one with no version fails the build (floors-deb.py, .github#312); the tree's debian/control stays bare,
# so the repository's own no-typed-floors test, which runs inside dpkg-buildpackage, still passes.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")

tree=.
tag=
real=
sep='~git'
lint=1
while getopts C:t:rs:L opt; do
    case $opt in
        C) tree=$OPTARG ;;
        t) tag=$OPTARG ;;
        r) real=1 ;;
        s) sep=$OPTARG ;;
        L) lint=0 ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
mkdir -p "${1:?usage: build-deb.sh [-C <tree>] [-t <release tag> | -r] [-s <separator>] [-L] <output dir>}"
[ -z "$tag" ] || [ -z "$real" ] || { echo "-t and -r exclude each other" >&2; exit 2; }
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

# the changelog the DEBs carry: render-changelog.sh, the one rendering (contract-bootstrap's bootstrap.sh packs it too)
"$here/render-changelog.sh" -C . ${tag:+-t "$tag"} ${real:+-r} -s "$sep" >/dev/null

apt-get build-dep -y --no-install-recommends ./
command -v python3 >/dev/null || apt-get install -y --no-install-recommends python3-minimal
dpkg-buildpackage -b -uc -us
mapfile -t built < <(find .. -maxdepth 1 -name '*.deb' ! -name '*-dbgsym_*')
# the repack is dated like the build (the changelog's time), so two builds of one commit stay the same bytes
SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -S Timestamp) python3 "$here/floors-deb.py" apply-deb "${built[@]}"
python3 "$here/floors-deb.py" check "${built[@]}"

changes=$(ls ../"${name}"_*.changes)
# a repacked .deb has new sums: the .buildinfo and the .changes are rewritten to them before lintian reads them
python3 "$here/floors-deb.py" restamp "$changes"
suppress=()
[ -n "$tag" ] || [ -n "$real" ] || suppress=(--suppress-tags package-has-long-file-name)
[ "$lint" = 0 ] || lintian --fail-on error,warning "${suppress[@]}" "$changes"

find .. -maxdepth 1 -name '*.deb' ! -name '*-dbgsym_*' -exec cp {} "$out/" \;
ls "$out"/*.deb
