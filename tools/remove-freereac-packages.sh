#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Take FreeREAC's packages out of the OpenMixer channel, and nothing else (.github#224; owner ruling 2026-11-23: the
# OpenMixer and FreeREAC channels are independent, and this channel serves no FreeREAC package). They came from FreeREAC
# releases that named no target-repo and took the shared workflows' default, a republish workflow of this repository,
# and the freereac-release mirror; publish-rpms/channel-owner.sh now refuses all three at the source.
#
#   remove-freereac-packages.sh rpm|deb <channel checkout> [<gpg key id>]     no key id: unsigned metadata, a dry run
#
# FREEREAC_LISTING (required) is a file of the paths FreeREAC's channel serves (rpm/..., deb/...: `git ls-tree -r
# --name-only` of FreeREAC/freereac.github.io, as the workflow writes it).
#
# THE SOURCES ARE A CONSTANT, NOT AN ARGUMENT: freereac-release, libreac, reac-pw and reac-stageboxes, the FreeREAC
# repositories whose packages this channel holds. A candidate is a file under <channel>/<kind>/<dir>/ named like one of
# them (freereac-*, libreac*, reac-*); its own header must name one of those sources (rpm SOURCERPM, or NAME of a source
# rpm; deb Source, else Package) and FreeREAC as its home (rpm URL, deb Homepage: github.com/FreeREAC/ or
# freereac.github.io), else the run refuses before anything is removed.
#
# A GAP KEEPS THE FILE. A candidate is removed only when FreeREAC's channel serves the same package at the same version or
# newer for the same cell: rpm fedora/<release>/<arch>, SRPMS for a source rpm, and for a noarch package
# fedora/<release>/noarch or every architecture directory of the release this channel has; deb debian/<suite>/<arch>.
# Every kept candidate is printed as a gap, so a machine of this channel never loses a version it could install from it.
# A RETIRED FEDORA RELEASE IS NOT A GAP: an rpm candidate under fedora/<release>/ older than the development release (the rpm
# line of release-matrix/quick.txt, the one place it is written, as channel/gen-keep-list.mjs reads it) is removed whether
# FreeREAC serves it or not, and printed as retired (owner rulings 2026-11-19 and 2026-11-23: Fedora 44 is dropped, its
# FreeREAC source rpms are not moved).
# A deb changelog directory, changelogs/<prefix>/<source>, goes when no package of that source is left in deb/.
#
# The metadata is then made again and signed by the tree scripts of a publish (EMPTY_OK: nothing is added), with every
# guard of a publish, and the checkout is audited with git: every change must be inside <kind>/ and either a removed
# candidate, the changelog of a source that left, or metadata the tree scripts write; anything else refuses the run. A
# tree with nothing to remove is left exactly as it is (exit 0): a re-run, or channel-push's lost-race rebuild, changes
# nothing.
#
# CHANGELOGS_URL (deb) is the Changelogs field of the Release files, as publish-debs sets it; default
# https://www.openmixer.org/deb/changelogs.
set -euo pipefail
usage='usage: remove-freereac-packages.sh rpm|deb <channel checkout> [<gpg key id>]'
sources=(freereac-release libreac reac-pw reac-stageboxes)
kind=${1:?$usage}
channel=$(readlink -m "${2:?$usage}")
key=${3:-}
here=$(dirname "$(readlink -f "$0")")
actions=$here/../.github/actions
fail() { echo "FAIL: $*" >&2; exit 1; }
case $kind in rpm | deb) ;; *) fail "rpm or deb, not '$kind'" ;; esac
[ -d "$channel/$kind" ] || fail "no $kind tree at $channel/$kind"
[ -s "${FREEREAC_LISTING:-}" ] || fail "FREEREAC_LISTING names no file: what FreeREAC's channel serves must be known before anything is removed"
git -C "$channel" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$channel is not a git checkout: the change could not be audited"
[ -z "$(git -C "$channel" status --porcelain --untracked-files=all)" ] || fail "$channel has changes before the removal: $(git -C "$channel" status --short | head -5)"
tree=$channel/$kind
listing=$FREEREAC_LISTING
dev_fedora=$(sed 's/#.*//' "$here/../.github/actions/release-matrix/quick.txt" | awk '$1 == "rpm" && $2 ~ /^[0-9]+$/ && NF == 3 {print $2; exit}')
[ -n "$dev_fedora" ] || fail "release-matrix/quick.txt names no rpm cell: no development Fedora release to judge a retired one by"
is_source() { local s; for s in "${sources[@]}"; do [ "$1" = "$s" ] && return 0; done; return 1; }
freereac_home() { case ${1,,} in *github.com/freereac/* | *://freereac.github.io*) return 0 ;; esac; return 1; }
candidates() { find "$1" -mindepth 2 -type f \( -name 'freereac-*.rpm' -o -name 'libreac*.rpm' -o -name 'reac-*.rpm' \
    -o -name 'freereac-*.deb' -o -name 'libreac*.deb' -o -name 'reac-*.deb' \) | sort; }
newer_or_same() { # <theirs> <ours>
    if [ "$kind" = rpm ]; then [ "$(rpm --eval "%{lua: print(rpm.vercmp('$1', '$2'))}")" -ge 0 ]
    else dpkg --compare-versions "$1" ge "$2"; fi
}
covered() { # <dir as FreeREAC lays it out, under <kind>/> <name> <version>: FreeREAC serves name at version or newer there
    local f v
    while IFS= read -r f; do
        f=${f##*/}
        if [ "$kind" = rpm ]; then
            case $f in "$2"-*) ;; *) continue ;; esac
            v=${f#"$2"-}; v=${v%.*.rpm}
            [[ $v =~ ^[^-]+-[^-]+$ ]] || continue # a package whose name only starts with this one
        else
            case $f in "$2"_*) ;; *) continue ;; esac
            v=${f#"$2"_}; v=${v%_*.deb}
        fi
        newer_or_same "$v" "$3" && return 0
    done < <(grep -E "^$kind/$1/[^/]+\$" "$listing" || true)
    return 1
}
src_of() { # <file>: the source package name, from the header
    if [ "$kind" = rpm ]; then
        local issrc name srcrpm
        IFS='|' read -r issrc name srcrpm < <(rpm -qp --nosignature --qf '%{SOURCEPACKAGE}|%{NAME}|%{SOURCERPM}\n' "$1" 2>/dev/null)
        if [ "$issrc" = 1 ]; then echo "$name"; else echo "${srcrpm%-*-*.src.rpm}"; fi
    else
        local s; s=$(dpkg-deb -f "$1" Source 2>/dev/null || true); s=${s%% *}; echo "${s:-$(dpkg-deb -f "$1" Package)}"
    fi
}

