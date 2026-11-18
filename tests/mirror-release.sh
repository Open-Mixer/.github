#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# mirror.sh against a fixture FreeREAC channel (a directory laid out like the served one), throwaway keys: the package signed by the pinned key
# is mirrored (an rpm leaves UNSIGNED for this channel's key to sign), and each way the source could lie is refused by name: a package signed by
# another key, an unsigned one, a key file with a second key, a key that is not the pinned one, a deb the signed index does not list or whose
# bytes differ from the index.
#
#   mirror-release.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
mirror=$here/../.github/actions/mirror-release/mirror.sh
w=$(mktemp -d); chmod 755 "$w"
export GNUPGHOME=$w/g; mkdir -m700 "$GNUPGHOME"
fail() { echo "FAIL: $*" >&2; exit 1; }
for n in a b; do gpg --batch -q --passphrase '' --quick-gen-key "Key $n <$n@example.org>" rsa3072 sign 1y; done
fpr() { gpg --with-colons --fingerprint "$1@example.org" | awk -F: '/^fpr:/ {print $10; exit}'; }
A=$(fpr a); B=$(fpr b)
printf '%s\n' "$A" > "$w/pinned"; export FREEREAC_KEY_FPR_FILE=$w/pinned
refused() { # <label> <must say> -- command...
    local label=$1 must=$2; shift 3
    if out=$("$@" 2>&1); then fail "$label: accepted"; fi
    grep -qF -- "$must" <<< "$out" || fail "$label: the refusal does not say '$must': $out"
}
case ${1:?usage: mirror-release.sh rpm|deb} in
rpm)
    mk() { # <fedora> <dir> <signing key or empty>
        printf 'Name: freereac-release\nVersion: 1\nRelease: 1.fc%s\nSummary: t\nLicense: MIT\nBuildArch: noarch\n%%description\nt\n%%files\n' "$1" > "$w/s$1.spec"
        rpmbuild -bb --quiet --define "_topdir $w/rb$1" "$w/s$1.spec" > /dev/null 2>&1
        mkdir -p "$2/rpm/fedora/$1/noarch"; cp "$w/rb$1/RPMS/noarch/freereac-release-1-1.fc$1.noarch.rpm" "$2/rpm/fedora/$1/noarch/"
        [ -z "$3" ] || rpmsign --addsign --define "_gpg_name $3" --define "_gpg_sign_cmd_extra_args --pinentry-mode loopback" "$2/rpm/fedora/$1/noarch/freereac-release-1-1.fc$1.noarch.rpm" > /dev/null
    }
    good=$w/good; mkdir -p "$good/rpm"; gpg --armor --export "$A" > "$good/rpm/RPM-GPG-KEY-freereac"
    mk 44 "$good" "$A"; mk 45 "$good" "$A"
    RELEASES="44 45" "$mirror" rpm "$good" freereac-release 1-1 "$w/out" > /dev/null || fail "a package signed by the pinned key was refused"
    for rel in 44 45; do
        f=$w/out/freereac-release-1-1.fc$rel.noarch.rpm
        [ -s "$f" ] || fail "fc$rel was not mirrored"
        sig=$(rpm -qp --qf '%{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}' "$f" 2>/dev/null | sed 's/(none)//g')
        [ -z "$sig" ] || fail "the mirrored fc$rel still carries a signature ($sig): this channel signs it, not FreeREAC"
    done
    # no cells given: refused by name, and a release added to the cells that the source does not serve is refused naming it, one served is mirrored
    refused 'rpm with RELEASES unset' 'RELEASES is unset' -- env -u RELEASES "$mirror" rpm "$good" freereac-release 1-1 "$w/out-unset"
    refused 'rpm with RELEASES empty' 'RELEASES is unset' -- env RELEASES= "$mirror" rpm "$good" freereac-release 1-1 "$w/out-empty"
    refused 'a cell the source does not serve' 'fc46' -- env RELEASES="44 45 46" "$mirror" rpm "$good" freereac-release 1-1 "$w/out-46"
    mk 46 "$good" "$A"
    RELEASES="44 45 46" "$mirror" rpm "$good" freereac-release 1-1 "$w/out-46b" > /dev/null || fail "a cell added to the list was not mirrored"
    [ -s "$w/out-46b/freereac-release-1-1.fc46.noarch.rpm" ] || fail "fc46 was not mirrored"
    RELEASES="44" "$mirror" rpm "$good" freereac-release 1-1 "$w/out-only44" > /dev/null
    [ ! -e "$w/out-only44/freereac-release-1-1.fc45.noarch.rpm" ] || fail "a release not in the list was mirrored"
    # signed by another key
    bad=$w/bad; mkdir -p "$bad/rpm"; cp "$good/rpm/RPM-GPG-KEY-freereac" "$bad/rpm/"; mk 44 "$bad" "$B"; mk 45 "$bad" "$B"
    refused 'rpm signed by another key' 'no good signature by the pinned FreeREAC key' -- env RELEASES="44 45" "$mirror" rpm "$bad" freereac-release 1-1 "$w/out-bad"
    [ ! -e "$w/out-bad" ] || [ -z "$(ls -A "$w/out-bad")" ] || fail "a refused package was written"
    # unsigned
    uns=$w/uns; mkdir -p "$uns/rpm"; cp "$good/rpm/RPM-GPG-KEY-freereac" "$uns/rpm/"; mk 44 "$uns" ""; mk 45 "$uns" ""
    refused 'unsigned rpm' 'no good signature' -- env RELEASES="44 45" "$mirror" rpm "$uns" freereac-release 1-1 "$w/out-uns"
    # a signed rpm under the requested name whose version-release is not the requested one (the file name lies about its content)
    liar=$w/liar; mkdir -p "$liar/rpm"; cp "$good/rpm/RPM-GPG-KEY-freereac" "$liar/rpm/"; mk 44 "$liar" "$A"; mk 45 "$liar" "$A"
    for rel in 44 45; do mv "$liar/rpm/fedora/$rel/noarch/freereac-release-1-1.fc$rel.noarch.rpm" "$liar/rpm/fedora/$rel/noarch/freereac-release-2-1.fc$rel.noarch.rpm"; done
    refused "an rpm whose version-release is not the requested one" "is 1-1.fc44, not the requested 2-1.fc44" -- env RELEASES="44 45" "$mirror" rpm "$liar" freereac-release 2-1 "$w/out-liar"
    # a key file with a second key, and a key that is not the pinned one
    two=$w/two; cp -r "$good" "$two"; gpg --armor --export "$A" "$B" > "$two/rpm/RPM-GPG-KEY-freereac"
    refused 'a key file with two keys' 'serves 2 keys' -- env RELEASES="44 45" "$mirror" rpm "$two" freereac-release 1-1 "$w/out-two"
    other=$w/other; cp -r "$good" "$other"; gpg --armor --export "$B" > "$other/rpm/RPM-GPG-KEY-freereac"
    refused 'a key that is not the pinned one' 'not the pinned' -- env RELEASES="44 45" "$mirror" rpm "$other" freereac-release 1-1 "$w/out-other"
    ;;
