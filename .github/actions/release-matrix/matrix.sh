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
#   REF_NAME    the tag of the run when it runs on one (github.ref_name)
#   CATCH_UP    'true': build only the cells of the set that a version the channel serves lacks (below)
#   CELLS_TSV   with CATCH_UP, the channel's cells.tsv of this kind (cells.sh), a file; unset, it is read from CHANNEL
#   CHANNEL     with CATCH_UP and no CELLS_TSV, the channel repository whose <kind>/cells.tsv is read, through the API
#               rather than the Pages site, which lags a push
#   TOKEN       a token that reads CHANNEL (PAGES_TOKEN)
#   NAMES       with CATCH_UP, the binary package names the release builds, space separated (globs allowed)
#
# Which set, first match:
#   1. MATRIX, when the caller passed it (on a staged run too: see below);
#   2. a release (a tag, or source-ref): WAVE, and FULL without it. A tag pushed by hand, with no wave open, never
#      publishes part of the matrix because nobody said otherwise;
#   3. a staged run or a workflow_dispatch: WAVE, and FULL without it;
#   4. anything else (a pull request, a push to a branch): full, the dry run it always was.
# A STAGED RUN, and a dispatch, build the FULL matrix by default: every package in every cell, rpm fc45 x86_64 and
# aarch64, deb trixie amd64 and arm64 (owner ruling 2026-11-26, which supersedes the quick staging of 2026-11-23,
# .github#233, and the x86_64-rpm/arm64-deb development matrix of 2026-11-19). A caller that passed no matrix used to
# stage the quick set alone, and every amd64 consumer of the next layer then failed to install, one layer at a time
# (plugin-hostd#326 fixed one caller). Only WAVE=quick, or an explicit MATRIX=quick, narrows a staged run to the quick
# set; then a caller whose matrix holds no quick cell is refused rather than given its full matrix.
# The quick set is the lines of quick.txt of this kind that the caller's matrix holds. When it holds none of them
# (a library built for x86_64 alone has no arm64 deb), the run builds the caller's full matrix and says so: a run
# never builds nothing.
#
# A CATCH-UP (CATCH_UP=true) fills the cells a served version lacks, for instance a cell that joined the quick set
# after the version was tagged. The version is the tag's (SOURCE_REF, or the tag of the run); the cells are the set's
# cells, chosen as above, minus the ones CELLS_TSV already records for that version. A cell counts as served for a
# package when the package's line records it. A package whose line records only arch-independent cells (all, noarch)
# in that release serves every cell of the release and is not judged there: the publish drops its rebuilt files.
# Every other package of NAMES is judged:
#   - served by none of them: the cell is built;
#   - served by all of them (or every package is arch-independent there): the cell is left out, and the run says so;
#   - served by some and not others: refused, naming the cell and the packages. A catch-up never rewrites a
#     served file, and that cell cannot be filled without doing so.
# Refused by name too: a version the channel does not serve at all (a release, not a catch-up), a package of NAMES
# the version has no line for, and a tag that names no version. Nothing missing is not an error: the cells are [],
# count is 0, the run builds nothing and says so. Only cells of the set are ever planned: the plan is the set
# minus what is served, never a cell the set does not hold.
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
# A Debian release outside the full matrix is refused by name, never built: Debian is trixie only (owner ruling
# 2026-11-28), and full.txt is the one place the Debian releases are written. A caller passing a retired release in
# its suite-matrix or deb-releases is red here, in the first job of build-deb.yml.
if [ "$kind" = deb ]; then
    for rel in "${releases[@]}"; do
        awk -v r="$rel" '$1 == "deb" && $2 == r { f = 1 } END { exit !f }' "$here/full.txt" || {
            echo "::error::Debian release '$rel' is not in the full matrix (release-matrix/full.txt: $(awk '$1 == "deb" { print $2 }' "$here/full.txt" | sort -u | xargs), the only Debian releases built: owner ruling 2026-11-28)" >&2
            exit 2
        }
    done
fi

