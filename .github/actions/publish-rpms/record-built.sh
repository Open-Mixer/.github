#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# record-built.sh <tree> <commit> <name> <package file>...
#
# A merge to devel stages the REAL package, whose name holds no commit (.github#289). This records which commit built it:
# <tree>/built/<name>/<version>.commit holds the full commit, one line, for every version among the packages (rpm
# %{VERSION}; deb Version without epoch or revision). <name> is the caller's package-name, the ONE key both kinds write
# and every reader reads (release-preflight, devel-bump-check, promote-staged): never the spec's Name or the deb Source,
# which differ (plugin-db-qualification: rpm Name plugin-qualification-records, deb Source plugin-db-qualification). The
# kind stays in the path through <tree> (staging/rpm, staging/deb): each kind publishes in a run of its own.
# publish-tree.sh of publish-rpms and publish-debs runs it with BUILT_COMMIT and BUILT_NAME set. A record that names
# another commit is refused, naming it: a version is built once.
set -euo pipefail
usage='usage: record-built.sh <tree> <commit> <name> <package file>...'
tree=${1:?$usage}; commit=${2:?$usage}; name=${3:?$usage}
shift 3
case $name in */* | . | .. | *[[:space:]]*) echo "refused: '$name' is not a package name" >&2; exit 1 ;; esac
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "refused: '$commit' is not a full 40-character commit: the real build's record names the commit itself" >&2; exit 1; }
declare -A seen=()
for f in "$@"; do
    case $f in
        *.rpm) ver=$(rpm -qp --qf '%{VERSION}\n' "$f") ;;
        *.deb) ver=$(dpkg-deb -f "$f" Version); ver=${ver#*:}
               case $ver in *-*) ver=${ver%-*} ;; esac ;;
        *) continue ;;
    esac
    [ -n "$ver" ] || { echo "refused: $f names no version" >&2; exit 1; }
    seen[$ver]=1
done
for ver in "${!seen[@]}"; do
    rec=$tree/built/$name/$ver.commit
    if [ -f "$rec" ]; then
        [ "$(cat "$rec")" = "$commit" ] || { echo "refused ${rec#"$tree"/}: it records the build of $(cat "$rec"), and this run is $commit: a version is built once" >&2; exit 1; }
        continue
    fi
    mkdir -p "$(dirname "$rec")"
    printf '%s\n' "$commit" > "$rec"
    echo "recorded ${rec#"$tree"/}: built by $commit"
done
