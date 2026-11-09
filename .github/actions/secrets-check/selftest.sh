#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The checker against planted inputs: set secrets and a clean workflow are green; an empty secret, a missing secret and
# a secret-to-secret fallback are each red.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'jobs:\n  a:\n    steps:\n      - with: {k: "${{ secrets.TOKEN_A }}"}\n' > "$t/clean.yml"
printf 'jobs:\n  a:\n    steps:\n      - with: {k: "${{ secrets.TOKEN_A || secrets.TOKEN_B }}"}\n' > "$t/fallback.yml"
run() { SECRETS_JSON="$1" python3 -I "$here/check.py" "$2" "${@:3}" >/dev/null 2>&1; }
run '{"TOKEN_A":"x","TOKEN_B":"y"}' "TOKEN_A TOKEN_B" "$t/clean.yml" || { echo "FAIL set secrets are red"; exit 1; }
run '{"TOKEN_A":"x","TOKEN_B":""}' "TOKEN_A TOKEN_B" "$t/clean.yml" && { echo "FAIL an empty secret passes"; exit 1; }
run '{"TOKEN_A":"x"}' "TOKEN_A TOKEN_B" "$t/clean.yml" && { echo "FAIL a missing secret passes"; exit 1; }
run '{"TOKEN_A":"x"}' "TOKEN_A" "$t/fallback.yml" && { echo "FAIL a fallback passes"; exit 1; }
echo "ok   secrets-check proves itself"