# the candidates, proved by header; then the ones FreeREAC covers
gone=() gaps=()
declare -A gone_source=()
while IFS= read -r f; do
    rel=${f#"$channel"/}
    if [ "$kind" = rpm ]; then
        IFS='|' read -r name ver relv url < <(rpm -qp --nosignature --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{URL}\n' "$f" 2>/dev/null) ||
            fail "$rel is not a readable rpm"
        evr=$ver-$relv
    else
        name=$(dpkg-deb -f "$f" Package 2>/dev/null) || fail "$rel is not a readable deb"
        evr=$(dpkg-deb -f "$f" Version); url=$(dpkg-deb -f "$f" Homepage 2>/dev/null || true)
    fi
    src=$(src_of "$f")
    is_source "$src" || fail "$rel is named like a FreeREAC package but its source is '$src': nothing was removed"
    freereac_home "$url" || fail "$rel (source $src) does not name FreeREAC as its home ('$url'): nothing was removed"
    hit=
    if [ "$kind" = rpm ]; then
        r=$(cut -d/ -f3 <<< "$rel"); d=$(cut -d/ -f4 <<< "$rel")
        if [[ $r =~ ^[0-9]+$ ]] && [ "$r" -lt "$dev_fedora" ]; then
            hit=1; echo "retired $rel: Fedora $r is older than the development release $dev_fedora"
        elif covered "fedora/$r/$d" "$name" "$evr"; then hit=1
        elif [ "$d" = noarch ]; then
            # served to every architecture of the release: each architecture tree of FreeREAC's must carry it
            hit=1
            for a in x86_64 aarch64; do
                [ -d "$tree/fedora/$r/$a" ] || continue
                covered "fedora/$r/$a" "$name" "$evr" || { hit=; break; }
            done
        fi
    else
        covered "$(dirname "${rel#deb/}")" "$name" "$evr" && hit=1
    fi
    if [ -n "$hit" ]; then gone+=("$f"); gone_source[$src]=1
    else gaps+=("$rel: FreeREAC's channel serves no $name $evr or newer for this cell"); fi
done < <(candidates "$tree")

for g in ${gaps[@]+"${gaps[@]}"}; do echo "kept (gap) $g"; done
if [ "${#gone[@]}" = 0 ]; then
    echo "the $kind tree serves no FreeREAC package that FreeREAC's channel covers: nothing to remove, the tree is left as it is"
    exit 0
fi

for f in "${gone[@]}"; do rm -f -- "$f"; echo "removed ${f#"$channel"/}"; done
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
left_dirs=()
case $kind in
rpm)
    # the metadata is made from the bytes the tree holds, as channel-pull leaves it for a publish (strip: rpm)
    find "$tree" -type d -name repodata -prune -exec rm -rf {} +
    EMPTY_OK=true "$actions/publish-rpms/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
deb)
    # the changelog of a source goes with its last package
    declare -A still=()
    while IFS= read -r f; do still[$(src_of "$f")]=1; done < <(candidates "$tree/debian")
    for src in "${!gone_source[@]}"; do
        case $src in lib*) p=${src:0:4} ;; *) p=${src:0:1} ;; esac
        d=$tree/changelogs/$p/$src
        [ -d "$d" ] && [ -z "${still[$src]:-}" ] || continue
        rm -rf -- "$d"; left_dirs+=("${d#"$channel"/}"); echo "removed ${d#"$channel"/}"
    done
    CHANGELOGS_URL=${CHANGELOGS_URL-https://www.openmixer.org/deb/changelogs} EMPTY_OK=true \
        "$actions/publish-debs/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
esac
for f in "${gone[@]}"; do [ ! -e "$f" ] || fail "${f#"$channel"/} is still there"; done

# the audit: only the removed candidates, the changelogs of sources that left, and metadata changed
declare -A removed=()
for f in "${gone[@]}"; do removed[${f#"$channel"/}]=1; done
bad=0
while IFS= read -r -d '' entry; do
    st=${entry:0:2} path=${entry:3}
    case $path in
    "$kind"/*) ;;
    *) echo "refused: $path changed, outside $kind/" >&2; bad=1; continue ;;
    esac
    if [ "$st" = ' D' ]; then
        [ -z "${removed[$path]:-}" ] || continue
        hit=
        for d in ${left_dirs[@]+"${left_dirs[@]}"}; do case $path in "$d"/*) hit=1 ;; esac; done
        [ -z "$hit" ] || continue
    fi
    case ${path#"$kind"/} in
    repodata/* | */repodata/* | */Packages | */Packages.gz | */Release | */InRelease | */Release.gpg | cells.tsv | \
        RPM-GPG-KEY-openmixer | openmixer.asc | openmixer.repo) ;;
    # publish-debs writes the changelog of a served package that has none yet; a publish adds it, never rewrites one
    changelogs/*_changelog) [ "$kind" = deb ] && [ "$st" = '??' ] || { echo "refused: $path changed ($st): a served changelog is never rewritten" >&2; bad=1; } ;;
    *) echo "refused: $path changed ($st), and it is neither a removed FreeREAC package nor metadata" >&2; bad=1 ;;
    esac
done < <(git -C "$channel" status --porcelain=v1 -z --untracked-files=all)
[ "$bad" = 0 ] || fail "the removal changed more than FreeREAC's packages and their metadata: nothing may be pushed"
echo "removed FreeREAC's packages from $kind/: ${#gone[@]} file(s) removed, ${#gaps[@]} kept for a gap, metadata regenerated${key:+ and signed}"
