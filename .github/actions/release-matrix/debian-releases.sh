#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# debian-releases.sh <release>...: exit 0 when every Debian release named is in the full matrix (full.txt beside this
# file, the one place the Debian releases are written), else name the first one outside it and exit 2. Debian is trixie
# only (owner ruling 2026-11-28, "we don't do bookworm"): a retired release is refused by name, never built, promoted or
# purged. One refusal for every door that takes a list of Debian releases: matrix.sh (build-deb.yml's suite-matrix,
# check-matrix's deb-releases) and the debian-releases action (promote-staged, purge-staging and promote-wave).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
for rel in "$@"; do
    awk -v r="$rel" '$1 == "deb" && $2 == r { f = 1 } END { exit !f }' "$here/full.txt" || {
        echo "::error::Debian release '$rel' is not in the full matrix (release-matrix/full.txt: $(awk '$1 == "deb" { print $2 }' "$here/full.txt" | sort -u | xargs), the only Debian releases built: owner ruling 2026-11-28)" >&2
        exit 2
    }
done
