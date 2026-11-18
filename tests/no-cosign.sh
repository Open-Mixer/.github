#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The deb index carries ONE signature, the packages key's: no workflow passes a cosign key, and neither
# publish-debs nor purge-staging (their actions and scripts) has a cosign input, import step or COSIGN path any
# more. Fails naming the file and line. ROOT names another checkout (the sabotage run reads an old tree).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=${ROOT:-$here/..}
bad=$(grep -rniE 'cosign|co-sign' "$root/.github/workflows" --exclude=ci.yml "$root/.github/actions/publish-debs" \
    "$root/.github/actions/purge-staging" || true)
if [ -n "$bad" ]; then
    echo "FAIL: a cosign path is left in the publish (the apt index could carry two signatures):" >&2
    echo "$bad" >&2
    exit 1
fi
echo "no-cosign: ok"
