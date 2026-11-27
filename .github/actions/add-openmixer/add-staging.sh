#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Add the staging channel of the release wave beside the real one, at a higher priority, on a Fedora or Debian machine
# that already has the real channel (openmixer-release installed: the key is the one it installs). Runs as root.
#
#   BASE_URL=https://www.openmixer.org [SUITE=<debian release>] [STAGING_BOOTSTRAP=true] [STAGING_FOR_DEVEL=true] add-staging.sh
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
#
# STAGING_FOR_DEVEL=true (add-openmixer on a pull request into devel) refuses an absent staging channel by name before
# anything else, STAGING_BOOTSTRAP or not: such a run builds against staging and never falls back to the real channel.
# Whether staging is served is judged before the real channel's file is looked for, so that refusal (and the
# bootstrap skip) never depend on the machine; adding staging still requires the real channel beside it.
#
# LEVEL=devel/<wave> adds the devel channel of that wave instead (docs/release-operations.md, "The three channel
# levels"), above staging: dnf /etc/yum.repos.d/openmixer-devel.repo, ids openmixer-devel and openmixer-devel-noarch,
# priority=5; apt /etc/apt/sources.list.d/openmixer-devel.sources and the pin /etc/apt/preferences.d/openmixer-devel.pref,
# Pin-Priority 650 for the index labelled OpenMixer-Devel. The files are packaging/devel, the wave written in. A wave's
# tree that was never published (index and key both 404) is skipped with a notice whatever STAGING_BOOTSTRAP says: the
# first line of a wave builds before anything was published to it, and every later line reads what the earlier ones
# published. A tree that is published without this machine's index still fails. Only one wave is ever added.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
level=${LEVEL:-staging}
base=${BASE_URL:-https://www.openmixer.org}
base=${base%/}
die() { echo "add-staging: $*" >&2; exit 1; }
if [ "$level" = staging ]; then
    src=$here/../../../packaging/staging path=staging name=openmixer-staging what="the staging channel"
else
    wave=$("$here/../publish-rpms/channel-level.sh" wave "$level") || exit 1
    src=$here/../../../packaging/devel path=devel/$wave name=openmixer-devel what="the devel channel of $wave"
    # a wave's first line builds before its tree exists: an absent tree is skipped, never a fallback once it exists
    STAGING_BOOTSTRAP=true STAGING_FOR_DEVEL=false
fi

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
    # a pull request into devel builds against staging and nothing else (devel -> staging -> prod, .github#270)
    if [ "${STAGING_FOR_DEVEL:-false}" = true ]; then
        die "a pull request into devel builds against the staging channel, and $tree serves no staging repository (${absent[*]} answered 404): it never falls back to the real channel"
    fi
    if [ "${STAGING_BOOTSTRAP:-false}" != true ]; then
        die "${absent[*]} answered 404: the staging channel $tree serves no index for this machine. A staged build never falls back to the real channel; only the first layer of a wave, before anything was staged, passes staging-bootstrap: true"
    fi
    if [ "${#absent[@]}" -eq "$#" ] && ! served "$tree/$key"; then
        echo "add-staging: $what ($tree) has not been published yet (${absent[*]} and $tree/$key answered 404): nothing added, as staging-bootstrap asks; the first staged publish creates it"
        exit 0
    fi
    # a wave publishes the cells of its own matrix (OMX_DEVEL_MATRIX, a quick devel matrix): a machine whose cell the wave
    # never built finds no index of it at all, and reads staging, which the caller adds beside it (.github#331). An index
    # served for only part of this machine (its arch but not noarch) is still refused below.
    if [ "$level" != staging ] && [ "${#absent[@]}" -eq "$#" ]; then
        echo "add-staging: $what ($tree) is published but serves no index for this machine (${absent[*]} answered 404): the wave built no package for this cell, nothing added; this job reads staging and the real channel"
        exit 0
    fi
    die "${absent[*]} answered 404, but $what ($tree) is published: it is not added half-way, staging-bootstrap or not"
}
if command -v dnf >/dev/null; then
    # shellcheck disable=SC1091
    releasever=$(. /etc/os-release && echo "${VERSION_ID:-}")
    [ -n "$releasever" ] || die "/etc/os-release has no VERSION_ID: the Fedora release of the staging index is unknown"
    skip_if_never_published "$base/$path/rpm" RPM-GPG-KEY-openmixer \
        "$base/$path/rpm/fedora/$releasever/$(uname -m)/repodata/repomd.xml" "$base/$path/rpm/fedora/$releasever/noarch/repodata/repomd.xml"
    [ -f /etc/yum.repos.d/openmixer.repo ] || die "the real channel is not added (/etc/yum.repos.d/openmixer.repo): $what goes beside it, never alone"
    repo=$("$here/../publish-rpms/channel-level.sh" repo-file "$level" "$(mktemp -d)")
    sed "s|https://www.openmixer.org/|$base/|" "$repo" > "/etc/yum.repos.d/$name.repo"
    chmod 644 "/etc/yum.repos.d/$name.repo"
    echo "added $base/$path/rpm ($name, $name-noarch, priority $(sed -n 's/^priority=//p' "/etc/yum.repos.d/$name.repo" | head -1))"
else
    suite=${SUITE:-}
    # shellcheck disable=SC1091
    [ -n "$suite" ] || suite=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    [ -n "$suite" ] || die "no Debian release named, and /etc/os-release has no VERSION_CODENAME"
    skip_if_never_published "$base/$path/deb" openmixer.asc "$base/$path/deb/debian/$suite/InRelease"
    [ -f /etc/apt/sources.list.d/openmixer.sources ] || die "the real channel is not added (/etc/apt/sources.list.d/openmixer.sources): $what goes beside it, never alone"
    sed -e "s|@SUITE@|$suite|" -e "s|@WAVE@|${wave:-}|" -e "s|https://www.openmixer.org/|$base/|" "$src/$name.sources.in" \
        > "/etc/apt/sources.list.d/$name.sources"
    install -D -m 644 "$src/$name.pref" "/etc/apt/preferences.d/$name.pref"
    chmod 644 "/etc/apt/sources.list.d/$name.sources"
    echo "added $base/$path/deb/debian/$suite (pinned $(sed -n 's/^Pin-Priority: //p' "$src/$name.pref"))"
fi
