#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The trigger gate (delivery pipeline §12): its own self-test, then the gate over this repository's workflows.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/.github/actions/trigger-gate/check.sh" --self-test
