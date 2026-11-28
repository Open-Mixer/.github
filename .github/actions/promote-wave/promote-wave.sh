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
#
# PROMOTE_PACKAGES (names, space separated): ONE LINE of a wave, promoted once that line is proven (devel-chain.sh's
# continuous promotion), not the whole wave: only the packages whose name, or whose source package's name, is listed
# (rpm %{NAME} / its SOURCERPM's name; deb Package / Source), their cells.tsv rows and the build records
# built/<name>/ of a listed name move. The same refusals and the same byte comparison apply. A line names the packages
# of both kinds (channel-promote --line: rpm libomx-domain-devel beside deb libomx-domain-dev), so a name no package of
# this kind matches is no refusal by itself when the other kind's tree holds it (its build record built/<name>/, a
# package file of that name, or a deb index stanza of that Package or Source): it is named "no <kind> of <name> in the
# wave". A name that matches on no kind is refused, naming it (a line that published nothing into the wave has nothing
# to promote, and saying so beats a green no-op). The whole wave promoted later keeps these bytes: the same bytes at
# the same path are kept.
#
# PROMOTE_KEEP_STAGING (<name>=<version>, space separated): the reconciliation of a version built twice before the
# build-once fix (a merge to devel outside the wave built it again into staging, with other bytes). Staging's build was
# published first and a published file is never replaced, so staging's is kept: every file of the wave of that name
# (as above) and version, its build record built/<name>/<version>.commit and its cells.tsv rows are left out, and the
# wave's copy is reported superseded, by path. Each left-out package must be a path staging holds, else it is refused
# (keeping staging's build of a version staging does not hold would drop the version). A token names a SOURCE package
# (or project) and version, and matches each kind by the source name that kind records (rpm: its SOURCERPM's name and
# built/<name>/; deb: its Source field, else Package, and built/<name>/), so libdiginet=0.1.11 keeps the deb files built
# from source libdiginet whatever their binary names. A kind holding the source at no version at all (the wave built
# no package of it of this kind) is no refusal by itself: it is named "no <kind> of <name> in the wave", and the token
# must match on the other kind (devel/<wave>/<other kind>: its build record built/<name>/<version>.commit, a package file
# of that name and version, or a deb index stanza of that Source and version), else it matches on no kind and is
# refused. A kind holding the source at other versions only refuses the token. Every other path staging holds with
# other bytes still refuses the promotion.
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
other=rpm; [ "$kind" = deb ] || other=deb
osrc=$channel/$("$here/../publish-rpms/channel-level.sh" tree "$other" "devel/$wave")
# other_holds <name> [<version>]: the wave's tree of the other kind holds <name> (at <version>, if given), read without
# that kind's tools (a deb job has no rpm, an rpm job no dpkg): its build record built/<name>/, a package file of that
# name (rpm <name>-<version>-<release>.<arch>.rpm, a src.rpm naming the source; deb <name>_<version>[-<revision>]_<arch>.deb),
# or a stanza of a deb index whose Source (else Package) is <name>; with no version, whose Package or Source is <name>
other_holds() {
    local n=$1 v=${2:-}
    [ -d "$osrc" ] || return 1
    if [ -n "$v" ]; then
        [ ! -f "$osrc/built/$n/$v.commit" ] || return 0
        [ -z "$(find "$osrc" -type f \( -name "$n-$v-*.rpm" -o -name "${n}_${v}_*.deb" -o -name "${n}_${v}-*_*.deb" \) -print -quit)" ] || return 0
    else
        [ ! -d "$osrc/built/$n" ] || return 0
        # <name>-<version>-<release>.<arch>.rpm with its last three fields off is <name>; <name>_<version>_<arch>.deb
        find "$osrc" -type f \( -name "$n-*.rpm" -o -name "${n}_*.deb" \) -printf '%f\n' |
            sed -E -e '/\.rpm$/ { s/\.[^.]+\.rpm$//; s/-[^-]+-[^-]+$//; }' -e 's/_[^_]+_[^_]+\.deb$//' | grep -xF -- "$n" > /dev/null && return 0
    fi
    # no index (an rpm tree has none) holds nothing: xargs -r runs no awk and exits 0, which read as held
    local idx; mapfile -t idx < <(find "$osrc" -type f -name Packages)
    [ "${#idx[@]}" -gt 0 ] || return 1
    awk -v n="$n" -v v="$v" '
        function done_() { b = p; s = s == "" ? p : s; sub(/ .*/, "", s); sub(/^[0-9]+:/, "", w); sub(/-[^-]*$/, "", w)
            if (v == "" ? (b == n || s == n) : (s == n && w == v)) f = 1; p = s = w = "" }
        /^Package: / { p = $2 } /^Source: / { s = $2 } /^Version: / { w = $2 } /^$/ { done_() }
        END { done_(); exit !f }' "${idx[@]}"
}
# unselected <name>: a packages name no package of this kind matched; named and passed when the other kind holds it,
# else refused
unselected() {
    other_holds "$1" || die "$1 matches no package of $rel nor of devel/$wave/$other, on no kind: nothing was promoted"
    echo "promote-wave: no $kind of $1 in the wave: packages $1 is for devel/$wave/$other"
}
# unmatched <token> <this kind holds the name>: a keep token no package of this kind matched; named and passed when this
# kind holds no package of its source and the other kind holds the version, else refused
unmatched() {
    local k=$1 n=${1%%=*} v=${1#*=}
    [ "$2" = 0 ] || die "keep-staging $k: $rel holds $n, but no package of it at $v that this promotion moves: nothing was promoted"
    other_holds "$n" "$v" || die "$k matches no package of $rel nor of devel/$wave/$other, on no kind: nothing was promoted"
    echo "promote-wave: no $kind of $n in the wave: keep-staging $k is for devel/$wave/$other, nothing of $rel is left out for it"
}
# a wave that published nothing of this kind (a devel matrix of rpm cells alone builds no deb) promotes nothing of it
[ -d "$src" ] || {
    for k in ${PROMOTE_PACKAGES:-}; do unselected "$k"; done
    for k in ${PROMOTE_KEEP_STAGING:-}; do unmatched "$k" 0; done
    echo "promote-wave: the channel has no $rel: the wave published nothing of this kind, nothing to promote"; exit 0
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/empty"

# what moves: the packages and the build records promote-staged reads; each tree's metadata (repodata, Packages,
# Release, cells.tsv, the repository and key files, changelogs) is its own and is made again for staging
mapfile -t pkgs < <(cd "$src" && find . -type f -name "*.$kind" | sed 's|^\./||' | LC_ALL=C sort)
mapfile -t recs < <(cd "$src" && { [ ! -d built ] || find built -type f; } | LC_ALL=C sort)
[ "${#pkgs[@]}" -gt 0 ] || {
    for k in ${PROMOTE_PACKAGES:-}; do unselected "$k"; done
    for k in ${PROMOTE_KEEP_STAGING:-}; do unmatched "$k" 0; done
    echo "promote-wave: $rel holds no package: nothing to promote"; exit 0
}

# keys <file>: "<name> <version>" of the package and of its source package, one a line (the version without epoch or
# release/revision, as record-built.sh writes it)
keys() {
    local n v s
    case $1 in
        *.rpm) IFS=' ' read -r n v s < <(rpm -qp --nosignature --qf '%{NAME} %{VERSION} %{SOURCERPM}\n' "$1" 2>/dev/null) ||
                   die "$1 is no rpm the tools can read"
               echo "$n $v"
               case $s in *.src.rpm) s=${s%.src.rpm}; s=${s%-*}; s=${s%-*}; echo "$s $v" ;; esac ;;
        *.deb) n=$(dpkg-deb -f "$1" Package) v=$(dpkg-deb -f "$1" Version) s=$(dpkg-deb -f "$1" Source)
               v=${v#*:}; case $v in *-*) v=${v%-*} ;; esac
               echo "$n $v"; [ -z "$s" ] || echo "${s%% *} $v" ;;
    esac
}
sel=" ${PROMOTE_PACKAGES:-} " keep=" ${PROMOTE_KEEP_STAGING:-} "
for k in ${PROMOTE_KEEP_STAGING:-}; do [[ $k =~ ^[A-Za-z0-9.+_-]+=[A-Za-z0-9.+~_-]+$ ]] || die "keep-staging '$k' is not <name>=<version>"; done
for k in ${PROMOTE_PACKAGES:-}; do [[ $k =~ ^[A-Za-z0-9.+_-]+$ ]] || die "packages '$k' is not a package name"; done
declare -A rows=() hit=() named=()
superseded=()
if [ -n "${PROMOTE_PACKAGES:-}${PROMOTE_KEEP_STAGING:-}" ]; then
    picked=()
    for f in "${pkgs[@]}"; do
        mapfile -t ks < <(keys "$src/$f")
        in=1 kept=''
        if [ -n "${PROMOTE_PACKAGES:-}" ]; then
            in=0; for k in "${ks[@]}"; do case $sel in *" ${k% *} "*) in=1; hit[${k% *}]=1 ;; esac; done
        fi
        for k in "${ks[@]}"; do case $keep in *" ${k% *}="*) named[${k% *}]=1 ;; esac; done
        [ "$in" = 1 ] || continue
        for k in "${ks[@]}"; do case $keep in *" ${k% *}=${k#* } "*) kept=${k% *}=${k#* } ;; esac; done
        if [ -n "$kept" ]; then
            hit[$kept]=1
            [ -e "$dst/$f" ] || die "keep-staging $kept: staging/$kind/$f is not there, so staging has no build of it to keep: nothing was promoted"
            superseded+=("$f ($kept)")
            continue
        fi
        picked+=("$f"); rows["${ks[0]% *}"$'\t'"${ks[0]#* }"]=1
    done
    for k in ${PROMOTE_PACKAGES:-}; do
        [ -n "${hit[$k]:-}" ] || unselected "$k"
    done
    for k in ${PROMOTE_KEEP_STAGING:-}; do
        [ -n "${hit[$k]:-}" ] || unmatched "$k" "${named[${k%%=*}]:-0}"
    done
    pkgs=(${picked[@]+"${picked[@]}"})
    left=()
    for r in ${recs[@]+"${recs[@]}"}; do
        n=${r#built/}; v=${n#*/}; n=${n%%/*}; v=${v%.commit}
        case $keep in *" $n=$v "*) superseded+=("$r ($n=$v)"); continue ;; esac
        if [ -n "${PROMOTE_PACKAGES:-}" ]; then case $sel in *" $n "*) ;; *) continue ;; esac; fi
        left+=("$r")
    done
    recs=(${left[@]+"${left[@]}"})
    for s in ${superseded[@]+"${superseded[@]}"}; do echo "superseded $rel/$s: staging keeps its own build, published first; the wave's copy is not promoted"; done
    [ "${#pkgs[@]}" -gt 0 ] || { echo "promote-wave: nothing of $rel is left to promote once ${PROMOTE_KEEP_STAGING:+the kept versions }are left out"; exit 0; }
