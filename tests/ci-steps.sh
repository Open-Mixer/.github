#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The ci-steps reader held to its table (arms.yml beside it): every row against the reader, and every row that is only
# a script against the real shell. Then the reader on this repository's own workflow: this script runs and gates there.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$here/.github/actions/ci-steps/arms.py"
python3 -I "$here/.github/actions/ci-steps/ci_steps.py" --require tests/ci-steps.sh "$here/.github/workflows/ci.yml"
