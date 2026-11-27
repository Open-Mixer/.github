#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Promote a DONE wave's devel channel into staging, the same bytes (docs/release-operations.md, "The three channel
# levels"): every package and build record of devel/<wave>/<kind> is copied to the same path under staging/<kind>,
# staging's cells.tsv takes the wave's rows, and staging's metadata is regenerated and signed by the publish's own tree
# script. Nothing is rebuilt and no package is signed again. Only <channel>/staging/<kind> is written: the wave's tree,
# the channel root and every other tree stay as they are.
#
#   promote-wave.sh rpm|deb <channel> <wave> [<gpg key id>]     no key id: unsigned metadata, for inspection only
#
# REFUSED, naming every file, before anything is copied: a path staging already holds with other bytes (a promoted file
# never replaces a published one; the same bytes at the same path are kept, so a promotion that ran is run again
# safely), and a wave name that is not [a-z0-9-]+. A wave whose tree of this kind is absent or holds no package promotes
# nothing of it and says so (exit 0). With a key, the wave's own tree
# is first vouched for by the tree script on a scratch copy (an rpm by its signature, a deb by its tree's signed
# index): a file someone left in a devel tree is never carried into staging's signed index.
# After the copy every promoted file is compared with its source, byte for byte.
#
# The environment: SKELETON (Fedora or Debian releases whose staging index must exist), SKELETON_ARCHES (deb),
# CHANGELOGS_URL (deb: where staging's changelogs/ is served), as publish-rpms and publish-debs set them for staging.
set -euo pipefail
usage='usage: promote-wave.sh rpm|deb <channel> <wave> [<gpg key id>]'
kind=${1:?$usage}
channel=$(readlink -m "${2:?$usage}")
wave=${3:?$usage}
key=${4:-}
here=$(dirname "$(readlink -f "$0")")
die() { echo "promote-wave: $*" >&2; exit 1; }
case $kind in rpm | deb) ;; *) die "rpm or deb, not '$kind'" ;; esac
[ -d "$channel" ] || die "no channel at $channel"
rel=$("$here/../publish-rpms/channel-level.sh" tree "$kind" "devel/$wave") || exit 1
src=$channel/$rel
dst=$channel/staging/$kind
# a wave that published nothing of this kind (a devel matrix of rpm cells alone builds no deb) promotes nothing of it
[ -d "$src" ] || { echo "promote-wave: the channel has no $rel: the wave published nothing of this kind, nothing to promote"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/empty"

# what moves: the packages and the build records promote-staged reads; each tree's metadata (repodata, Packages,
# Release, cells.tsv, the repository and key files, changelogs) is its own and is made again for staging
mapfile -t pkgs < <(cd "$src" && find . -type f -name "*.$kind" | sed 's|^\./||' | LC_ALL=C sort)
mapfile -t recs < <(cd "$src" && { [ ! -d built ] || find built -type f; } | LC_ALL=C sort)
[ "${#pkgs[@]}" -gt 0 ] || { echo "promote-wave: $rel holds no package: nothing to promote"; exit 0; }

# the wave's tree vouched for as a publish vouches for what it did not place, on a scratch copy (the tree is not written)
if [ -n "$key" ]; then
    cp -a "$src" "$work/vouch"
    if [ "$kind" = rpm ]; then
        find "$work/vouch" -type d -name repodata -prune -exec rm -rf {} +
        REPO_FILE=$("$here/../publish-rpms/channel-level.sh" repo-file "devel/$wave" "$work/repo") EMPTY_OK=true SKELETON='' \
            "$here/../publish-rpms/publish-tree.sh" "$work/vouch" "$work/empty" "$key" > "$work/vouch.log" 2>&1 ||
            { cat "$work/vouch.log" >&2; die "$rel holds packages its signatures do not vouch for: nothing was promoted"; }
    else
        LABEL=OpenMixer-Devel EMPTY_OK=true SKELETON='' "$here/../publish-debs/publish-tree.sh" "$work/vouch" "$work/empty" "$key" \
            > "$work/vouch.log" 2>&1 || { cat "$work/vouch.log" >&2; die "$rel holds packages its signed index does not vouch for: nothing was promoted"; }
    fi
fi

# a path staging holds with other bytes refuses the whole promotion; the same bytes are kept
clash=0 kept=0
declare -a new=()
for f in "${pkgs[@]}" ${recs[@]+"${recs[@]}"}; do
    if [ -e "$dst/$f" ]; then
        if cmp -s "$src/$f" "$dst/$f"; then kept=$((kept + 1)); continue; fi
        echo "refused staging/$kind/$f: staging holds it with other bytes than $rel/$f, and a promotion never replaces a published file" >&2
        clash=1
    else
        new+=("$f")
    fi
done
[ "$clash" = 0 ] || die "nothing was copied"

mkdir -p "$dst"
# the wave's rows of cells.tsv join staging's, replacing a row of the same package and version: cells.sh (run by the tree
# script below) keeps each row's set and reads the cells from the tree again
if [ -f "$src/cells.tsv" ]; then
    awk -F'\t' 'FNR == NR { if ($0 !~ /^#/ && $1 != "") w[$1 FS $2] = $0; next }
        $0 !~ /^#/ && $1 != "" && !(($1 FS $2) in w) { print }
        END { for (k in w) print w[k] }' "$src/cells.tsv" "$( [ -f "$dst/cells.tsv" ] && echo "$dst/cells.tsv" || echo /dev/null)" > "$work/cells.tsv"
    mv "$work/cells.tsv" "$dst/cells.tsv"
fi

# the same bytes into staging: an rpm is copied in place (its signature is its own, and the tree script checks it as a
# package it did not place); a deb is handed to the tree script, which places it by its control file at the same path and
# indexes it under staging's signed Release; a build record is copied
mkdir -p "$work/debs"
for f in ${new[@]+"${new[@]}"}; do
    case $f in
        *.deb) suite=${f#debian/}; suite=${suite%%/*}; mkdir -p "$work/debs/$suite"; install -m 0644 "$src/$f" "$work/debs/$suite/" ;;
        *) install -D -m 0644 "$src/$f" "$dst/$f" ;;
    esac
done
if [ "$kind" = rpm ]; then
    find "$dst" -type d -name repodata -prune -exec rm -rf {} +
    REPO_FILE=$here/../../../packaging/staging/openmixer-staging.repo EMPTY_OK=true \
        "$here/../publish-rpms/publish-tree.sh" "$dst" "$work/empty" ${key:+"$key"}
else
    LABEL=OpenMixer-Staging EMPTY_OK=true "$here/../publish-debs/publish-tree.sh" "$dst" "$work/debs" ${key:+"$key"}
fi

# every promoted file is the wave's, byte for byte, at its path
for f in "${pkgs[@]}" ${recs[@]+"${recs[@]}"}; do
    cmp -s "$src/$f" "$dst/$f" || die "staging/$kind/$f is not the bytes of $rel/$f after the promotion"
done
echo "promoted $rel -> staging/$kind: ${#new[@]} file(s) copied, $kept already there with the same bytes, ${#pkgs[@]} package(s) of the wave in staging's index"
