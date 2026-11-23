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

# --on (.github#124): a workflow none of the named events can start runs nothing on them; a command there is refused by
# name, with the workflow's own on:. Without --on nothing changes; a workflow that an asked event starts passes.
req_on() { # req_on <want exit> <what> <on:> [--on EVENT...]: tests/x.sh, written in a workflow with that on:
  local want=$1 what=$2 on=$3 st=0; shift 3
  printf 'on: %s\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: tests/x.sh\n' "$on" > "$work/o.yml"
  out=$(python3 -I "$dir/ci_steps.py" "$@" --require tests/x.sh "$work/o.yml") || st=$?
  [ "$st" = "$want" ] || { echo "--on: $what: exit $st, want $want: $out" >&2; exit 1; }
}
req_on 1 "a dispatch-only workflow, --on pull_request" workflow_dispatch --on pull_request
case "$out" in *"step 1"*"on: workflow_dispatch"*) ;; *) echo "--on: the refusal does not name the step and the workflow's on: $out" >&2; exit 1 ;; esac
req_on 1 "a schedule-only workflow, --on push --on pull_request" "{schedule: [{cron: '0 3 * * *'}]}" --on push --on pull_request
case "$out" in *"on: schedule"*) ;; *) echo "--on: the schedule refusal does not show the on: $out" >&2; exit 1 ;; esac
req_on 0 "a dispatch-only workflow, no --on (nothing changes)" workflow_dispatch
req_on 0 "a push and pull_request workflow, --on pull_request" "[push, pull_request]" --on pull_request
req_on 0 "a reusable workflow (its events are the caller's), --on pull_request" "{workflow_call: {}}" --on pull_request
echo "ci-steps --on: a workflow no named event starts is refused by name; without --on, or started by one, it passes"
# the action passes its events input as --on: its own run script, on the dispatch-only workflow
python3 -I - "$dir/action.yml" > "$work/action.sh" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])
PY
printf 'on: workflow_dispatch\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: tests/x.sh\n' > "$work/o.yml"
act() { GITHUB_ACTION_PATH=$dir GITHUB_WORKSPACE=$work WORKFLOWS=o.yml REQUIRE=tests/x.sh CONDITIONAL=false EVENTS=$1 bash "$work/action.sh" > /dev/null 2>&1; }
if act 'pull_request push'; then echo "the action's events input does not reach --on" >&2; exit 1; fi
act '' || { echo "the action with no events refuses a dispatch-only workflow" >&2; exit 1; }
echo "ci-steps action: events reaches --on; empty, the triggers are not asked"
