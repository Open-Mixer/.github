#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Empty the staging channel of a release wave and leave it a valid, empty repository: every package goes, and the
# metadata is regenerated (and signed, with a key) by the same tree scripts a publish uses, so a machine that still
# has the staging channel added reads an empty index rather than a 404. Only <channel>/staging/<kind> is written; the
# real tree, <channel>/rpm or <channel>/deb, and everything else in the channel stay as they are.
#
#   purge-staging.sh rpm|deb <channel> [<gpg key id>]     no key id: unsigned metadata, for inspection only
#
# SKELETON (Fedora releases or Debian releases, space separated) names releases whose empty index must exist even if the
# staging tree never held them; with deb, SKELETON_ARCHES the architectures (default amd64 arm64).
set -euo pipefail
kind=${1:?usage: purge-staging.sh rpm|deb <channel> [<gpg key id>]}
channel=$(readlink -m "${2:?usage: purge-staging.sh rpm|deb <channel> [<gpg key id>]}")
key=${3:-}
here=$(dirname "$(readlink -f "$0")")
tree=$channel/staging/$kind
case $kind in rpm | deb) ;; *) echo "purge-staging.sh: rpm or deb, not '$kind'" >&2; exit 2 ;; esac
[ -d "$channel" ] || { echo "no channel at $channel" >&2; exit 1; }
mkdir -p "$tree"
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT

# every path removed is found under the staging tree, by name, and is a package or its metadata
case $kind in
rpm)
    n=$(find "$tree" -type f -name '*.rpm' | wc -l)
    find "$tree" -type f -name '*.rpm' -delete
    find "$tree" -type d -name repodata -prune -exec rm -rf {} +
    REPO_FILE=$here/../../../packaging/staging/openmixer-staging.repo EMPTY_OK=true \
        "$here/../publish-rpms/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
deb)
    n=$(find "$tree" -type f -name '*.deb' | wc -l)
    find "$tree" -type f \( -name '*.deb' -o -name Packages -o -name Packages.gz -o -name Release \
        -o -name InRelease -o -name Release.gpg \) -delete
    rm -rf "$tree/changelogs"
    LABEL=OpenMixer-Staging EMPTY_OK=true "$here/../publish-debs/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
esac
left=$(find "$tree" -type f -name "*.$kind" | wc -l)
[ "$left" = 0 ] || { echo "the staging tree still holds $left package(s)" >&2; exit 1; }
echo "purged staging/$kind: $n package(s) removed, empty metadata regenerated"
