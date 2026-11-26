#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the RPMs of a tree from a tarball of it.
#
#   build-rpm.sh [-C <tree>] [-t <release tag> | -r] [-n] <output dir>
#
# The spec is the tree's only packaging/*.spec and the version is its own. With -t the tag must be
# v<version> and the tree must be that tag's commit; without it the build is a snapshot: the release
# carries .git<commit time>.<short sha>, the commit's own time in seconds, so that the build of a later commit sorts
# above the build of an earlier one (a short sha alone sorts by chance). The spec's %changelog is generated from git (commit subjects since the previous
# tag, .github/actions/changelog/changelog.sh); the version is the spec's. BuildRequires must be installed. -n skips
# %check (rpmbuild --nocheck): a sibling built for another repository's tests (wave-deps), whose own CI runs its tests.
# -r builds the spec's own version at HEAD with no tag and no snapshot stamp: a merge to devel builds the real package,
# once, and that build is what the staging channel serves and promotion copies to the channel root (.github#289).
# Every bare Requires of an OpenMixer package installed in the build root gets its floor, ">= <installed version>",
# in the build copy of the spec, and a built package requiring one with no version fails the build (floors.sh,
# .github#312): the spec in the tree names them bare, never with a hand-typed version.
set -euo pipefail

tree=.
tag=
real=
check=()
while getopts C:t:rn opt; do
    case $opt in
        C) tree=$OPTARG ;;
        t) tag=$OPTARG ;;
        r) real=1 ;;
        n) check=(--nocheck) ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
out=$(readlink -m "${1:?usage: build-rpm.sh [-C <tree>] [-t <release tag> | -r] [-n] <output dir>}")
[ -z "$tag" ] || [ -z "$real" ] || { echo "-t and -r exclude each other" >&2; exit 2; }
tree=$(readlink -f "$tree")

specs=("$tree"/packaging/*.spec)
[ "${#specs[@]}" -eq 1 ] && [ -f "${specs[0]}" ] || { echo "$tree/packaging holds no single spec" >&2; exit 1; }
name=$(basename "${specs[0]}" .spec)
version=$(sed -n 's/^Version: *//p' "${specs[0]}")
[ -n "$version" ] || { echo "no Version in the spec" >&2; exit 1; }

# Two builds of one commit give the same bytes (tests/build-rpm-same-bytes.sh): the build tree is one fixed path per
# package, because its path lands in the source package's header (rpm keeps the build scripts with the path written out)
# and in the debug info, and the source archive carries no clock (gzip -n). One build of a package at a time on a
# machine.
top=/tmp/omx-build/$name
rm -rf "$top"
mkdir -p "$top/SOURCES" "$top/SPECS" "$out"
spec=$top/SPECS/$name.spec
cp "${specs[0]}" "$spec"
short=$(git -C "$tree" rev-parse --short HEAD)
stamp=$(git -C "$tree" log -1 --format=%ct HEAD).$short

if [ -n "$tag" ]; then
    [ "$tag" = "v$version" ] || { echo "tag $tag is not v$version, the spec's version" >&2; exit 1; }
    [ "$(git -C "$tree" rev-parse "$tag^{commit}")" = "$(git -C "$tree" rev-parse HEAD)" ] ||
        { echo "the tree is not at $tag" >&2; exit 1; }
    ref=$tag
elif [ -n "$real" ]; then
    ref=HEAD
else
    sed -i "s/^Release: *\([0-9][0-9]*\)%{?dist}/Release: \1.git$stamp%{?dist}/" "$spec"
    ref=HEAD
fi
release=$(sed -n 's/^Release: *\(.*\)%{?dist}$/\1/p' "$spec")
# %changelog is the last section: whatever the spec holds after it is replaced by the entry made from git
grep -q '^%changelog' "$spec" || printf '\n%%changelog\n' >> "$spec"
sed -i '/^%changelog/q' "$spec"
"$(dirname "$(readlink -f "$0")")/../changelog/changelog.sh" rpm -C "$tree" "$ref" "$version-$release" >> "$spec"

here=$(dirname "$(readlink -f "$0")")
"$here/floors.sh" apply "$spec"

git -C "$tree" archive --prefix="$name-$version/" HEAD | gzip -n > "$top/SOURCES/$name-$version.tar.gz"
rpmbuild --define "_topdir $top" "${check[@]}" -ba "$spec"
mapfile -t built < <(find "$top/RPMS" -name '*.rpm')
"$here/floors.sh" check "${built[@]}"
find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp {} "$out/" \;
ls "$out"/*.rpm
