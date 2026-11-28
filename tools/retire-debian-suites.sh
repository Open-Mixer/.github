#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Take every RETIRED Debian release out of one apt tree of the channel: its whole suite directory (packages and index)
# and the changelogs only its packages served. A release is retired when it is neither in the full matrix
# (.github/actions/release-matrix/full.txt, the only Debian releases built) nor frozen (release-matrix/frozen.txt, served
# and never built). The set is derived from those two files, never written here: owner ruling 2026-11-28, Debian is
# trixie only and the published bookworm packages leave every channel; a release that leaves the matrix later leaves the
# same way.
#
#   retire-debian-suites.sh <channel checkout> <tree>
#
# <tree> is an apt tree of the channel, relative to it: deb (the real channel), staging/deb, or devel/<wave>/deb.
#
# A Debian release is one flat repository, debian/<suite>/ with its own Packages, Release, InRelease and Release.gpg, and
# no index of another release names a path in it. So the suites that stay keep their index and its signature byte for
# byte (nothing is signed again, no key is needed), and each one's InRelease is checked to verify against the key file
# the tree serves (openmixer.asc) and to name the Packages beside it: a tree whose remaining index does not verify
# refuses the run before anything is removed. cells.tsv is written again (release-matrix/cells.sh) without the release.
#
# A changelog, changelogs/<prefix>/<source>/<source>_<version>_changelog (publish-tree.sh place_changelog), goes when a
# package of the retired release served that source version and no package of a release that stays does; every other
# changelog stays.
#
# The checkout is audited with git: every change must be a path of a retired suite, one of those changelogs, or
# <tree>/cells.tsv; anything else refuses the run. A tree with no retired release is left exactly as it is (exit 0): a
# re-run, or channel-push's lost-race rebuild, changes nothing. Every removed file is printed ("removed <path>").
#
# FULL_MATRIX and FROZEN name other lists (the tests); default the release-matrix files beside the tool.
set -euo pipefail
usage='usage: retire-debian-suites.sh <channel checkout> <deb | staging/deb | devel/<wave>/deb>'
channel=$(readlink -m "${1:?$usage}")
rel_tree=${2:?$usage}
here=$(dirname "$(readlink -f "$0")")
matrix=$here/../.github/actions/release-matrix
full=${FULL_MATRIX:-$matrix/full.txt}
frozen=${FROZEN:-$matrix/frozen.txt}
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ $rel_tree =~ ^(deb|staging/deb|devel/[a-z0-9-]+/deb)$ ]] || fail "the tree is deb, staging/deb or devel/<wave>/deb, not '$rel_tree'"
tree=$channel/$rel_tree
git -C "$channel" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$channel is not a git checkout: the change could not be audited"
[ -z "$(git -C "$channel" status --porcelain --untracked-files=all)" ] || fail "$channel has changes before the run: $(git -C "$channel" status --short | head -5)"
[ -f "$full" ] && [ -f "$frozen" ] || fail "no release-matrix lists at $full and $frozen"

# the Debian releases that stay: built (full.txt) or frozen; a list naming none would retire every suite
declare -A keep=()
while read -r k r _; do [ "$k" = deb ] && [[ $r =~ ^[a-z]+$ ]] && keep[$r]=1; done < <(sed 's/#.*//' "$full" "$frozen")
[ "${#keep[@]}" -gt 0 ] || fail "full.txt and frozen.txt name no Debian release: every suite would be retired, nothing was removed"

if [ ! -d "$tree/debian" ]; then
    echo "$rel_tree holds no debian/ directory: nothing to retire, the tree is left as it is"
    exit 0
