#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The signature check of a promotion (promote-staged.yml): what collect.py copied out of the staging tree is promoted
# only if the release key already vouches for it. Nothing is signed here, and a promotion signs no package.
#
#   vouch.sh <channel checkout> rpm|deb <collected dir>
#
# rpm: every package carries a good signature by a key the channel serves (rpm/RPM-GPG-KEY-openmixer, read only if
# every primary in it is pinned in this repository, channel-keys.sh). An unsigned package is refused: the publish
# would sign it, and a promotion must not turn a write to the staging tree into a package signed by the release key.
# deb: a .deb carries no signature of its own, so every package must be listed with its SHA256 in its suite's staging
# Packages, whose InRelease verifies against the keys the channel serves (deb/openmixer.asc, pinned the same way).
# Refuses naming each file; exit 0 says every file is vouched for.
set -euo pipefail
channel=$(readlink -f "${1:?usage: vouch.sh <channel checkout> rpm|deb <collected dir>}")
kind=${2:?usage: vouch.sh <channel checkout> rpm|deb <collected dir>}
src=${3:?usage: vouch.sh <channel checkout> rpm|deb <collected dir>}
keys=$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh
refused=0
case $kind in
rpm)
    served=$channel/rpm/RPM-GPG-KEY-openmixer
    [ -s "$served" ] || { echo "the channel serves no key at rpm/RPM-GPG-KEY-openmixer: nothing can be vouched for" >&2; exit 1; }
    "$keys" pinned "$served" || { echo "the channel's key file is not one this repository pins: nothing is promoted" >&2; exit 1; }
    # rpmkeys takes one key per file, so the served keys are split by fingerprint first
    home=$(mktemp -d); keystore=$(mktemp -d)
    "$keys" emit "$served" | GNUPGHOME=$home gpg --batch --quiet --import 2>/dev/null
    while IFS= read -r fpr; do
        GNUPGHOME=$home gpg --batch --armor --export "$fpr" > "$home/k.asc"
        rpmkeys --root "$keystore" --import "$home/k.asc"
    done < <(GNUPGHOME=$home gpg --batch --with-colons --fingerprint | awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
    n=0
    while IFS= read -r f; do
        n=$((n + 1))
        out=$(rpmkeys --root "$keystore" --checksig "$f" 2>&1) || true
        case $out in
            *": digests signatures OK") echo "vouched $(basename "$f")" ;;
            *) echo "refused $(basename "$f"): not signed by a key the channel serves ($out)" >&2; refused=1 ;;
        esac
    done < <(find "$src" -name '*.rpm' | sort)
    rm -rf "$home" "$keystore"
    ;;
deb)
    command -v gpgv >/dev/null || { echo "gpgv is not installed: the staging index cannot be read, so nothing can be vouched for" >&2; exit 1; }
    served=$channel/deb/openmixer.asc
    [ -s "$served" ] || { echo "the channel serves no key at deb/openmixer.asc: nothing can be vouched for" >&2; exit 1; }
    "$keys" pinned "$served" || { echo "the channel's key file is not one this repository pins: nothing is promoted" >&2; exit 1; }
    keyring=$(mktemp)
    "$keys" emit "$served" | gpg --batch --yes --dearmor > "$keyring"
    # the staging index of a suite, as "<sha256> ./<arch>/<file>" lines, when its InRelease carries a good signature
    # and names the Packages beside it (as publish-debs/publish-tree.sh reads the index it vouches by)
    index() {
        local dir=$1 release want got
        [ -f "$dir/InRelease" ] && [ -f "$dir/Packages" ] || return 0
        release=$(mktemp)
        { gpgv --status-fd 3 --keyring "$keyring" --output "$release" "$dir/InRelease" 3>&1 1>/dev/null 2>/dev/null || true; } |
            awk '/BADSIG/ {b = 1} /VALIDSIG/ {g = 1} END {exit !(g && !b)}' || { rm -f "$release"; return 0; }
        want=$(awk '/^SHA256:/ {s = 1; next} /^[^ ]/ {s = 0} s && $3 == "Packages" {print $1}' "$release")
        rm -f "$release"
        got=$(sha256sum < "$dir/Packages" | cut -d' ' -f1)
        [ -n "$want" ] && [ "$want" = "$got" ] || return 0
        awk '/^Filename:/ {f = $2} /^SHA256:/ {h = $2} /^$/ {if (f != "" && h != "") print h, f; f = ""; h = ""}
            END {if (f != "" && h != "") print h, f}' "$dir/Packages"
    }
    n=0
    for suitedir in "$src"/*/; do
        [ -d "$suitedir" ] || continue
        suite=$(basename "$suitedir")
        idx=$(index "$channel/staging/deb/debian/$suite")
        while IFS= read -r f; do
            n=$((n + 1))
            arch=$(dpkg-deb -f "$f" Architecture)
            if grep -qxF "$(sha256sum < "$f" | cut -d' ' -f1) ./$arch/$(basename "$f")" <<< "$idx"; then
                echo "vouched $suite/$(basename "$f")"
            else
                echo "refused $suite/$(basename "$f"): not in the signed staging index of $suite" >&2; refused=1
            fi
        done < <(find "$suitedir" -name '*.deb' | sort)
    done
    rm -f "$keyring"
    ;;
*) echo "rpm or deb, not $kind" >&2; exit 1 ;;
esac
[ "$n" -gt 0 ] || { echo "no package under $src" >&2; exit 1; }
[ "$refused" = 0 ] || { echo "the staged build is not vouched for: nothing is promoted" >&2; exit 1; }