deb)
    ch=$w/ch/deb/debian/trixie; mkdir -p "$ch/all" "$w/p/DEBIAN"
    printf 'Package: freereac-release\nVersion: 1-1\nArchitecture: all\nMaintainer: t <t@example.org>\nDescription: t\n' > "$w/p/DEBIAN/control"
    dpkg-deb -b "$w/p" "$ch/all/freereac-release_1-1_all.deb" > /dev/null
    (cd "$ch" && apt-ftparchive packages . > Packages && apt-ftparchive release . > Release)
    sign() { gpg --batch --yes --armor --detach-sign --local-user "$1" --output "$ch/Release.gpg" "$ch/Release"; }
    sign "$A"; gpg --armor --export "$A" > "$w/ch/deb/freereac.asc"
    SUITES=trixie "$mirror" deb "$w/ch" freereac-release 1-1 "$w/out" > /dev/null || fail "a deb the signed index lists was refused"
    [ -s "$w/out/trixie/freereac-release_1-1_all.deb" ] || fail "the deb was not mirrored"
    refused 'deb with SUITES unset' 'SUITES is unset' -- env -u SUITES "$mirror" deb "$w/ch" freereac-release 1-1 "$w/out-unset"
    refused 'a suite the source does not serve' 'trixie2' -- env SUITES="trixie trixie2" "$mirror" deb "$w/ch" freereac-release 1-1 "$w/out-2"
    # an index signed by another key
    sign "$B"
    refused 'a Release signed by another key' 'is not signed by the pinned FreeREAC key' -- env SUITES=trixie "$mirror" deb "$w/ch" freereac-release 1-1 "$w/out-bad"
    sign "$A"
    # bytes that differ from the signed index
    printf 'x' >> "$ch/all/freereac-release_1-1_all.deb"
    refused 'a deb that differs from the index' 'does not have the sha256 the signed index lists' -- env SUITES=trixie "$mirror" deb "$w/ch" freereac-release 1-1 "$w/out-tamper"
    refused 'a version the index does not list' 'lists no freereac-release 9' -- env SUITES=trixie "$mirror" deb "$w/ch" freereac-release 9 "$w/out-none"
    ;;
esac
echo "mirror-release $1: ok"
