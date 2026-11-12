#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the RPMs of a tree from a tarball of it.
#
#   build-rpm.sh [-C <tree>] [-t <release tag>] [-n] <output dir>
#
# The spec is the tree's only packaging/*.spec and the version is its own. With -t the tag must be
# v<version> and the tree must be that tag's commit; without it the build is a snapshot: the release
# carries .git<short sha>. The spec's %changelog is generated from git (commit subjects since the previous
# tag, .github/actions/changelog/changelog.sh); the version is the spec's. BuildRequires must be installed. -n skips
# %check (rpmbuild --nocheck): a sibling built for another repository's tests (wave-deps), whose own CI runs its tests.
set -euo pipefail

tree=.
tag=
check=()
while getopts C:t:n opt; do
    case $opt in
        C) tree=$OPTARG ;;
        t) tag=$OPTARG ;;
        n) check=(--nocheck) ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
out=$(readlink -m "${1:?usage: build-rpm.sh [-C <tree>] [-t <release tag>] [-n] <output dir>}")
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

if [ -n "$tag" ]; then
    [ "$tag" = "v$version" ] || { echo "tag $tag is not v$version, the spec's version" >&2; exit 1; }
    [ "$(git -C "$tree" rev-parse "$tag^{commit}")" = "$(git -C "$tree" rev-parse HEAD)" ] ||
        { echo "the tree is not at $tag" >&2; exit 1; }
    ref=$tag
else
    sed -i "s/^Release: *\([0-9][0-9]*\)%{?dist}/Release: \1.git$short%{?dist}/" "$spec"
    ref=HEAD
fi
release=$(sed -n 's/^Release: *\(.*\)%{?dist}$/\1/p' "$spec")
# %changelog is the last section: whatever the spec holds after it is replaced by the entry made from git
grep -q '^%changelog' "$spec" || printf '\n%%changelog\n' >> "$spec"
sed -i '/^%changelog/q' "$spec"
"$(dirname "$(readlink -f "$0")")/../changelog/changelog.sh" rpm -C "$tree" "$ref" "$version-$release" >> "$spec"

git -C "$tree" archive --prefix="$name-$version/" HEAD | gzip -n > "$top/SOURCES/$name-$version.tar.gz"
rpmbuild --define "_topdir $top" "${check[@]}" -ba "$spec"
find "$top/RPMS" "$top/SRPMS" -name '*.rpm' -exec cp {} "$out/" \;
ls "$out"/*.rpm
