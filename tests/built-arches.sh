#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# built-arches.sh names the architectures a dry run built, so its installability check does not judge an architecture
# it did not build (omx-plugins 0.19.2: an x86_64-only dry run put the noarch contract 0.19.2 beside the published
# aarch64 0.19.1, pinned to contract 0.19.1, and the dry run was red on a break the release does not make).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ba=$here/.github/actions/channel-installability/built-arches.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
check() { # label want kind dir
  local got; got=$("$ba" "$3" "$4")
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: '$got', want '$2'"; fail=1; fi
}
mkdir -p "$t/rpm/sub" "$t/deb/trixie" "$t/noarch" "$t/both"
touch "$t/rpm/omx-plugins-0.19.2-1.git03ded2e1.fc44.x86_64.rpm" "$t/rpm/sub/omx-plugins-0.19.2-1.fc45.x86_64.rpm" \
      "$t/rpm/omx-plugins-contract-0.19.2-1.fc44.noarch.rpm" "$t/rpm/omx-plugins-0.19.2-1.fc44.src.rpm"
check "rpm: x86_64 only, noarch and src ignored" "x86_64" rpm "$t/rpm"
touch "$t/deb/trixie/omx-plugins-lv2_0.19.2-1_amd64.deb" "$t/deb/trixie/omx-plugins-contract_0.19.2-1_all.deb"
check "deb: amd64 only, all ignored" "amd64" deb "$t/deb"
touch "$t/noarch/x-contract-1.0-1.fc44.noarch.rpm"
check "rpm: only noarch names no architecture" "" rpm "$t/noarch"
touch "$t/both/a-1-1.fc44.x86_64.rpm" "$t/both/a-1-1.fc44.aarch64.rpm"
check "rpm: a full build names both" "aarch64 x86_64" rpm "$t/both"
rc=0; "$ba" tar "$t/rpm" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 2 ]; then echo "ok   an unknown kind exits 2"; else echo "FAIL an unknown kind: exit $rc, want 2"; fail=1; fi
exit $fail
