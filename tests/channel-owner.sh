#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A publish never places a package of one house organisation into the other's channel (.github#224), through the tree
# scripts every publish runs (publish-rpms/publish-tree.sh, publish-debs/publish-tree.sh, CHANNEL_REPO naming the channel):
#   - a FreeREAC package (URL or Homepage https://github.com/FreeREAC/...) into the OpenMixer channel is refused, nothing placed;
#   - the same package into FreeREAC's channel is placed;
#   - an OpenMixer package (https://www.openmixer.org) into FreeREAC's channel is refused;
#   - a run of FreeREAC (GITHUB_REPOSITORY_OWNER) publishing into the OpenMixer channel is refused, whatever the package;
#   - an upstream package (a URL of neither organisation) and an OpenMixer package go into the OpenMixer channel;
#   - a FreeREAC package the OpenMixer tree ALREADY serves does not stop a regeneration of that tree (the prune, the removal).
# Unsigned trees (no key): the guard runs before anything is signed. Needs rpm-build and createrepo_c (rpm), dpkg-dev and
# apt-utils (deb).
#
#   channel-owner.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
kind=${1:?usage: channel-owner.sh rpm|deb}
actions=$here/../.github/actions
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
export SERVED_KEYS_DIR=none

case $kind in
rpm)
    mk() { # <name> <url>
        local d=$w/rb-$1; mkdir -p "$d"
        printf '%s\n' "Name: $1" 'Version: 1.0' 'Release: 1.fc45' 'Summary: t' 'License: MIT' "URL: $2" 'BuildArch: noarch' \
            '%description' 't' '%files' > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1"
        mkdir -p "$w/src-$1"; cp "$(find "$d/RPMS" -name '*.rpm')" "$w/src-$1/"
    }
    pub() { "$actions/publish-rpms/publish-tree.sh" "$1" "$2"; }
    served() { find "$1" -name "$2-*.rpm" 2>/dev/null | grep -q .; }
    ;;
deb)
    mk() { # <name> <url>
        local d=$w/db-$1; mkdir -p "$d/DEBIAN" "$w/src-$1/trixie"
        printf '%s\n' "Package: $1" 'Version: 1.0' 'Architecture: all' 'Maintainer: t <t@example.org>' "Homepage: $2" 'Description: t' > "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$w/src-$1/trixie/$1_1.0_all.deb" >/dev/null
    }
    pub() { LABEL=Test "$actions/publish-debs/publish-tree.sh" "$1" "$2"; }
    served() { find "$1" -name "$2_*.deb" 2>/dev/null | grep -q .; }
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
mk libfr https://github.com/FreeREAC/libfr
mk omx-thing https://www.openmixer.org
mk upstream-thing https://github.com/free-audio/clap

# <expect 0|1> <channel> <tree> <package> [caller owner]
try() {
    local rc=0
    CHANNEL_REPO=$2 GITHUB_REPOSITORY_OWNER=${5:-} pub "$3" "$w/src-$4" > "$w/out" 2>&1 || rc=$?
    if [ "$1" = 0 ] && [ "$rc" != 0 ]; then cat "$w/out"; return 1; fi
    if [ "$1" = 1 ] && [ "$rc" = 0 ]; then return 1; fi
    return 0
}
om=Open-Mixer/open-mixer.github.io fr=FreeREAC/freereac.github.io

try 1 "$om" "$w/om" libfr || fail "a FreeREAC package was published into the OpenMixer channel"
grep -q 'is a package of freereac' "$w/out" || fail "the refusal does not name the organisation: $(cat "$w/out")"
! served "$w/om" libfr || fail "the refused FreeREAC package was placed"
ok "$kind: a FreeREAC package into the OpenMixer channel is refused, nothing placed"

try 0 "$fr" "$w/fr" libfr || fail "a FreeREAC package was refused by FreeREAC's channel"
served "$w/fr" libfr || fail "the FreeREAC package is not in FreeREAC's channel"
ok "$kind: the same package goes into FreeREAC's channel"

try 1 "$fr" "$w/fr2" omx-thing || fail "an OpenMixer package was published into FreeREAC's channel"
ok "$kind: an OpenMixer package into FreeREAC's channel is refused"

try 1 "$om" "$w/om" upstream-thing FreeREAC || fail "a run of FreeREAC published into the OpenMixer channel"
grep -q 'a run of FreeREAC publishes into' "$w/out" || fail "the caller refusal does not say so: $(cat "$w/out")"
ok "$kind: a run of FreeREAC publishing into the OpenMixer channel is refused"

try 0 "$om" "$w/om" upstream-thing Open-Mixer || fail "an upstream package was refused by the OpenMixer channel"
try 0 "$om" "$w/om" omx-thing Open-Mixer || fail "an OpenMixer package was refused by the OpenMixer channel"
ok "$kind: an upstream package and an OpenMixer package go into the OpenMixer channel"

# a tree that already serves a FreeREAC package (the state the removal fixes) is regenerated without a refusal
cp -r "$w/fr/." "$w/om/"
try 0 "$om" "$w/om" omx-thing Open-Mixer || fail "a served FreeREAC package stopped a regeneration of the OpenMixer tree"
ok "$kind: a FreeREAC package the tree already serves does not stop its regeneration"
echo "channel-owner $kind: ok"