wave=${WAVE:-}
case $wave in quick | full | '') ;; *) echo "::error::OMX_RELEASE_MATRIX is '$wave', not quick or full" >&2; exit 2 ;; esac
staged=${STAGED:-}
case ${MATRIX:-} in
quick | full)
    set=$MATRIX source="the matrix input"
    [ "$staged:$set" != true:full ] || source="$source, a staged promotion candidate (every cell)"
    ;;
'')
    if [ "${REF_TYPE:-}" = tag ] || [ -n "${SOURCE_REF:-}" ]; then
        set=${wave:-full} source="a release"
    elif [ "$staged" = true ]; then
        # the full matrix unless the wave says quick (owner ruling 2026-11-26: every package in every cell)
        set=${wave:-full} source="a staged run"
    elif [ "${EVENT:-}" = workflow_dispatch ]; then
        set=${wave:-full} source="a manual run"
    else
        set=full wave='' source="a dry run of ${EVENT:-an unnamed event}"
    fi
    [ -z "$wave" ] || source="$source, OMX_RELEASE_MATRIX=$wave"
    ;;
*) echo "::error::matrix is '$MATRIX', not quick or full" >&2; exit 2 ;;
esac

cells=()
if [ "$set" = quick ]; then
    # the quick (development) set wins: a caller's architecture list only narrows WITHIN the set. When it leaves
    # no cell (an amd64-only caller while the set is trixie arm64), the run builds the set's own cell for the
    # caller's releases, never the caller's full matrix. Only when the set has no cell of this kind and these
    # releases does the run build the caller's full matrix.
    inset=()
    while read -r k rel arch rest; do
        case $k in '' | '#'*) continue ;; esac
        [ -n "$arch" ] && [ -z "$rest" ] || { echo "::error::quick.txt: not '<kind> <release> <arch>': $k $rel $arch $rest" >&2; exit 2; }
        [ "$k" = "$kind" ] || continue
        printf '%s\n' "${releases[@]}" | grep -qxF -- "$rel" || continue
        inset+=("$rel $arch")
        printf '%s\n' "${arches[@]}" | grep -qxF -- "$arch" || continue
        cells+=("$rel $arch")
    done < "$here/quick.txt"
    if [ "${#cells[@]}" = 0 ] && [ "${#inset[@]}" -gt 0 ]; then
        cells=("${inset[@]}")
        echo "::notice::the quick set's $kind cell is outside the caller's architectures (${arches[*]}): this run builds the set's own cell, ${inset[*]}"
        source="$source, the set's cell outside the caller's architectures"
    fi
    if [ "${#cells[@]}" = 0 ] && [ "$staged" = true ]; then
        echo "::error::the caller's $kind matrix (${releases[*]}) holds no tested platform of quick.txt: a staged run builds the tested platforms alone (owner ruling 2026-11-23), never the caller's full matrix" >&2
        exit 2
    fi
    if [ "${#cells[@]}" = 0 ]; then
        echo "::notice::the quick set has no $kind cell among ${releases[*]}: this run builds the caller's full $kind matrix"
        set=full source="$source, no quick $kind cell in the caller's matrix"
    fi
fi
if [ "$set" = full ]; then
    for rel in "${releases[@]}"; do for arch in "${arches[@]}"; do cells+=("$rel $arch"); done; done
fi

# what the quick set left out of the caller's matrix, for the notice: a run says what it skipped
left=
if [ "$set" = quick ]; then
    for rel in "${releases[@]}"; do for arch in "${arches[@]}"; do
        printf '%s\n' "${cells[@]}" | grep -qxF -- "$rel $arch" && continue
        if [ "$kind" = rpm ]; then left+="${left:+, }fc$rel $arch"; else left+="${left:+, }$rel $arch"; fi
    done; done
fi