fi
retired=() stay=()
for d in "$tree"/debian/*/; do
    [ -d "$d" ] || continue
    s=$(basename "$d")
    if [ -n "${keep[$s]:-}" ]; then stay+=("$s"); else retired+=("$s"); fi
done
if [ "${#retired[@]}" = 0 ]; then
    echo "$rel_tree serves no retired Debian release (kept: ${stay[*]:-none}): nothing to retire, the tree is left as it is"
    exit 0
fi

# every index that stays verifies against the key file the tree serves, and names the Packages beside it
keyfile=$tree/openmixer.asc
if [ "${#stay[@]}" -gt 0 ]; then
    [ -s "$keyfile" ] || fail "$rel_tree serves no openmixer.asc: the indexes that stay could not be verified, nothing was removed"
    keyring=$(mktemp)
    trap 'rm -f "$keyring"' EXIT
    gpg --batch --yes --dearmor < "$keyfile" > "$keyring" 2>/dev/null || fail "$rel_tree/openmixer.asc is not a key file"
    for s in "${stay[@]}"; do
        d=$tree/debian/$s
        rel=$(mktemp)
        gpgv --keyring "$keyring" --output "$rel" "$d/InRelease" >/dev/null 2>&1 ||
            { rm -f "$rel"; fail "$rel_tree/debian/$s/InRelease does not verify against $rel_tree/openmixer.asc: nothing was removed"; }
        want=$(awk '/^SHA256:/ {x = 1; next} /^[^ ]/ {x = 0} x && $3 == "Packages" {print $1}' "$rel")
        rm -f "$rel"
        [ -n "$want" ] && [ "$want" = "$(sha256sum < "$d/Packages" | cut -d' ' -f1)" ] ||
            fail "$rel_tree/debian/$s/Packages is not the one its InRelease names: nothing was removed"
        echo "kept $rel_tree/debian/$s: its InRelease verifies against $rel_tree/openmixer.asc"
    done
fi

# <source> <version> of a deb, as place_changelog names its changelog
srcver() {
    local f=$1 pkg ver sf source sv
    pkg=$(dpkg-deb -f "$f" Package) ver=$(dpkg-deb -f "$f" Version)
    sf=$(dpkg-deb -f "$f" Source 2>/dev/null || true)
    source=${sf%% *} source=${source:-$pkg}
    case $sf in *"("*")"*) sv=${sf#*(} sv=${sv%)*} ;; *) sv=$ver ;; esac
    echo "$source ${sv#*:}"
}
declare -A served=() orphan=()
for s in ${stay[@]+"${stay[@]}"}; do
    while IFS= read -r f; do served[$(srcver "$f")]=1; done < <(find "$tree/debian/$s" -name '*.deb' | sort)
done
for s in "${retired[@]}"; do
    while IFS= read -r f; do
        sv=$(srcver "$f")
        [ -n "${served[$sv]:-}" ] || orphan[$sv]=1
    done < <(find "$tree/debian/$s" -name '*.deb' | sort)
done

declare -A removed=()
for s in "${retired[@]}"; do
    n=$(find "$tree/debian/$s" -name '*.deb' | wc -l)
    while IFS= read -r f; do
        removed[${f#"$channel"/}]=1
        echo "removed ${f#"$channel"/}"
    done < <(find "$tree/debian/$s" -type f | LC_ALL=C sort)
    rm -rf -- "$tree/debian/$s"
    echo "retired $rel_tree/debian/$s: $n package(s) and its index removed (not in full.txt nor frozen.txt)"
done
for sv in "${!orphan[@]}"; do
    source=${sv% *} v=${sv#* }
    case $source in lib*) p=${source:0:4} ;; *) p=${source:0:1} ;; esac
    f=$tree/changelogs/$p/$source/${source}_${v}_changelog
    [ -f "$f" ] || continue
    rm -f -- "$f"
    rmdir -- "$tree/changelogs/$p/$source" 2>/dev/null || true
    rmdir -- "$tree/changelogs/$p" 2>/dev/null || true
    removed[${f#"$channel"/}]=1
    echo "removed ${f#"$channel"/}"
done
"$matrix/cells.sh" deb "$tree"

# the audit: only the retired suites, their orphaned changelogs and cells.tsv changed
bad=0
while IFS= read -r -d '' entry; do
    st=${entry:0:2} path=${entry:3}
    if [ "$st" = ' D' ] && [ -n "${removed[$path]:-}" ]; then continue; fi
    if [ "$st" = ' M' ] && [ "$path" = "$rel_tree/cells.tsv" ]; then continue; fi
    echo "refused: $path changed ($st), and it is neither a file of a retired suite, nor its changelog, nor cells.tsv" >&2
    bad=1
done < <(git -C "$channel" status --porcelain=v1 -z --untracked-files=all)
[ "$bad" = 0 ] || fail "the run changed more than the retired suites: nothing may be pushed"
for s in "${retired[@]}"; do [ ! -e "$tree/debian/$s" ] || fail "$rel_tree/debian/$s is still there"; done
echo "retired from $rel_tree: ${retired[*]} (${#removed[@]} file(s) removed); kept ${stay[*]:-none}, their indexes untouched"
