#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# No release for Debian bookworm (owner ruling 2026-11-16), bookworm dropped from the matrix (owner 2026-11-27), and
# Debian trixie only (owner ruling 2026-11-28), offline, for this repository. The workflows, the actions (the
# release-matrix and check-matrix among them) and the packaging are read by the one shared check, retired-debian-check, the
# same every caller runs from public-sources-check (tests/retired-debian-check.sh proves it); this file adds what only this
# repository has, the keep-list generator and the keep-list, so the prune's plan keeps no bookworm file.
# release-matrix/frozen.txt keeps its bookworm line, exempt by path in the shared check: a promotion must not hold a
# served suite against its matrix.
# Positive control: a bookworm put back into a copy of a workflow, into quick.txt and into the keep-list generator
# each go red, and the frozen exemption reaches no other file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
chk=$here/.github/actions/retired-debian-check/retired-debian-check.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

scan() { # <root>: print every offending line of the tree, the shared check and the keep-list files
  local root=$1 f
  "$chk" "$root" 2>/dev/null | grep -E '^[^ ]+:[0-9]+: ' || true
  for f in "$root"/channel/gen-keep-list.mjs "$root"/channel/keep-list.txt; do
    [ -f "$f" ] || continue
    grep -nHi 'bookworm' "$f" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' || true
  done
}

hits=$(scan "$here")
if [ -n "$hits" ]; then echo "$hits"; echo "FAIL a workflow, action, packaging line or the keep-list still names bookworm"; exit 1; fi
echo "ok   no workflow, action, packaging or keep-list line names bookworm"

mkdir -p "$t/s/.github" "$t/s/channel"
cp -r "$here/.github/workflows" "$here/.github/actions" "$t/s/.github/"
cp "$here/channel/gen-keep-list.mjs" "$here/channel/keep-list.txt" "$t/s/channel/"
sed -i "0,/\"trixie\"/s//\"bookworm\", \"trixie\"/" "$t/s/.github/workflows/clap-headers-deb.yml"
printf 'deb bookworm amd64\n' >> "$t/s/.github/actions/release-matrix/quick.txt"
sed -i "s/\['trixie'\]\.map((s) =>/['bookworm', 'trixie'].map((s) =>/" "$t/s/channel/gen-keep-list.mjs"
for w in clap-headers-deb.yml quick.txt gen-keep-list.mjs; do
  scan "$t/s" | grep -q "$w:" || { echo "FAIL sabotage: a bookworm put back into $w is not seen"; exit 1; }
done
# the exemption is that one file by name: a bookworm in any other release-matrix file is still seen
printf 'deb bookworm\n' > "$t/s/.github/actions/release-matrix/frozen-extra.txt"
scan "$t/s" | grep -q 'frozen-extra.txt' || { echo "FAIL sabotage: the frozen exemption reaches another file"; exit 1; }
echo "ok   sabotage: a bookworm put back into a workflow, quick.txt and the keep-list generator is red"
