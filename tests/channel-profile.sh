#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A channel that is not OpenMixer's, published through the same scripts: KEY_FILE names its key file,
# SERVED_KEYS_DIR=none keeps OpenMixer's committed keys out of it, REPO_FILE is its repository file. It must serve exactly the
# key it signs with, under its own name, and nothing of OpenMixer's key file name. The defaults stay OpenMixer's.
#
#   channel-profile.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
actions=$here/../.github/actions
work=$(mktemp -d)
chmod 755 "$work"
fail() { echo "FAIL: $*" >&2; exit 1; }
served() { gpg --batch --with-colons --import-options show-only --import < "$1" 2>/dev/null |
    awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}' | sort | tr '\n' ' '; }
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Channel Key <ch@example.org>' ed25519 sign 1y
KEY=$(gpg --with-colons --fingerprint ch@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$KEY" > "$PINNED_FINGERPRINTS"
# a committed key of "OpenMixer's", which the other channel must not serve
mkdir "$work/committed"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Other Key <other@example.org>' ed25519 sign 1y
OTHER=$(gpg --with-colons --fingerprint other@example.org | awk -F: '/^fpr:/ {print $10; exit}')
printf '%s packages throwaway\n' "$OTHER" >> "$PINNED_FINGERPRINTS"
gpg --batch --armor --export "$OTHER" > "$work/committed/other.asc"

# the signing fingerprint a channel names: another key is refused by name and nothing is signed, the named one passes, and a channel
# with no committed keys that names none is refused
cf=$actions/import-gpg-key/check-fingerprint.sh
"$cf" key "$KEY" "$KEY" || fail "the named key was refused"
"$cf" key "$KEY" "${KEY,,}" || fail "the named key was refused in lower case"
"$cf" key "$KEY" "" || fail "no fingerprint named must check none"
if out=$("$cf" key "$OTHER" "$KEY" 2>&1); then fail "a key that is not the named one was accepted"; fi
grep -q "the signing key is $OTHER, not the $KEY" <<< "$out" || fail "the refusal does not name both keys: $out"
if "$cf" want false "" 2>/dev/null; then fail "committed-keys=false with no fingerprint was accepted"; fi
if "$cf" want false "not-a-fingerprint" 2>/dev/null; then fail "committed-keys=false with a malformed fingerprint was accepted"; fi
"$cf" want false "$KEY" || fail "committed-keys=false with a fingerprint was refused"
"$cf" want true "" || fail "the default (committed keys) must not need a fingerprint"

case "${1:?usage: channel-profile.sh rpm|deb}" in
rpm)
    mkdir -p "$work/src" && printf '%s\n' 'Name: pkg-a' 'Version: 1' 'Release: 1.fc44' 'Summary: t' 'License: MIT' \
        'BuildArch: noarch' '%description' 't' '%files' > "$work/a.spec"
    rpmbuild -bb --quiet --define "_topdir $work/rb" "$work/a.spec" >/dev/null 2>&1
    find "$work/rb" -name '*.rpm' -exec cp {} "$work/src/" \;
    printf '%s\n' '[freereac]' 'name=FreeREAC' > "$work/freereac.repo"
    tree=$work/rpm
    KEY_FILE=RPM-GPG-KEY-freereac SERVED_KEYS_DIR=none REPO_FILE=$work/freereac.repo \
        "$actions/publish-rpms/publish-tree.sh" "$tree" "$work/src" "$KEY"
    [ "$(served "$tree/RPM-GPG-KEY-freereac")" = "$KEY " ] || fail "the key file serves $(served "$tree/RPM-GPG-KEY-freereac"), not only $KEY"
    [ ! -e "$tree/RPM-GPG-KEY-openmixer" ] || fail "an OpenMixer key file was written into the other channel"
    [ ! -e "$tree/openmixer.repo" ] || fail "openmixer.repo was written into the other channel"
    cmp "$tree/freereac.repo" "$work/freereac.repo" || fail "the tree does not serve the channel's repository file"
    # the default is still OpenMixer's, with the committed keys
    tree=$work/rpm-default
    SERVED_KEYS_DIR=$work/committed "$actions/publish-rpms/publish-tree.sh" "$tree" "$work/src" "$KEY"
    want=$(printf '%s\n' "$KEY" "$OTHER" | sort | tr '\n' ' ')
    [ "$(served "$tree/RPM-GPG-KEY-openmixer")" = "$want" ] || fail "the default key file serves $(served "$tree/RPM-GPG-KEY-openmixer"), want $want"
    ;;
deb)
    mkdir -p "$work/p/DEBIAN" "$work/src/trixie"
    printf '%s\n' 'Package: pkg-a' 'Version: 1' 'Architecture: all' 'Maintainer: t <t@example.org>' 'Description: t' > "$work/p/DEBIAN/control"
    dpkg-deb -b "$work/p" "$work/src/trixie/pkg-a_1_all.deb" >/dev/null
    tree=$work/deb
    KEY_FILE=freereac.asc SERVED_KEYS_DIR=none LABEL=FreeREAC "$actions/publish-debs/publish-tree.sh" "$tree" "$work/src" "$KEY"
    [ "$(served "$tree/freereac.asc")" = "$KEY " ] || fail "the key file serves $(served "$tree/freereac.asc"), not only $KEY"
    [ ! -e "$tree/openmixer.asc" ] || fail "an OpenMixer key file was written into the other channel"
    grep -q '^Origin: FreeREAC$' "$tree"/debian/trixie/*/Release || grep -q '^Origin: FreeREAC$' "$tree"/debian/trixie/Release ||
        fail "the Release files are not labelled FreeREAC"
    tree=$work/deb-default
    SERVED_KEYS_DIR=$work/committed "$actions/publish-debs/publish-tree.sh" "$tree" "$work/src" "$KEY"
    want=$(printf '%s\n' "$KEY" "$OTHER" | sort | tr '\n' ' ')
    [ "$(served "$tree/openmixer.asc")" = "$want" ] || fail "the default key file serves $(served "$tree/openmixer.asc"), want $want"
    ;;
esac
echo "channel-profile $1: ok"
