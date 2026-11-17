#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# resolve-base (.github/actions/resolve-base): the one base-resolution rule of every compare gate, proven on throwaway
# repositories: a local, remote and sha base resolve with their merge-base; a stale origin/main is fetched first and an
# unreachable remote is refused by name, never the stale copy; an empty base, no base, HEAD, origin/ and a ref at HEAD's
# own commit are refused by name; a depth-1 single-branch clone's missing base, its missing remote and shallow history
# with no merge-base are refused by name; and the fetch and the HEAD guard are each what catches its case (sabotage).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/.github/actions/resolve-base/resolve-base.sh" --self-test
