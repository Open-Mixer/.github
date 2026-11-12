#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Add the staging channel of the release wave beside the real one, at a higher priority, on a Fedora or Debian machine
# that already has the real channel (openmixer-release installed: the key is the one it installs). Runs as root.
#
#   BASE_URL=https://www.openmixer.org [SUITE=<debian release>] [STAGING_BOOTSTRAP=true] add-staging.sh
#
# dnf: /etc/yum.repos.d/openmixer-staging.repo, ids openmixer-staging and openmixer-staging-noarch, priority=10 (the
# real repositories keep dnf's default, 99). apt: /etc/apt/sources.list.d/openmixer-staging.sources and the pin
# /etc/apt/preferences.d/openmixer-staging.pref, Pin-Priority 600 for the index labelled OpenMixer-Staging (the real
# channel stays at 500). The files are packaging/staging of this repository; BASE_URL replaces the host in them.
# The repository ids start with "openmixer" on purpose: channel-installability disables every system repository whose
# id does, so the gate keeps judging the real channel alone on a machine that has staging added.
#
# STRICT BY DEFAULT. A staging index of this machine's release that answers 404 (or is missing, for a file:// channel)
# fails the script, naming the URL: a staged build that cannot reach staging must never build against the released
# dependency instead. The first staged publish of the channel creates the staging tree (the index of every release of
# its matrix, the key), so after it every index a machine reads is served.
#
# STAGING_BOOTSTRAP=true is the one exception, for the first layer of a wave, whose build job adds staging before
# anything was ever published to it: when this machine's staging index AND the staging key file both answer 404,
# nothing is added, the script says so and exits 0. Anything else still fails: a staging tree that exists without this
# release's index fails here, any status but 200 or 404 fails here, and a bad signature fails dnf or apt, as before.
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
# <tree> <key file> <index url>...: returns when every index is served; with STAGING_BOOTSTRAP=true, exits 0 having added
# nothing when the staging tree was never published; fails naming the URLs that answered 404 otherwise
skip_if_never_published() {
    local tree=$1 key=$2 url
    local -a absent=()
    shift 2
    for url in "$@"; do served "$url" || absent+=("$url"); done
    [ "${#absent[@]}" -gt 0 ] || return 0
    if [ "${STAGING_BOOTSTRAP:-false}" != true ]; then
        die "${absent[*]} answered 404: the staging channel $tree serves no index for this machine. A staged build never falls back to the real channel; only the first layer of a wave, before anything was staged, passes staging-bootstrap: true"
    fi
    if [ "${#absent[@]}" -eq "$#" ] && ! served "$tree/$key"; then
        echo "add-staging: the staging channel $tree has not been published yet (${absent[*]} and $tree/$key answered 404): nothing added, as staging-bootstrap asks; the first staged publish creates it"
        exit 0
    fi
    die "${absent[*]} answered 404, but the staging channel $tree is published: it is not added half-way, staging-bootstrap or not"
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
