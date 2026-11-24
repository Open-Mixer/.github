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
#   staged-cells.sh arches deb [<dir>]    the staging skeleton's Debian architectures, space separated: the quick set's,
#                                         and with MATRIX_SET=full those of the arch-specific debs of <dir> too
#
# THE RUN'S SET (MATRIX_SET, which the publish step already has from matrix-set): empty or quick, the quick set above,
# the default. full, a staged promotion candidate that asked for the full matrix (.github#273, the owner's build-once
# ruling 2026-11-24): a package passes when its release is one the run built (RELEASES for rpm, SUITES for deb, space
# separated, the preflight's releases), any architecture of it; a release the run did not build is still refused by
# file and cell. Any other MATRIX_SET, or full with no releases named, is exit 2: a set that cannot be read never
# widens the check.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
usage='usage: staged-cells.sh check rpm|deb <dir> | arches deb [<dir>]'
cells() { # <kind>: "<release> <arch>" per quick cell
    awk -v k="$1" '$1 == k && NF == 3 {print $2, $3}' "$here/quick.txt"
}
run_set=${MATRIX_SET:-quick}
case $run_set in quick | full) ;; *) echo "staged-cells: MATRIX_SET is '$run_set', not quick or full" >&2; exit 2 ;; esac
run_releases() { # <kind>: the releases the run built, one per line
    if [ "$1" = rpm ]; then printf '%s\n' "${RELEASES:-}"; else printf '%s\n' "${SUITES:-}"; fi | tr -s ' ,' '\n' | sed '/^$/d'
}
in_set() { # <kind> <release> <arch>
    if [ "$run_set" = full ]; then run_releases "$1" | grep -qxF -- "$2"; else cells "$1" | grep -qxF -- "$2 $3"; fi
}
release_in_set() { # <kind> <release>
    if [ "$run_set" = full ]; then run_releases "$1" | grep -qxF -- "$2"; else cells "$1" | awk '{print $1}' | grep -qxF -- "$2"; fi
}

case ${1:-} in
arches)
    [ "${2:-}" = deb ] || { echo "$usage" >&2; exit 2; }
    {
        cells deb | awk '{print $2}'
        if [ "$run_set" = full ] && [ -n "${3:-}" ]; then
            find "$3" -name '*.deb' | sed 's/.*_//; s/\.deb$//' | grep -vx all || true
        fi
    } | sort -u | tr '\n' ' ' | sed 's/ $//'
    echo
    ;;
check)
    kind=${2:-} dir=${3:-}
    case $kind in rpm | deb) ;; *) echo "$usage" >&2; exit 2 ;; esac
    [ -d "$dir" ] || { echo "staged-cells: no directory $dir" >&2; exit 2; }
    [ "$run_set" = quick ] || [ -n "$(run_releases "$kind" | tr -d '\n')" ] || { echo "staged-cells: MATRIX_SET=full names no release the run built ($([ "$kind" = rpm ] && echo RELEASES || echo SUITES) is empty)" >&2; exit 2; }
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
            # only <dir>/<suite>/<package>.deb is judged here: any other layout is publish-tree.sh's to refuse, by name
            [ "$(dirname "$(dirname "$f")")" = "${dir%/}" ] || continue
            suite=$(basename "$(dirname "$f")")
            arch=$(basename "$f" .deb); arch=${arch##*_}
            case $arch in
            all) release_in_set deb "$suite" || bad+=("$f ($suite $arch)") ;;
            *) in_set deb "$suite" "$arch" || bad+=("$f ($suite $arch)") ;;
            esac
        done < <(find "$dir" -name '*.deb' -print0 | sort -z)
    fi
    if [ "$run_set" = full ]; then what="the full matrix it asked for, the releases it built ($(run_releases "$kind" | paste -sd, -))"; else what="the tested platforms, the quick set ($(cells "$kind" | paste -sd, -))"; fi
    if [ "${#bad[@]}" -gt 0 ]; then
        echo "::error::a staged run publishes $what alone: refused ${bad[*]}" >&2
        exit 1
    fi
    echo "staged-cells: every $kind package of $dir is of $what"
    ;;
*)
    echo "$usage" >&2
    exit 2
    ;;
esac
