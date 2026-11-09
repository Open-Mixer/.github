#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The two release checks prove themselves on planted inputs (a caller short of a permission its shared workflow asks
# for; an empty or missing secret; a secret-to-secret fallback), and every workflow here is free of a fallback.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/.github/actions/release-permissions-check/selftest.sh"
"$here/.github/actions/secrets-check/selftest.sh"
if grep -rnE --exclude-dir=secrets-check 'secrets\.[A-Za-z0-9_]+[[:space:]]*\|\|' "$here/.github" "$here/docs" 2>/dev/null; then
  echo "FAIL a workflow falls back from one secret to another"; exit 1
fi
echo "ok   no workflow of this repository falls back between secrets"
