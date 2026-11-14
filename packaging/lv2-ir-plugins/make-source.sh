#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# ir.lv2's source as the spec builds it: upstream publishes no archive (its git is git.hq.sig7.se, which Fedora's own
# spec clones by hand), so the tarball is made from the commit .github/pins.txt names.
#
#   make-source.sh <dir> <tarball>
#
# The tarball is reproducible: sorted names, owner 0, the commit's time as mtime. Needs git and tar.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
read -r _ url pin < <(grep '^lv2-ir-plugins ' "$here/../../.github/pins.txt") || { echo "lv2-ir-plugins has no line in pins.txt" >&2; exit 1; }
dir=$(readlink -m "${1:?usage: make-source.sh <dir> <tarball>}")
tarball=$(readlink -m "${2:?usage: make-source.sh <dir> <tarball>}")

retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        [ "$attempt" = 5 ] && return 1
        sleep $((attempt * 3))
    done
}

# the server speaks git's dumb HTTP: no shallow fetch and no fetch by commit, so the history is cloned whole
rm -rf "$dir"
retry git clone -q "$url" "$dir"
git -C "$dir" checkout -q "$pin"
[ "$(git -C "$dir" rev-parse HEAD)" = "$pin" ] || { echo "ir.lv2 is not at $pin" >&2; exit 1; }
when=$(git -C "$dir" log -1 --format=%ct)
rm -rf "$dir/.git"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$when" \
    --transform "s,^$(basename "$dir"),lv2-ir-plugins-$pin," -C "$(dirname "$dir")" -czf "$tarball" "$(basename "$dir")"
