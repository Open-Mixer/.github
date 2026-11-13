#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the mod-host RPMs, with mod-host-protocol and mod-host-protocol-devel, into $1: the OpenMixer fork at the
# commit .github/pins.txt names, by its own packaging/mod-host.spec (actions/build-rpm/build-rpm.sh). When the fork's
# tag v<Version> is that commit the build is the release (<Version>-<Release>), otherwise a snapshot
# (<Version>-<Release>.git<sha>). Runs as root in a Fedora container.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$(readlink -m "${1:?usage: build.sh <output dir>}")
src=$(mktemp -d)/mod-host

# pipewire's jack first: the builddep would pull jack-audio-connection-kit-devel, which conflicts with it
dnf install -y --setopt=install_weak_deps=False git rpm-build dnf5-plugins gcc make tar gzip python3 pkgconf-pkg-config \
    pipewire-jack-audio-connection-kit-devel
"$here/../mod-host-protocol/fetch-source.sh" "$src"
git config --global --add safe.directory "$src"
dnf builddep -y --setopt=install_weak_deps=False "$src"/packaging/mod-host.spec
version=$(sed -n 's/^Version: *//p' "$src"/packaging/mod-host.spec)
read -r _ url _ < <(grep '^mod-host ' "$here/../../pins.txt")
tag=()
if git -C "$src" fetch -q --depth 1 "$url" "refs/tags/v$version:refs/tags/v$version" 2>/dev/null &&
    [ "$(git -C "$src" rev-parse "v$version^{commit}")" = "$(git -C "$src" rev-parse HEAD)" ]; then
    tag=(-t "v$version")
fi
"$here/../build-rpm/build-rpm.sh" -C "$src" "${tag[@]}" "$out.all"

mkdir -p "$out/SRPMS"
find "$out.all" -name '*.rpm' ! -name '*.src.rpm' ! -name '*-debug*' -exec cp {} "$out/" \;
# the source package the binaries name in their SOURCERPM header, in a directory of its own so that the
# mod-host-[0-9]*.rpm globs of the callers never match it
cp "$out.all"/mod-host-[0-9]*.src.rpm "$out/SRPMS/"
srpm=$(ls "$out"/SRPMS/mod-host-[0-9]*.src.rpm)
[ "$(rpm -qp --qf '%{SOURCERPM}' "$out"/mod-host-[0-9]*.rpm | sort -u)" = "$(basename "$srpm")" ] ||
    { echo "the binaries do not name $(basename "$srpm") as their source package" >&2; exit 1; }
ls "$out"/mod-host-[0-9]*.rpm "$out"/mod-host-protocol-[0-9]*.rpm "$out"/mod-host-protocol-devel-*.rpm
