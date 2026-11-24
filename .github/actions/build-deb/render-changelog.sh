#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Write a tree's debian/changelog the way its DEBs carry it: the top entry's body regenerated from git
# (.github/actions/changelog/changelog.sh), and, for a snapshot, the top entry's version <version><separator><commit
# time>.<short sha>. The one rendering build-deb.sh builds with and contract-bootstrap's bootstrap.sh packs, so a
# -contract package built alone carries the changelog its library's own build of that commit carries, byte for byte.
#
#   render-changelog.sh [-C <tree>] [-t <release tag>] [-s <separator>]
#
# With -t the tag must be v<version> and the tree must be that tag's commit, and the version is left as it is; without
# it the entry is a snapshot's, joined by <separator> (default ~git). The tree needs its tags and history (changelog.sh).
# Prints the version written.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tree=.
tag=
sep='~git'
while getopts C:t:s: opt; do
    case $opt in
        C) tree=$OPTARG ;;
        t) tag=$OPTARG ;;
        s) sep=$OPTARG ;;
        *) exit 2 ;;
    esac
done
cd "$tree"
[ -f debian/changelog ] || { echo "$tree has no debian/changelog" >&2; exit 1; }
version=$(dpkg-parsechangelog -S Version)
short=$(git rev-parse --short HEAD)
stamp=$(git log -1 --format=%ct HEAD).$short
"$here/../changelog/changelog.sh" deb -C . "${tag:-HEAD}"
if [ -n "$tag" ]; then
    [ "$tag" = "v$version" ] || { echo "tag $tag is not v$version, the debian/changelog version" >&2; exit 1; }
    [ "$(git rev-parse "$tag^{commit}")" = "$(git rev-parse HEAD)" ] || { echo "the tree is not at $tag" >&2; exit 1; }
    echo "$version"
else
    sed -i "1s/^\\(\\S\\+\\) (\\([^)]*\\))/\\1 ($version$sep$stamp)/" debian/changelog
    echo "$version$sep$stamp"
fi
