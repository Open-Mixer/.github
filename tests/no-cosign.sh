#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The deb index carries ONE signature, the packages key's: no workflow hands publish-debs (or purge-staging) a
# cosign-key, the input that made the personal key co-sign Release.gpg and InRelease. Fails naming the file and line.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
bad=$(grep -rnE '^\s*cosign-(key|passphrase):\s*\S' "$here/../.github/workflows" || true)
if [ -n "$bad" ]; then
    echo "FAIL: a workflow passes a cosign key to the publish (the apt index would carry two signatures):" >&2
    echo "$bad" >&2
    exit 1
fi
echo "no-cosign: ok"
