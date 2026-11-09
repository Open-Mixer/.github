#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The checker against planted callers: complete is green; each missing permission, a read where write is needed, and
# no block at all are red.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mk() { printf 'on: push\n%sjobs:\n  release:\n%s    uses: FreeMixer/.github/.github/workflows/release-c-lib.yml@v1\n' "$1" "$2" > "$t/$3"; }
mk $'permissions: {contents: write, issues: write, actions: read}\n' '' ok.yml
mk $'permissions: {contents: write, actions: read}\n' '' no-issues.yml
mk $'permissions: {contents: write, issues: write, actions: read}\n' $'    permissions: {contents: read}\n' job-narrows.yml
mk $'permissions: {contents: read, issues: write, actions: read}\n' '' read-only.yml
mk '' '' none.yml
python3 -I "$here/check.py" "$t/ok.yml" >/dev/null || { echo "FAIL a complete caller is red"; exit 1; }
for f in no-issues job-narrows read-only none; do
  if python3 -I "$here/check.py" "$t/$f.yml" >/dev/null 2>&1; then echo "FAIL $f passes"; exit 1; fi
done
echo "ok   release-permissions-check proves itself"
