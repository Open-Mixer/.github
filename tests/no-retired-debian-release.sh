#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# No release for Debian bookworm (owner ruling 2026-11-16), offline. Nothing that builds, signs, publishes or checks a
# package for bookworm may name it: no non-comment line of a workflow, of the release-matrix or check-matrix action or
# of the quick set carries the word. What is already published stays served (channel/keep-list.txt, the prune, the
# channel index and the openmixer-release apt source are readers of it and are not scanned here).
# Positive control: a bookworm put back into a copy of a workflow, and into quick.txt, each go red.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

scan() { # <root>: print every offending line
  local root=$1 f
  for f in "$root"/workflows/*.yml "$root"/actions/release-matrix/* "$root"/actions/check-matrix/*; do
    [ -f "$f" ] || continue
    grep -nHi 'bookworm' "$f" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true
  done
}

hits=$(scan "$here/.github")
if [ -n "$hits" ]; then echo "$hits"; echo "FAIL a release or check matrix still names bookworm"; exit 1; fi
echo "ok   no workflow, release-matrix or check-matrix line names bookworm"

mkdir -p "$t/s/workflows" "$t/s/actions"
cp "$here"/.github/workflows/*.yml "$t/s/workflows/"; cp -r "$here/.github/actions/release-matrix" "$here/.github/actions/check-matrix" "$t/s/actions/"
sed -i "0,/\"trixie\"/s//\"bookworm\", \"trixie\"/" "$t/s/workflows/clap-headers-deb.yml"
printf 'deb bookworm amd64\n' >> "$t/s/actions/release-matrix/quick.txt"
[ "$(scan "$t/s" | wc -l)" -ge 2 ] || { echo "FAIL sabotage: a bookworm put back is not seen"; exit 1; }
echo "ok   sabotage: a bookworm put back into a workflow and into quick.txt is red"
