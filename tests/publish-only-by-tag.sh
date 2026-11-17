#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Publish only by tagging (docs/release-operations.md): the gate reads what every step of every workflow and composite
# action DOES and fails by file, job and step on a publish that is not guarded by the tag condition. It proves itself on
# planted trees first (every way of publishing it must see red, the guarded ones green). Argument: a repository root.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$here/tests/publish_only_by_tag.py" --selftest
python3 -I "$here/tests/publish_only_by_tag.py" "${1:-$here}"
