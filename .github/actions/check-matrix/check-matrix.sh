#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The cells a check runs while a release wave is open (ruling D25, Open-Mixer/.github#59): a full-stack or install check,
# or an ordinary CI matrix, covers the cells the release set builds and no others. A cell the set does not build is
# skipped by reading the organisation variable OMX_RELEASE_MATRIX, never deleted from the caller's matrix, and comes
# back when the variable is full.
#
#   check-matrix.sh      reads the environment, writes set, rpm, rpm-count, deb, deb-count, cells, count and images to
#                        $GITHUB_OUTPUT (standard output without it)
#
#   WAVE          the organisation variable OMX_RELEASE_MATRIX: quick, full, or empty
#   MATRIX        the caller's matrix input: quick, full, or empty (the variable decides)
#   RPM_RELEASES  the caller's whole check matrix of Fedora releases, a JSON array; empty when it checks no rpm
#   RPM_ARCHES    its architectures, a JSON array
#   DEB_RELEASES  the caller's whole check matrix of Debian releases, a JSON array; empty when it checks no deb
#   DEB_ARCHES    its architectures, a JSON array
#   ARM_ARCHES    the architectures of a cell that runs on ARM_RUNNER, space separated; every other cell runs on X86_RUNNER
#   ARM_RUNNER    the runner label of those cells
#   X86_RUNNER    the runner label of the rest: a caller with its own pool passes its OMX_RUNNER expression
#                 (the action.yml inputs arm-arches, arm-runner and x86-runner carry the defaults; no arch is written here)
#
# The set is MATRIX, else WAVE, else full. The cells are what release-matrix's matrix.sh says for that set: the quick set
# is quick.txt beside it, cut down to the caller's matrix, and that file stays the only place it is written. One
# difference: matrix.sh builds the caller's full matrix when the quick set holds none of its cells (a run never builds
# nothing); a check renders no cell then, because a check never runs a cell the set does not build. The caller skips the
# job on a count of 0.
#
# Each cell is matrix.sh's row with the container image and the runner added: {"fedora": "45", "arch": "x86_64",
# "image": "fedora:45", "runner": "ubuntu-latest"} or {"suite": "trixie", "arch": "arm64", "image": "debian:trixie",
# "runner": "ubuntu-24.04-arm"}. The runner is the one of the cell's own architecture (the arm-arches, arm-runner and
# x86-runner inputs name the ARM architectures and the two labels): a container of one architecture cannot install the packages of another (apt resolves libomxdsp-dev arm64 and dpkg refuses it in an amd64 container,
# omx-panel ci 44563540081), and the channel's development debs are trixie arm64 only. A caller writes
# runs-on: ${{ matrix.cell.runner }} instead of choosing the runner by hand. images is the images of every cell, each
# once, in order: the matrix of a CI job that runs on the runner's own architecture.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
matrix_sh=$here/../release-matrix/matrix.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# the digest of every cell image, declared once (images.txt, .github#248)
declare -A digest=()
while read -r img d _; do
    [ -n "$img" ] && [ "${img#\#}" = "$img" ] || continue
    [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::images.txt: $img has '$d', not sha256:<64 hex>" >&2; exit 2; }
    digest[$img]=$d
done < "$here/images.txt"

for r in "${ARM_RUNNER:?}" "${X86_RUNNER:?}"; do
    [[ $r =~ ^[A-Za-z0-9._-]+$ ]] || { echo "::error::runner '$r' is not a runner label" >&2; exit 2; }
done
: "${ARM_ARCHES:?the architectures that run on ARM_RUNNER}"
wave=${WAVE:-}
case $wave in quick | full | '') ;; *) echo "::error::OMX_RELEASE_MATRIX is '$wave', not quick or full" >&2; exit 2 ;; esac
case ${MATRIX:-} in
quick | full) set=$MATRIX source="the matrix input" ;;
'') set=${wave:-full} source="OMX_RELEASE_MATRIX=${wave:-unset}" ;;
*) echo "::error::matrix is '$MATRIX', not quick or full" >&2; exit 2 ;;
esac

