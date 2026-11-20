#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# trigger-gate: no workflow but the one lint runs on push, pull_request, pull_request_target or merge_group.
#
#   check.sh --lint FILE [ROOT]   the check over ROOT/.github/workflows/*.yml (ROOT default: the current directory)
#   check.sh --self-test          each planted failure must go red, each allowed shape green
#
# The exception mechanism is the --lint argument (the action's `lint-workflow` input): the file name of the
# repository's one lint workflow. That file may carry any trigger. Every other workflow is refused when it has
#   push: with branches, branches-ignore, paths, paths-ignore, no filter at all, or a tags-ignore without tags;
#   pull_request, pull_request_target, merge_group: always.
# A push that names `tags:` and no branch or path filter is the release and passes. workflow_dispatch, workflow_call,
# schedule, repository_dispatch, release and the rest pass.
# Output: one `TRIGGER-REFUSED <file>: <trigger>` per refusal then a summary line and exit 1; clean prints
# `TRIGGER-GATE OK <n> workflows`. Reading no workflow is a failure, and so is a file that does not parse.
set -euo pipefail

gate() {  # gate <lint-file> <root>
  python3 - "$1" "$2" <<'PY'
import glob, os, sys
try:
    import yaml
except ImportError:
    print("TRIGGER-GATE ERROR: python3 yaml is not installed"); sys.exit(2)
lint, root = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml")) + glob.glob(os.path.join(root, ".github/workflows/*.yaml")))
if not files:
    print("TRIGGER-GATE ERROR: no workflow under %s/.github/workflows" % root); sys.exit(2)
BAD = ("pull_request", "pull_request_target", "merge_group")
refused = []
bad_parse = False
for f in files:
    name = os.path.basename(f)
    try:
        doc = yaml.safe_load(open(f))
    except Exception as e:
        print("TRIGGER-GATE ERROR: %s does not parse: %s" % (name, str(e).splitlines()[0])); bad_parse = True; continue
    if not isinstance(doc, dict):
        print("TRIGGER-GATE ERROR: %s is not a mapping" % name); bad_parse = True; continue
    # PyYAML reads the key `on` as boolean True
    on = doc["on"] if "on" in doc else doc.get(True)
    if name == lint:
        continue
    if on is None:
        trig = {}
    elif isinstance(on, str):
        trig = {on: None}
    elif isinstance(on, list):
        trig = {t: None for t in on}
    else:
        trig = on
    for t in BAD:
        if t in trig:
            refused.append((name, t))
    if "push" in trig:
        p = trig["push"]
        tags_only = isinstance(p, dict) and p.get("tags") and not any(k in p for k in ("branches", "branches-ignore", "paths", "paths-ignore"))
        if not tags_only:
            refused.append((name, "push"))
if bad_parse:
    sys.exit(2)
if lint not in [os.path.basename(f) for f in files]:
    print("TRIGGER-GATE ERROR: lint workflow %s not found" % lint); sys.exit(2)
for n, t in refused:
    print("TRIGGER-REFUSED %s: %s" % (n, t))
if refused:
    print("TRIGGER-GATE REFUSED %d trigger(s) in %d of %d workflows" % (len(refused), len({n for n, _ in refused}), len(files)))
    sys.exit(1)
print("TRIGGER-GATE OK %d workflows" % len(files))
PY
}

self_test() {
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/.github/workflows"
  local w="$t/.github/workflows"
  expect() {  # expect <rc> <label>
    local rc=0; gate lint.yml "$t" >"$t/out" 2>&1 || rc=$?
    [ "$rc" = "$1" ] || { echo "self-test FAILED: $2 (rc $rc, wanted $1)"; cat "$t/out"; exit 1; }
  }
  printf 'on:\n  pull_request:\njobs: {}\n' > "$w/lint.yml"
  printf 'on:\n  push:\n    tags: ["v*"]\njobs: {}\n' > "$w/rel.yml"
  expect 0 "tag-only push and the named lint's pull_request"
  printf 'on: [workflow_dispatch, workflow_call, schedule, repository_dispatch, release]\njobs: {}\n' > "$w/other.yml"
  expect 0 "workflow_dispatch and the other allowed triggers"
  printf 'on:\n  pull_request:\njobs: {}\n' > "$w/pr.yml"
  expect 1 "pull_request on a workflow that is not the lint"; rm "$w/pr.yml"
  printf 'on:\n  push:\n    branches: [main]\njobs: {}\n' > "$w/pb.yml"
  expect 1 "push with branches"; rm "$w/pb.yml"
  printf 'on: push\njobs: {}\n' > "$w/ps.yml"
  expect 1 "push with no filter"; rm "$w/ps.yml"
  printf 'on:\n  push:\n    tags: ["v*"]\n    paths: ["a"]\njobs: {}\n' > "$w/pp.yml"
  expect 1 "push with tags and paths"; rm "$w/pp.yml"
  printf 'on:\n  merge_group:\njobs: {}\n' > "$w/mg.yml"
  expect 1 "merge_group"; rm "$w/mg.yml"
  printf 'on:\n  pull_request_target:\njobs: {}\n' > "$w/prt.yml"
  expect 1 "pull_request_target"; rm "$w/prt.yml"
  # sabotage: the tag-only release gains a branch filter and must go red
  printf 'on:\n  push:\n    tags: ["v*"]\n    branches: [main]\njobs: {}\n' > "$w/rel.yml"
  expect 1 "sabotage: tag-only fixture given push branches"
  echo "trigger-gate self-test OK"
}

case "${1:-}" in
  --self-test) self_test ;;
  --lint) [ -n "${2:-}" ] || { echo "usage: check.sh --lint FILE [ROOT]" >&2; exit 2; }; gate "$2" "${3:-.}" ;;
  *) echo "usage: check.sh --lint FILE [ROOT] | --self-test" >&2; exit 2 ;;
esac
