#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Lay out DISTRHO-Ports' source as the spec builds it: the upstream commit .github/pins.txt names, with every
# submodule at the commit that commit records (a GitHub archive of the repository holds none of them, and the ports
# do not build without their JUCE versions).
#
#   make-source.sh <dir>                      the checkout, with its .git directories, for the DEB build
#   make-source.sh <dir> <tarball>            the same without .git, as the tarball the spec's Source0 names
#
# The tarball is reproducible: sorted names, owner 0, the commit's time as mtime. Needs git and tar.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
read -r _ url pin < <(grep '^DISTRHO-Ports ' "$here/../../.github/pins.txt") || { echo "DISTRHO-Ports has no line in pins.txt" >&2; exit 1; }
dir=$(readlink -m "${1:?usage: make-source.sh <dir> [<tarball>]}")

retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        [ "$attempt" = 5 ] && return 1
        sleep $((attempt * 3))
    done
}

mkdir -p "$dir"
git -C "$dir" init -q
retry git -C "$dir" fetch -q --depth 1 "$url" "$pin"
git -C "$dir" checkout -q FETCH_HEAD
[ "$(git -C "$dir" rev-parse HEAD)" = "$pin" ] || { echo "DISTRHO-Ports is not at $pin" >&2; exit 1; }
retry git -C "$dir" submodule update --init --recursive --depth 1 --jobs 4

if [ -n "${2:-}" ]; then
    tarball=$(readlink -m "$2")
    when=$(git -C "$dir" log -1 --format=%ct)
    find "$dir" -name .git -prune -exec rm -rf {} +
    parent=$(dirname "$dir")
    base=$(basename "$dir")
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$when" \
        --transform "s,^$base,DISTRHO-Ports-$pin," -C "$parent" -czf "$tarball" "$base"
fi
