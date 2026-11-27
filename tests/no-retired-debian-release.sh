#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# No release for Debian bookworm (owner ruling 2026-11-16), and bookworm dropped from the matrix altogether (owner
# 2026-11-27), offline. Nothing that builds, signs, publishes, checks or keeps a package for bookworm may name it: no
# non-comment line of a workflow, of the release-matrix or check-matrix action, of the quick set, of the keep-list
# generator or of the keep-list carries the word, so the prune's plan keeps no bookworm file. release-matrix/frozen.txt
# keeps its bookworm line until the prune has taken the suite's files (a promotion must not hold a served suite against
# its matrix meanwhile); the openmixer-release apt source is a reader. Neither is scanned here.
# Positive control: a bookworm put back into a copy of a workflow, into quick.txt and into the keep-list generator
# each go red, and the frozen exemption reaches no other file.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

scan() { # <root>: print every offending line
  local root=$1 f
  for f in "$root"/workflows/*.yml "$root"/actions/release-matrix/* "$root"/actions/check-matrix/* \
      "$root"/../channel/gen-keep-list.mjs "$root"/../channel/keep-list.txt; do
    [ -f "$f" ] || continue
    [ "${f##*/}" = frozen.txt ] && continue  # served until the prune takes it, never built (above)
    grep -nHi 'bookworm' "$f" | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' || true
  done
}

hits=$(scan "$here/.github")
if [ -n "$hits" ]; then echo "$hits"; echo "FAIL a release or check matrix, or the keep-list, still names bookworm"; exit 1; fi
echo "ok   no workflow, release-matrix, check-matrix or keep-list line names bookworm"

mkdir -p "$t/s/workflows" "$t/s/actions" "$t/channel"
cp "$here"/.github/workflows/*.yml "$t/s/workflows/"; cp -r "$here/.github/actions/release-matrix" "$here/.github/actions/check-matrix" "$t/s/actions/"
cp "$here/channel/gen-keep-list.mjs" "$here/channel/keep-list.txt" "$t/channel/"
sed -i "0,/\"trixie\"/s//\"bookworm\", \"trixie\"/" "$t/s/workflows/clap-headers-deb.yml"
printf 'deb bookworm amd64\n' >> "$t/s/actions/release-matrix/quick.txt"
sed -i "s/\['trixie'\]\.map((s) =>/['bookworm', 'trixie'].map((s) =>/" "$t/channel/gen-keep-list.mjs"
for w in clap-headers-deb.yml quick.txt gen-keep-list.mjs; do
  scan "$t/s" | grep -q "$w:" || { echo "FAIL sabotage: a bookworm put back into $w is not seen"; exit 1; }
done
# the exemption is that one file by name: a bookworm in any other release-matrix file is still seen
printf 'deb bookworm\n' > "$t/s/actions/release-matrix/frozen-extra.txt"
scan "$t/s" | grep -q 'frozen-extra.txt' || { echo "FAIL sabotage: the frozen exemption reaches another file"; exit 1; }
echo "ok   sabotage: a bookworm put back into a workflow, quick.txt and the keep-list generator is red"