if [ "${CATCH_UP:-}" = true ]; then
    no() { echo "::error::catch-up: $*" >&2; exit 1; }
    [ "${STAGED:-}" != true ] || no "a staged run is not a catch-up: a catch-up fills a released version's cells in the real channel"
    tag=${SOURCE_REF:-}
    [ -n "$tag" ] || { [ "${REF_TYPE:-}" = tag ] && tag=${REF_NAME:-}; }
    [ -n "$tag" ] || no "needs the tag of a served version (source-ref, or a run on the tag)"
    ver=${tag#v}
    [ "$ver" != "$tag" ] && [ -n "$ver" ] || no "'$tag' is not v<version>"
    if [ -z "${CELLS_TSV:-}" ]; then
        [ -n "${CHANNEL:-}" ] && [ -n "${TOKEN:-}" ] || no "no cells.tsv given, and no channel and token to read it from"
        CELLS_TSV=$(mktemp)
        code=$(curl -sS --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o "$CELLS_TSV" -w '%{http_code}' \
            -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/$CHANNEL/contents/$kind/cells.tsv") || no "could not read $kind/cells.tsv of $CHANNEL"
        [ "$code" = 200 ] || no "$kind/cells.tsv of $CHANNEL answered HTTP $code"
    fi
    [ -f "${CELLS_TSV:-}" ] || no "no cells.tsv of the channel at '${CELLS_TSV:-}'"
    head -1 "$CELLS_TSV" | grep -q $'^# package\tversion\tset\tcells$' || no "${CELLS_TSV} is not a cells.tsv (its first line is not the header)"
    read -ra names <<< "${NAMES:-}"
    [ "${#names[@]}" -gt 0 ] || no "NAMES lists no package"
    declare -A rec=()
    while IFS=$'\t' read -r n v _ c; do
        case $n in '' | '#'*) continue ;; esac
        [ "$v" = "$ver" ] || continue
        for name in "${names[@]}"; do
            # shellcheck disable=SC2254 # name is a glob on purpose
            case $n in $name) rec[$n]=$c; break ;; esac
        done
    done < "$CELLS_TSV"
    [ "${#rec[@]}" -gt 0 ] || no "the channel serves no ${names[*]} $ver at all: that is a release, not a catch-up"
    for name in "${names[@]}"; do
        hit=
        for n in "${!rec[@]}"; do
            # shellcheck disable=SC2254 # name is a glob on purpose
            case $n in $name) hit=1; break ;; esac
        done
        [ -n "$hit" ] || no "the channel serves $ver of ${!rec[*]} but no $name $ver: a package of the release is missing everywhere, that is a release, not a catch-up"
    done
    indep_only() { # <release> <cells...>: true when the cells of that release are all arch-independent (all, noarch)
        local r=$1 w indep=
        shift
        for w in "$@"; do
            case $w in "$r"/all | "$r"/noarch) indep=1 ;; "$r"/*) return 1 ;; esac
        done
        [ -n "$indep" ]
    }
    keep=()
    for c in "${cells[@]}"; do
        rel=${c% *} arch=${c#* }
        if [ "$kind" = rpm ]; then cell=fc$rel; else cell=$rel; fi
        has=() lacks=()
        for n in $(printf '%s\n' "${!rec[@]}" | LC_ALL=C sort); do
            line=" ${rec[$n]} "
            if [[ $line == *" $cell/$arch "* ]]; then
                has+=("$n")
            elif indep_only "$cell" ${rec[$n]}; then
                : # arch-independent here: served for the whole release, and its files are never rewritten (the publish drops them)
            else
                lacks+=("$n")
            fi
        done
        if [ "${#lacks[@]}" = 0 ]; then
            echo "::notice::catch-up: $cell/$arch already serves ${names[*]} $ver: not built"
        elif [ "${#has[@]}" = 0 ]; then
            keep+=("$c")
        else
            no "$cell/$arch serves ${has[*]} $ver but not ${lacks[*]}: filling it would rewrite served files"
        fi
    done
    cells=(${keep[@]+"${keep[@]}"})
    source="$source, catch-up of $tag"
    [ "${#cells[@]}" -gt 0 ] || echo "::notice::catch-up: the channel serves $tag in every $set cell: nothing is missing, this run builds nothing"
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
echo "::notice::$kind matrix: $set ($source), ${#cells[@]} cell(s): $shown${left:+ (skipped while quick: $left)}"
