#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Write <tree>/cells.tsv: for every package and version a channel tree holds, the cells it was published for and
# whether that was the quick set or the full matrix. The channel page reads it to show which cells a version has,
# and a final release reads it to refuse a dependency published for the quick set alone (quick-deps.sh).
#
#   cells.sh rpm|deb <tree> [<package dir>]
#
# One line per package and version, tab separated, sorted:
#   <package>  <version>  <set>  <cells, space separated>
# A cell is fc<release>/<arch> (rpm) or <Debian release>/<arch> (deb), the directory the file lies in, so noarch and
# all are cells too; source packages are left out. The version is the upstream version: the Release of an rpm and
# the revision or +git / ~git suffix of a deb are not part of it, so a staged build and its release share a line
# only when they share a tree, which they never do.
#
# The cells are read from the tree each time, by file name: the file is never the only record of what is there.
# The set is the one thing the tree cannot say. MATRIX_SET (quick or full) is the set of the run that publishes
# <package dir>, and every package and version found there takes it; every other line keeps the set it had, and a
# version published before sets were recorded has '-'. Without MATRIX_SET nothing is claimed for this run either.
#
# Not signed: nothing installs from it. It is written by the tree scripts, with the index, and committed with it.
set -euo pipefail
kind=${1:?usage: cells.sh rpm|deb <tree> [<package dir>]}
tree=${2:?usage: cells.sh rpm|deb <tree> [<package dir>]}
src=${3:-}
set=${MATRIX_SET:-}
case $kind in rpm) top=fedora ext=rpm ;; deb) top=debian ext=deb ;; *) echo "cells.sh: rpm or deb, not '$kind'" >&2; exit 2 ;; esac
case $set in quick | full | '') ;; *) echo "cells.sh: MATRIX_SET is '$set', not quick or full" >&2; exit 2 ;; esac
[ -d "$tree" ] || { echo "cells.sh: no tree at $tree" >&2; exit 1; }
out=$tree/cells.tsv

name_version() { # <file>: prints "<package> <upstream version>", or nothing for a source package or a foreign name
    local b n v
    b=$(basename "$1" ".$ext")
    if [ "$kind" = rpm ]; then
        case $b in *.src) return 0 ;; esac
        b=${b%.*}                       # the architecture
        [[ $b == *-*-* ]] || return 0
        b=${b%-*}                       # the Release
        n=${b%-*} v=${b##*-}
    else
        [[ $b == *_*_* ]] || return 0
        n=${b%%_*} v=${b#*_}
        v=${v%_*}                       # the architecture
        v=${v#*%3a} v=${v%%[+~]git*} v=${v%-*}
    fi
    printf '%s %s\n' "$n" "$v"
}

declare -A was=() now=() cells=()
if [ -f "$out" ]; then
    while IFS=$'\t' read -r n v s _; do
        case $n in '' | '#'*) continue ;; esac
        was[$n $v]=$s
    done < "$out"
fi
if [ -n "$src" ] && [ -n "$set" ]; then
    while IFS= read -r f; do
        nv=$(name_version "$f")
        [ -z "$nv" ] || now[$nv]=$set
    done < <(find "$src" -type f -name "*.$ext" | sort)
fi
if [ -d "$tree/$top" ]; then
    while IFS= read -r f; do
        nv=$(name_version "$f")
        [ -n "$nv" ] || continue
        d=${f#"$tree/$top/"}            # <release>/<arch>/<file>
        rel=${d%%/*} arch=${d#*/} arch=${arch%%/*}
        [ "$kind" = deb ] || rel=fc$rel
        case " ${cells[$nv]:-} " in *" $rel/$arch "*) ;; *) cells[$nv]="${cells[$nv]:+${cells[$nv]} }$rel/$arch" ;; esac
    done < <(find "$tree/$top" -mindepth 3 -maxdepth 3 -type f -name "*.$ext" | LC_ALL=C sort)
fi
{
    printf '# package\tversion\tset\tcells\n'
    for nv in "${!cells[@]}"; do
        printf '%s\t%s\t%s\t%s\n' "${nv% *}" "${nv#* }" "${now[$nv]:-${was[$nv]:--}}" "${cells[$nv]}"
    done | LC_ALL=C sort
} > "$out.new"
mv "$out.new" "$out"
echo "cells.tsv of ${tree##*/}: $(($(wc -l < "$out") - 1)) package version(s)${set:+, $set for the ones of this run}"
