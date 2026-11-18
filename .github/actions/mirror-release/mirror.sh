#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Mirror ONE package of the FreeREAC channel into this channel: the release package freereac-release, so that openmixer-release's
# Requires: freereac-release resolves from the OpenMixer channel alone on a machine that has only that channel enabled (the upgrade path
# of an existing client), after which the FreeREAC repository it installs serves reac-pw. Nothing else of FreeREAC's is ever mirrored.
#
#   mirror.sh rpm <FreeREAC channel URL|DIR> <package> <version-release> <out dir>     one unsigned rpm per Fedora release in RELEASES
#   mirror.sh deb <FreeREAC channel URL|DIR> <package> <version> <out dir>              <out dir>/<suite>/<file>.deb, SUITES
#
# THE SOURCE IS VERIFIED, NOT TRUSTED. The FreeREAC key is the one primary whose fingerprint is committed in freereac-key.fpr (public data,
# beside this script): the key file the channel serves must hold exactly that one key. An rpm must carry a good signature by it (header and
# payload digests too); a deb must be listed, with its sha256, in a Packages index whose sha256 is in a Release signed by it (Release.gpg).
# Anything else is refused by name and nothing is written.
#
# The rpm leaves UNSIGNED (rpmsign --delsign: the signature header is the only change): publish-rpms signs it with THIS channel's key. The
# FreeREAC signature is not kept, because a client of this channel holds only this channel's key and gpgcheck=1 would refuse a package signed
# by another; the source signature is what this script verifies, the channel's signature is what the client verifies. A deb carries no
# signature of its own; the index of this channel, signed by this channel's key, vouches for it.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
usage='usage: mirror.sh rpm|deb <FreeREAC channel URL|DIR> <package> <version> <out dir>'
kind=${1:?$usage}; base=${2:?$usage}; pkg=${3:?$usage}; ver=${4:?$usage}; out=$(readlink -m "${5:?$usage}")
base=${base%/}
want=$(grep -v '^#' "${FREEREAC_KEY_FPR_FILE:-$here/freereac-key.fpr}" | tr -d '[:space:]')
[[ $want =~ ^[0-9A-Fa-f]{40}$ ]] || { echo "FAIL: the pinned FreeREAC fingerprint '$want' is not a fingerprint" >&2; exit 1; }
[[ $pkg =~ ^[a-z0-9][a-z0-9.+-]*$ && $ver =~ ^[A-Za-z0-9.+~_-]+$ ]] || { echo "FAIL: '$pkg' '$ver' is not a package and a version" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

get() { # <path under the channel> <dest>
    case $base in
    http://* | https://*) curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o "$2" "$base/$1" || fail "$base/$1 could not be fetched" ;;
    *) cp -- "$base/$1" "$2" || fail "$base/$1 is not there" ;;
    esac
}

# the key the channel serves: exactly one primary, the pinned one
key_dir=$work/key
mkdir -p "$key_dir"
chmod 700 "$key_dir"
case $kind in rpm) get rpm/RPM-GPG-KEY-freereac "$work/key.asc" ;; deb) get deb/freereac.asc "$work/key.asc" ;; *) fail "$usage" ;; esac
have=$(gpg --batch --with-colons --import-options show-only --import < "$work/key.asc" 2>/dev/null | awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
[ "$(wc -w <<< "$have")" = 1 ] || fail "the FreeREAC channel serves $(wc -w <<< "$have") keys ($(tr '\n' ' ' <<< "$have")), exactly one is expected"
[ "${have^^}" = "${want^^}" ] || fail "the FreeREAC channel's key is $have, not the pinned $want"
export GNUPGHOME=$key_dir
gpg --batch --quiet --import < "$work/key.asc"

case $kind in
rpm)
    mkdir -p "$work/root" "$out"
    gpg --batch --armor --export "$want" > "$work/pub.asc"
    rpmkeys --root "$work/root" --import "$work/pub.asc"
    for rel in ${RELEASES:-44 45}; do
        f=$pkg-$ver.fc$rel.noarch.rpm
        get "rpm/fedora/$rel/noarch/$f" "$work/$f"
        res=$(rpmkeys --root "$work/root" --checksig "$work/$f" 2>&1) || true
        grep -q 'digests signatures OK' <<< "$res" || fail "$f has no good signature by the pinned FreeREAC key: $res"
        [ "$(rpm -qp --qf '%{NAME}' "$work/$f")" = "$pkg" ] || fail "$f is not the package $pkg"
        vr=$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$work/$f")
        [ "$vr" = "$ver.fc$rel" ] || fail "$f is $vr, not the requested $ver.fc$rel"
        rpmsign --delsign "$work/$f" > /dev/null
        install -m 0644 "$work/$f" "$out/$f"
        echo "mirrored $f (verified against $want, signature header removed)"
    done
    ;;
deb)
    for suite in ${SUITES:-trixie}; do
        d=deb/debian/$suite
        mkdir -p "$work/$suite"
        for f in Release Release.gpg Packages; do get "$d/$f" "$work/$suite/$f"; done
        gpg --batch --export "$want" > "$work/keyring.gpg"
        gpgv --keyring "$work/keyring.gpg" "$work/$suite/Release.gpg" "$work/$suite/Release" > /dev/null 2>&1 || fail "$d/Release is not signed by the pinned FreeREAC key"
        sha=$(sha256sum < "$work/$suite/Packages" | cut -d' ' -f1)
        grep -A64 '^SHA256:' "$work/$suite/Release" | grep -qE "^ $sha +[0-9]+ Packages\$" || fail "$d/Packages is not the file the signed Release lists"
        entry=$(awk -v p="$pkg" -v v="$ver" 'BEGIN {RS = ""; FS = "\n"} {n = ""; vv = ""; fn = ""; h = ""
            for (i = 1; i <= NF; i++) { if ($i ~ /^Package: /) n = substr($i, 10); if ($i ~ /^Version: /) vv = substr($i, 10); if ($i ~ /^Filename: /) fn = substr($i, 11); if ($i ~ /^SHA256: /) h = substr($i, 9) }
            if (n == p && vv == v) print fn, h}' "$work/$suite/Packages")
        [ -n "$entry" ] || fail "$d/Packages lists no $pkg $ver"
        [ "$(wc -l <<< "$entry")" = 1 ] || fail "$d/Packages lists $pkg $ver more than once"
        fn=${entry%% *}; h=${entry##* }
        get "$d/${fn#./}" "$work/$suite/pkg.deb"
        [ "$(sha256sum < "$work/$suite/pkg.deb" | cut -d' ' -f1)" = "$h" ] || fail "$fn does not have the sha256 the signed index lists"
        mkdir -p "$out/$suite"
        install -m 0644 "$work/$suite/pkg.deb" "$out/$suite/$(basename "$fn")"
        echo "mirrored $(basename "$fn") (index and Release verified against $want)"
    done
    ;;
esac
