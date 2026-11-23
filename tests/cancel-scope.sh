#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A superseded run is cancelled only on a pull request, never on a tag push, a dispatch or a release: every concurrency
# block of every workflow has no cancel-in-progress, a literal false, or one gated on github.event_name == 'pull_request'.
# Proves itself on planted blocks first (each way of cancelling a release run must see red). Argument: a repository root.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$here/tests/cancel_scope.py" --selftest
python3 -I "$here/tests/cancel_scope.py" "${1:-$here}"
