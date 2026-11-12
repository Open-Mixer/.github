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
set -euo pipefail
src=$(dirname "$(readlink -f "$0")")/../../../packaging/staging
base=${BASE_URL:-https://www.openmixer.org}
base=${base%/}
die() { echo "add-staging: $*" >&2; exit 1; }
if command -v dnf >/dev/null; then
    [ -f /etc/yum.repos.d/openmixer.repo ] || die "the real channel is not added (/etc/yum.repos.d/openmixer.repo): staging goes beside it, never alone"
    sed "s|https://www.openmixer.org/|$base/|" "$src/openmixer-staging.repo" > /etc/yum.repos.d/openmixer-staging.repo
    chmod 644 /etc/yum.repos.d/openmixer-staging.repo
    echo "added $base/staging/rpm (openmixer-staging, openmixer-staging-noarch, priority 10)"
else
    [ -f /etc/apt/sources.list.d/openmixer.sources ] || die "the real channel is not added (/etc/apt/sources.list.d/openmixer.sources): staging goes beside it, never alone"
    suite=${SUITE:-}
    # shellcheck disable=SC1091
    [ -n "$suite" ] || suite=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    [ -n "$suite" ] || die "no Debian release named, and /etc/os-release has no VERSION_CODENAME"
    sed -e "s|@SUITE@|$suite|" -e "s|https://www.openmixer.org/|$base/|" "$src/openmixer-staging.sources.in" \
        > /etc/apt/sources.list.d/openmixer-staging.sources
    install -D -m 644 "$src/openmixer-staging.pref" /etc/apt/preferences.d/openmixer-staging.pref
    chmod 644 /etc/apt/sources.list.d/openmixer-staging.sources
    echo "added $base/staging/deb/debian/$suite (pinned 600)"
fi
