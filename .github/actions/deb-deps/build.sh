#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the Debian build dependencies of the OpenMixer packages.
#
#   build.sh <output dir> <name>...      name: a directory here holding its debian/ files
#
# mod-host-protocol is the OpenMixer fork of mod-host at its commit in .github/pins.txt, built by the fork's own
# debian/ (mod-host, libmod-host-protocol0, libmod-host-protocol-dev), the source the RPMs come from too; the
# installed library is checked by actions/mod-host-protocol/checks/framing-test.sh. The others are fetched at their
# commit in .github/pins.txt and given the debian/ directory of their name here. Each is built binary-only, linted
# and installed, so the next one and the packages that Build-Depend on it find it. Runs as root in a Debian
# container with dpkg-dev, debhelper, build-essential, git and lintian.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pins=$here/../../pins.txt
carried=$here/../../../packaging
mod_host=$here/../mod-host-protocol
out=$(readlink -m "${1:?usage: build.sh <output dir> <name>...}")
shift
mkdir -p "$out"
work=$(mktemp -d)

for name in "$@"; do
    src=$work/$name
    # the source package dpkg-buildpackage names its .changes after, and the lintian severity that fails it
    source=$name
    fail_on=error,warning
    if [ "$name" = mod-host-protocol ]; then
        # the fork packages itself; its sources keep upstream's style, so only an error fails the lint
        "$mod_host/fetch-source.sh" "$src"
        source=mod-host
        fail_on=error
    elif [ -x "$carried/$name/make-source.sh" ]; then
        # a source with submodules (Surge XT): the package lays out its own checkout
        "$carried/$name/make-source.sh" "$src"
    else
        [ -d "$here/$name" ] || { echo "no debian directory for $name" >&2; exit 1; }
        read -r _ url ref < <(grep "^$name " "$pins") || { echo "$name has no line in pins.txt" >&2; exit 1; }
        mkdir -p "$src"
        git -C "$src" init -q
        git -C "$src" fetch -q --depth 1 "$url" "$ref"
        git -C "$src" checkout -q FETCH_HEAD
        [ "$(git -C "$src" rev-parse HEAD)" = "$ref" ] || { echo "$name is not at $ref" >&2; exit 1; }
    fi
    # the files the packaging lays on the upstream source (a build system upstream does not ship), as the RPM does
    if [ "$name" != mod-host-protocol ]; then
        [ -d "$carried/$name/overlay" ] && cp -r "$carried/$name/overlay/." "$src/"
        cp -r "$here/$name" "$src/debian"
    fi
    (cd "$src" && apt-get build-dep -y --no-install-recommends ./ >/dev/null && dpkg-buildpackage -b -uc -us && lintian --fail-on "$fail_on" ../"${source}"_*.changes)
    find "$work" -maxdepth 1 -name '*-dbgsym_*.deb' -delete
    cp "$work"/*.deb "$out/"
    apt-get install -y --no-install-recommends "$work"/*.deb
    if [ "$name" = mod-host-protocol ]; then
        "$mod_host/checks/framing-test.sh"
    fi
    find "$work" -maxdepth 1 -name '*.deb' -delete
done
ls "$out"
