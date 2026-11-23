#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Lay out mod-host's source at the commit of the OpenMixer fork that .github/pins.txt names: the one source of the
# mod-host packages and of the protocol library the source builds in CI use. The fork carries the upstream pull
# requests as commits, so nothing is applied here.
#
#   fetch-source.sh <dir> [<subject>...]
#
# Each <subject> after the directory names a commit of the fork whose fix is taken out again, for a sabotage run:
# the src/ part of that commit is reversed and the tests it brought stay, so those tests must fail. Needs git.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pins=$here/../../pins.txt
dir=$(readlink -m "${1:?usage: fetch-source.sh <dir> [<subject of a fix to take out>...]}")
shift

read -r _ url ref < <(grep '^mod-host ' "$pins") || { echo "mod-host has no line in pins.txt" >&2; exit 1; }
[[ $ref =~ ^[0-9a-f]{40}$ ]] || { echo "pins.txt names no commit for mod-host" >&2; exit 1; }

mkdir -p "$dir"
git -C "$dir" init -q
# history as far back as the fixes a sabotage run takes out; a plain build needs the commit alone
depth=1
[ $# -eq 0 ] || depth=200
for attempt in 1 2 3 4 5; do
    git -C "$dir" fetch -q --depth "$depth" "$url" "$ref" && break
    [ "$attempt" = 5 ] && { echo "could not fetch mod-host $ref" >&2; exit 1; }
    sleep $((attempt * 3))
done
git -C "$dir" checkout -q FETCH_HEAD
[ "$(git -C "$dir" rev-parse HEAD)" = "$ref" ] || { echo "mod-host is not at $ref" >&2; exit 1; }

for subject in "$@"; do
    commit=$(git -C "$dir" log --no-merges --format=%H --fixed-strings --grep="$subject" -n 1)
    [ -n "$commit" ] || { echo "no commit of the fork says \"$subject\"" >&2; exit 1; }
    git -C "$dir" show "$commit" -- src | git -C "$dir" apply -R
    echo "sabotage: the src/ part of $commit ($subject) is reversed" >&2
done
