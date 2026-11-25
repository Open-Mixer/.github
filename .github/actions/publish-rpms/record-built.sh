#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# record-built.sh <tree> <commit> <package file>...
#
# A merge to devel stages the REAL package, whose name holds no commit (.github#289). This records which commit built it:
# <tree>/built/<source name>/<version>.commit holds the full commit, one line, for every source and version among the
# packages (rpm: the name of %{SOURCERPM} and %{VERSION}; deb: the Source field, else Package, and the Version without
# epoch or revision). promote-staged reads it and promotes the real build only from that commit or a descendant carrying
# the same version. publish-tree.sh of publish-rpms and publish-debs runs it with BUILT_COMMIT set. A record that names
# another commit is refused, naming it: a version is built once.
set -euo pipefail
tree=${1:?usage: record-built.sh <tree> <commit> <package file>...}
commit=${2:?usage: record-built.sh <tree> <commit> <package file>...}
shift 2
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "refused: '$commit' is not a full 40-character commit: the real build's record names the commit itself" >&2; exit 1; }
declare -A seen=()
for f in "$@"; do
    case $f in
        *.rpm)
            IFS='|' read -r is_src name ver srpm < <(rpm -qp --qf '%{SOURCEPACKAGE}|%{NAME}|%{VERSION}|%{SOURCERPM}\n' "$f")
            # a binary package names its source package file, <name>-<version>-<release>.src.rpm
            [ "$is_src" = 1 ] || name=${srpm%-*-*} ;;
        *.deb)
            name=$(dpkg-deb -f "$f" Source 2>/dev/null || true); name=${name%% *}
            [ -n "$name" ] || name=$(dpkg-deb -f "$f" Package)
            ver=$(dpkg-deb -f "$f" Version); ver=${ver#*:}
            case $ver in *-*) ver=${ver%-*} ;; esac ;;
        *) continue ;;
    esac
    [ -n "$name" ] && [ -n "$ver" ] || { echo "refused: $f names no source or version" >&2; exit 1; }
    seen[$name/$ver]=1
done
for nv in "${!seen[@]}"; do
    rec=$tree/built/$nv.commit
    if [ -f "$rec" ]; then
        [ "$(cat "$rec")" = "$commit" ] || { echo "refused ${rec#"$tree"/}: it records the build of $(cat "$rec"), and this run is $commit: a version is built once" >&2; exit 1; }
        continue
    fi
    mkdir -p "$(dirname "$rec")"
    printf '%s\n' "$commit" > "$rec"
    echo "recorded ${rec#"$tree"/}: built by $commit"
done