ask() { # <kind> <releases> <arches> <set>: the key=value lines matrix.sh writes
    : > "$tmp/out"
    KIND=$1 RELEASES=$2 ARCHES=$3 MATRIX=$4 WAVE='' STAGED='' SOURCE_REF='' CATCH_UP='' EVENT='' REF_TYPE='' \
        GITHUB_OUTPUT=$tmp/out "$matrix_sh" > /dev/null
    cat "$tmp/out"
}
field() { sed -n "s/^$1=//p" <<< "$2"; }
with_image() { # matrix.sh's cells with the container image of each
    sed -E 's/\{"fedora":"([^"]+)","arch":"([^"]+)"\}/{"fedora":"\1","arch":"\2","image":"fedora:\1"}/g;
            s/\{"suite":"([^"]+)","arch":"([^"]+)"\}/{"suite":"\1","arch":"\2","image":"debian:\1"}/g' <<< "$1"
}
with_runner() { # the cells with a runner each: ARM_RUNNER for a cell of an ARM_ARCHES architecture, X86_RUNNER for the rest
    local cells=$1 a
    for a in $ARM_ARCHES; do
        cells=$(sed -E "s/\"arch\":\"$a\"(,\"image\":\"[^\"]+\")\}/\"arch\":\"$a\"\1,\"arm\":1}/g" <<< "$cells")
    done
    sed -E "s/(\"image\":\"[^\"]+\")\}/\1,\"runner\":\"$X86_RUNNER\"}/g; s/(\"image\":\"[^\"]+\"),\"arm\":1\}/\1,\"runner\":\"$ARM_RUNNER\"}/g" <<< "$cells"
}
pinned() { # the cells with each image as <image>@<digest>; an image images.txt has no digest for is refused
    local cells=$1 img
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        [ -n "${digest[$img]:-}" ] || { echo "::error::the cell image $img has no digest in check-matrix/images.txt: add its line" >&2; exit 2; }
        cells=${cells//\"image\":\"$img\"/\"image\":\"$img@${digest[$img]}\"}
    done < <(grep -oE '"image":"[^"@]+"' <<< "$cells" | sed 's/^"image":"//; s/"$//' | sort -u)
    printf '%s' "$cells"
}
shown() { # <kind> <cells json>: the cells as a notice shows them, fc<release> <arch> or <suite> <arch>
    grep -oE '"(fedora|suite)":"[^"]+","arch":"[^"]+"' <<< "$2" |
        sed -E 's/"fedora":"([^"]+)","arch":"([^"]+)"/fc\1 \2/; s/"suite":"([^"]+)","arch":"([^"]+)"/\1 \2/' | paste -sd, - | sed 's/,/, /g' || true
}

declare -A json=() count=()
all='' n=0 notice=''
for kind in rpm deb; do
    if [ "$kind" = rpm ]; then rels=${RPM_RELEASES:-} arches=${RPM_ARCHES:-}; else rels=${DEB_RELEASES:-} arches=${DEB_ARCHES:-}; fi
    json[$kind]='[]' count[$kind]=0
    if [ -z "$rels" ] || [ "$rels" = '[]' ]; then continue; fi
    [ -n "$arches" ] && [ "$arches" != '[]' ] || { echo "::error::$kind releases $rels have no architectures" >&2; exit 2; }
    whole=$(ask "$kind" "$rels" "$arches" full)
    if [ "$set" = quick ]; then
        got=$(ask "$kind" "$rels" "$arches" quick)
        # the quick set holds none of the caller's cells: matrix.sh fell back to the full matrix, a check runs nothing
        [ "$(field set "$got")" = quick ] || got=$'cells=[]\ncount=0'
    else
        got=$whole
    fi
    json[$kind]=$(pinned "$(with_runner "$(with_image "$(field cells "$got")")")")
    count[$kind]=$(field count "$got")
    n=$((n + count[$kind]))
    inner=${json[$kind]#[} inner=${inner%]}
    [ -z "$inner" ] || all+="${all:+,}$inner"
    left=()
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        grep -qF -- "$c" <<< "${json[$kind]}" || left+=("$(shown "$kind" "{$c}")")
    done < <(grep -oE '"(fedora|suite)":"[^"]+","arch":"[^"]+"' <<< "$(field cells "$whole")")
    notice+="; $kind: ${count[$kind]} cell(s)"
    [ "${count[$kind]}" = 0 ] || notice+=": $(shown "$kind" "${json[$kind]}")"
    [ "${#left[@]}" = 0 ] || notice+=" (skipped while quick: ${left[*]})"
done
images=$(grep -oE '"image":"[^"]+"' <<< "[$all]" | sed 's/^"image"://' | awk '!seen[$0]++' | paste -sd, - || true)
{
    echo "set=$set"
    echo "rpm=${json[rpm]}"
    echo "rpm-count=${count[rpm]}"
    echo "deb=${json[deb]}"
    echo "deb-count=${count[deb]}"
    echo "cells=[$all]"
    echo "count=$n"
    echo "images=[$images]"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
echo "::notice::check matrix: $set ($source)$notice"