fi

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
    # one line, or with versions kept: only the rows of the packages that move
    if [ -n "${PROMOTE_PACKAGES:-}${PROMOTE_KEEP_STAGING:-}" ]; then
        printf '%s\n' "${!rows[@]}" > "$work/rows"
        awk -F'\t' 'FNR == NR { k[$0] = 1; next } /^#/ || ($1 FS $2) in k' "$work/rows" "$src/cells.tsv" > "$work/wave-cells.tsv"
    else
        cp "$src/cells.tsv" "$work/wave-cells.tsv"
    fi
    awk -F'\t' 'FNR == NR { if ($0 !~ /^#/ && $1 != "") w[$1 FS $2] = $0; next }
        $0 !~ /^#/ && $1 != "" && !(($1 FS $2) in w) { print }
        END { for (k in w) print w[k] }' "$work/wave-cells.tsv" "$( [ -f "$dst/cells.tsv" ] && echo "$dst/cells.tsv" || echo /dev/null)" > "$work/cells.tsv"
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
what=$rel more=''
[ -z "${PROMOTE_PACKAGES:-}" ] || what="$rel ($PROMOTE_PACKAGES)"
[ "${#superseded[@]}" = 0 ] || more=", ${#superseded[@]} superseded by staging's own build"
echo "promoted $what -> staging/$kind: ${#new[@]} file(s) copied, $kept already there with the same bytes, ${#pkgs[@]} package(s) of the wave in staging's index$more"
