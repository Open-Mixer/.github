#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# run.sh deb|rpm <packages dir> [<channel>]: the channel-installability gate in a Debian (deb) or Fedora (rpm)
# container, its tools installed when missing. <channel> is the deb/ or rpm/ tree, served (a URL) or pulled (a
# directory); empty is the served channel at BASE_URL. The environment narrows it: SUITES (Debian releases),
# FEDORA_VERSIONS, ARCHES, all space separated and empty for what the channel serves and the release brings, and
# SAME_PASS, the packages other repositories release in the same pass. UNBUILT_ARCH_PASS=true (a dry run, which builds one
# architecture) counts, on an architecture it built nothing for, the binary packages it built on another as released in
# the same pass. Exit 0 green, 1 red, 2 not measured.
set -euo pipefail
kind=$1 dir=$2 channel=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
base=${BASE_URL:-https://www.openmixer.org}
[ -n "$channel" ] || channel=$base/$kind
args=("$kind" --channel "$channel" --new-dir "$dir" --same-pass "${SAME_PASS:-}")
for a in ${ARCHES:-}; do args+=(--arch "$a"); done
[ "${UNBUILT_ARCH_PASS:-}" != true ] || args+=(--unbuilt-arch-pass)
case $kind in
  deb)
    if ! command -v dose-debcheck >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
      apt-get update -qq
      apt-get install -y --no-install-recommends dose-distcheck python3 python3-yaml dpkg-dev ca-certificates >/dev/null
    fi
    for s in ${SUITES:-}; do args+=(--suite "$s"); done ;;
  rpm)
    if ! dnf repoclosure --help >/dev/null 2>&1 || ! command -v createrepo_c >/dev/null || ! command -v python3 >/dev/null; then
      dnf install -y -q --setopt=install_weak_deps=False dnf5-plugins createrepo_c python3 >/dev/null
    fi
    for v in ${FEDORA_VERSIONS:-}; do args+=(--fedora "$v"); done ;;
  *) echo "run.sh: deb or rpm, not '$kind'" >&2; exit 2 ;;
esac
exec nice -n 10 python3 -I "$here/gate.py" "${args[@]}"
