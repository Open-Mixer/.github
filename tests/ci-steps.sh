#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The ci-steps reader held to its table (arms.yml beside it): every row against the reader, and every row that is only
# a script against the real shell; then its sabotage rows, each a break the table must see. Then the reader on this
# repository's own workflow: this script runs and gates there, and a step that cannot run on the workflow's triggers is
# refused by name.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dir="$here/.github/actions/ci-steps"
python3 -I "$dir/arms.py"
python3 -I "$dir/arms.py" --sabotage > /dev/null
python3 -I "$dir/ci_steps.py" --require tests/ci-steps.sh "$here/.github/workflows/ci.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/w.yml" <<'YML'
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: nightly only
        if: github.event_name == 'schedule'
        run: tests/never-here.sh
YML
status=0
out=$(python3 -I "$dir/ci_steps.py" --require tests/never-here.sh "$work/w.yml") || status=$?
[ "$status" = 1 ] || { echo "a step that cannot run on the workflow's triggers was not refused (exit $status)" >&2; exit 1; }
case "$out" in
  *"step 1"*"github.event_name == 'schedule'"*"false on every trigger"*) ;;
  *) echo "the refusal does not name the step and its condition: $out" >&2; exit 1 ;;
esac
