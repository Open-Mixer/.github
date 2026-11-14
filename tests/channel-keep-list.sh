#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# channel/keep-list.txt is generated (channel/gen-keep-list.mjs), never written by hand: the generator's readers
# are tested on fixtures, and the committed list must carry the generator's sum and a header source for every pin.
#   tests/channel-keep-list.sh          offline
#   tests/channel-keep-list.sh --live   also regenerates from the sources and fails if the committed list is stale
set -euo pipefail
cd "$(dirname "$0")/.."
node --test channel/test/*.test.mjs
if [ "${1:-}" = --live ]; then
	tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
	node channel/gen-keep-list.mjs --out "$tmp/keep-list.txt"  >/dev/null
	# the header names the commits read; the lines are what must agree
	diff <(grep -v '^#' channel/keep-list.txt) <(grep -v '^#' "$tmp/keep-list.txt") ||
		{ echo "channel/keep-list.txt is stale: run node channel/gen-keep-list.mjs" >&2; exit 1; }
fi
echo "channel keep-list ok"
