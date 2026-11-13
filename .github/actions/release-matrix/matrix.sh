#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Say which cells of the release matrix a run builds: the quick set (quick.txt beside this file) or the full matrix
# of the caller. build-rpm.yml and build-deb.yml run it once, in their first job, and the build and the install
# check both take their matrix from what it prints, so the two never differ.
#
#   matrix.sh        reads the environment, writes set, source, cells, releases, first-arch and count to
#                    $GITHUB_OUTPUT (standard output without it)
#
#   KIND        rpm or deb
#   RELEASES    the caller's Fedora releases (rpm) or Debian releases (deb), a JSON array of strings
#   ARCHES      the caller's architectures, a JSON array of strings
#   MATRIX      the matrix input: quick, full, or empty (the caller said nothing)
#   WAVE        the organisation variable OMX_RELEASE_MATRIX: quick while a release wave is open, full or unset otherwise
#   STAGED      'true' on a staged run
#   EVENT       the event of the run (github.event_name)
#   REF_TYPE    'tag' on a tag (github.ref_type)
#   SOURCE_REF  the tag being released when the run is not on it (inputs.source-ref)
#
# Which set, first match:
#   1. MATRIX, when the caller passed it;
#   2. a release (a tag, or source-ref): WAVE, and FULL without it. A tag pushed by hand, with no wave open, never
#      publishes part of the matrix because nobody said otherwise;
#   3. a staged run or a workflow_dispatch: WAVE, and QUICK without it;
#   4. anything else (a pull request, a push to a branch): full, the dry run it always was.
# The quick set is the lines of quick.txt of this kind that the caller's matrix holds. When it holds none of them
# (a library built for x86_64 alone has no arm64 deb), the run builds the caller's full matrix and says so: a run
# never builds nothing.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
kind=${KIND:?KIND: rpm or deb}
case $kind in rpm) key=fedora ;; deb) key=suite ;; *) echo "::error::KIND is '$kind', not rpm or deb" >&2; exit 2 ;; esac

list() { # <name> <json array of plain strings>: one item per line
    local re='^\[[[:space:]]*"[A-Za-z0-9_.-]+"([[:space:]]*,[[:space:]]*"[A-Za-z0-9_.-]+")*[[:space:]]*\]$'
    [[ $2 =~ $re ]] || { echo "::error::$1 is not a JSON array of names: $2" >&2; exit 2; }
    printf '%s\n' "$2" | tr -d '[]" \t' | tr ',' '\n'
}
mapfile -t releases < <(list RELEASES "${RELEASES:?RELEASES}")
mapfile -t arches < <(list ARCHES "${ARCHES:?ARCHES}")

wave=${WAVE:-}
case $wave in quick | full | '') ;; *) echo "::error::OMX_RELEASE_MATRIX is '$wave', not quick or full" >&2; exit 2 ;; esac
case ${MATRIX:-} in
quick | full) set=$MATRIX source="the matrix input" ;;
'')
    if [ "${REF_TYPE:-}" = tag ] || [ -n "${SOURCE_REF:-}" ]; then
        set=${wave:-full} source="a release"
    elif [ "${STAGED:-}" = true ]; then
        set=${wave:-quick} source="a staged run"
    elif [ "${EVENT:-}" = workflow_dispatch ]; then
        set=${wave:-quick} source="a manual run"
    else
        set=full wave='' source="a dry run of ${EVENT:-an unnamed event}"
    fi
    [ -z "$wave" ] || source="$source, OMX_RELEASE_MATRIX=$wave"
    ;;
*) echo "::error::matrix is '$MATRIX', not quick or full" >&2; exit 2 ;;
esac

cells=()
if [ "$set" = quick ]; then
    while read -r k rel arch rest; do
        case $k in '' | '#'*) continue ;; esac
        [ -n "$arch" ] && [ -z "$rest" ] || { echo "::error::quick.txt: not '<kind> <release> <arch>': $k $rel $arch $rest" >&2; exit 2; }
        [ "$k" = "$kind" ] || continue
        printf '%s\n' "${releases[@]}" | grep -qxF -- "$rel" || continue
        printf '%s\n' "${arches[@]}" | grep -qxF -- "$arch" || continue
        cells+=("$rel $arch")
    done < "$here/quick.txt"
    if [ "${#cells[@]}" = 0 ]; then
        echo "::notice::the quick set has no $kind cell among ${releases[*]} x ${arches[*]}: this run builds the caller's full $kind matrix"
        set=full source="$source, no quick $kind cell in the caller's matrix"
    fi
fi
if [ "$set" = full ]; then
    for rel in "${releases[@]}"; do for arch in "${arches[@]}"; do cells+=("$rel $arch"); done; done
fi

json= built=() first=
for c in "${cells[@]}"; do
    rel=${c% *} arch=${c#* }
    json+="${json:+,}{\"$key\":\"$rel\",\"arch\":\"$arch\"}"
    printf '%s\n' ${built[@]+"${built[@]}"} | grep -qxF -- "$rel" || built+=("$rel")
done
# what ships once per release (the source package, the noarch packages) ships from one architecture: the first of
# the caller's that the set builds
for arch in "${arches[@]}"; do
    for c in "${cells[@]}"; do [ "${c#* }" = "$arch" ] && first=$arch && break 2; done
done
{
    echo "set=$set"
    echo "source=$source"
    echo "cells=[$json]"
    echo "releases=${built[*]}"
    echo "first-arch=$first"
    echo "count=${#cells[@]}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
shown=
for c in "${cells[@]}"; do
    if [ "$kind" = rpm ]; then shown+="${shown:+, }fc${c% *} ${c#* }"; else shown+="${shown:+, }${c% *} ${c#* }"; fi
done
echo "::notice::$kind matrix: $set ($source), ${#cells[@]} cell(s): $shown"
