#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The testing channel carries the tested platforms alone (owner ruling 2026-11-23, .github#233,
# docs/release-operations.md "The staging channel of a release wave"): the quick set of quick.txt beside this file.
# publish-rpms and publish-debs run this on what a staged run is about to publish, before anything is placed.
#
#   staged-cells.sh check rpm|deb <dir>   refuses, naming the file, any package of a cell outside the quick set:
#                                         rpm  <name>-<version>-<release>.fcNN.<arch>.rpm: fcNN and <arch> a quick
#                                              cell, or noarch / src of a quick Fedora release;
#                                         deb  <dir>/<suite>/<name>_<version>_<arch>.deb: <suite> and <arch> a quick
#                                              cell, or all of a quick Debian release
#   staged-cells.sh arches deb            the quick set's Debian architectures, space separated (the staging skeleton)
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
usage='usage: staged-cells.sh check rpm|deb <dir> | arches deb'
cells() { # <kind>: "<release> <arch>" per quick cell
    awk -v k="$1" '$1 == k && NF == 3 {print $2, $3}' "$here/quick.txt"
}
in_set() { # <kind> <release> <arch>
    cells "$1" | grep -qxF -- "$2 $3"
}
release_in_set() { # <kind> <release>
    cells "$1" | awk '{print $1}' | grep -qxF -- "$2"
}

case ${1:-} in
arches)
    [ "${2:-}" = deb ] || { echo "$usage" >&2; exit 2; }
    cells deb | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//'
    echo
    ;;
check)
    kind=${2:-} dir=${3:-}
    case $kind in rpm | deb) ;; *) echo "$usage" >&2; exit 2 ;; esac
    [ -d "$dir" ] || { echo "staged-cells: no directory $dir" >&2; exit 2; }
    bad=()
    if [ "$kind" = rpm ]; then
        while IFS= read -r -d '' f; do
            b=$(basename "$f" .rpm)
            arch=${b##*.}
            if [[ $b =~ \.fc([0-9]+)\.[^.]+$ ]]; then rel=${BASH_REMATCH[1]}; else bad+=("$f (no .fcNN dist tag)"); continue; fi
            case $arch in
            noarch | src) release_in_set rpm "$rel" || bad+=("$f (fc$rel $arch)") ;;
            *) in_set rpm "$rel" "$arch" || bad+=("$f (fc$rel $arch)") ;;
            esac
        done < <(find "$dir" -name '*.rpm' -print0 | sort -z)
    else
        while IFS= read -r -d '' f; do
            suite=$(basename "$(dirname "$f")")
            arch=$(basename "$f" .deb); arch=${arch##*_}
            case $arch in
            all) release_in_set deb "$suite" || bad+=("$f ($suite $arch)") ;;
            *) in_set deb "$suite" "$arch" || bad+=("$f ($suite $arch)") ;;
            esac
        done < <(find "$dir" -name '*.deb' -print0 | sort -z)
    fi
    if [ "${#bad[@]}" -gt 0 ]; then
        echo "::error::a staged run publishes the tested platforms alone, the quick set ($(cells "$kind" | paste -sd, -)): refused ${bad[*]}" >&2
        exit 1
    fi
    echo "staged-cells: every $kind package of $dir is of a tested platform ($(cells "$kind" | paste -sd, -))"
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
