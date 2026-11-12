#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Add the staging channel of the release wave beside the real one, at a higher priority, on a Fedora or Debian machine
# that already has the real channel (openmixer-release installed: the key is the one it installs). Runs as root.
#
#   BASE_URL=https://www.openmixer.org [SUITE=<debian release>] add-staging.sh
#
# dnf: /etc/yum.repos.d/openmixer-staging.repo, ids openmixer-staging and openmixer-staging-noarch, priority=10 (the
# real repositories keep dnf's default, 99). apt: /etc/apt/sources.list.d/openmixer-staging.sources and the pin
# /etc/apt/preferences.d/openmixer-staging.pref, Pin-Priority 600 for the index labelled OpenMixer-Staging (the real
# channel stays at 500). The files are packaging/staging of this repository; BASE_URL replaces the host in them.
# The repository ids start with "openmixer" on purpose: channel-installability disables every system repository whose
# id does, so the gate keeps judging the real channel alone on a machine that has staging added.
#
# A STAGING CHANNEL NEVER PUBLISHED IS SKIPPED, NOTHING ELSE IS. The first staged publish of the channel creates the
# staging tree (the index of every release of its matrix, the key); before it, the staging URLs answer 404, and the
# build job of that very first staged run adds staging before its publish. So when this machine's staging index AND
# the staging key file both answer 404 (or are missing, for a file:// channel), nothing is added, the script says so
# and exits 0: there is nothing staged to take. Anything else is added as it is and loaded strictly by the caller: a
# staging tree that exists without this release's index fails here, and a bad signature fails dnf or apt, as before.
set -euo pipefail
src=$(dirname "$(readlink -f "$0")")/../../../packaging/staging
base=${BASE_URL:-https://www.openmixer.org}
base=${base%/}
die() { echo "add-staging: $*" >&2; exit 1; }

# 0 when <url> is served, 1 when it answers 404 (a missing file, for file://); anything else stops the script
served() {
    local url=$1 status
    case $url in
        file://*) [ -e "${url#file://}" ]; return ;;
    esac
    command -v curl >/dev/null || die "curl is not installed: cannot tell whether the staging channel is published"
    status=$(curl -s -o /dev/null -w '%{http_code}' --retry 5 --retry-delay 3 --connect-timeout 20 "$url" || true)
    case $status in
        200) return 0 ;;
        404) return 1 ;;
        *) die "$url answered '${status:-nothing}', neither served nor absent: the staging channel cannot be judged" ;;
    esac
}
# <tree> <key file> <index url>...: exits 0 having added nothing when the staging tree was never published
skip_if_never_published() {
    local tree=$1 key=$2 url missing=0
    shift 2
    for url in "$@"; do served "$url" || missing=$((missing + 1)); done
    [ "$missing" -gt 0 ] || return 0
    if [ "$missing" -eq "$#" ] && ! served "$tree/$key"; then
        echo "add-staging: the staging channel $tree has not been published yet (no index, no key): nothing added; the first staged publish creates it"
        exit 0
    fi
    die "the staging channel $tree is published but serves no index at $* for this machine: it is not added half-way"
}
if command -v dnf >/dev/null; then
    [ -f /etc/yum.repos.d/openmixer.repo ] || die "the real channel is not added (/etc/yum.repos.d/openmixer.repo): staging goes beside it, never alone"
    # shellcheck disable=SC1091
    releasever=$(. /etc/os-release && echo "${VERSION_ID:-}")
    [ -n "$releasever" ] || die "/etc/os-release has no VERSION_ID: the Fedora release of the staging index is unknown"
    skip_if_never_published "$base/staging/rpm" RPM-GPG-KEY-openmixer \
        "$base/staging/rpm/fedora/$releasever/$(uname -m)/repodata/repomd.xml" "$base/staging/rpm/fedora/$releasever/noarch/repodata/repomd.xml"
    sed "s|https://www.openmixer.org/|$base/|" "$src/openmixer-staging.repo" > /etc/yum.repos.d/openmixer-staging.repo
    chmod 644 /etc/yum.repos.d/openmixer-staging.repo
    echo "added $base/staging/rpm (openmixer-staging, openmixer-staging-noarch, priority 10)"
else
    [ -f /etc/apt/sources.list.d/openmixer.sources ] || die "the real channel is not added (/etc/apt/sources.list.d/openmixer.sources): staging goes beside it, never alone"
    suite=${SUITE:-}
    # shellcheck disable=SC1091
    [ -n "$suite" ] || suite=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    [ -n "$suite" ] || die "no Debian release named, and /etc/os-release has no VERSION_CODENAME"
    skip_if_never_published "$base/staging/deb" openmixer.asc "$base/staging/deb/debian/$suite/InRelease"
    sed -e "s|@SUITE@|$suite|" -e "s|https://www.openmixer.org/|$base/|" "$src/openmixer-staging.sources.in" \
        > /etc/apt/sources.list.d/openmixer-staging.sources
    install -D -m 644 "$src/openmixer-staging.pref" /etc/apt/preferences.d/openmixer-staging.pref
    chmod 644 /etc/apt/sources.list.d/openmixer-staging.sources
    echo "added $base/staging/deb/debian/$suite (pinned 600)"
fi
