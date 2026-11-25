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
#   push: with branches other than exactly [devel], branches-ignore, paths, paths-ignore, no filter at all, or a
#   tags-ignore without tags;
#   pull_request, pull_request_target, merge_group: always.
# A push that names `tags:`, `branches: [devel]` or both, and no other filter, is the release and passes: a merge to
# devel publishes its packages to the staging channel (owner, 2026-11-25; .github#289). workflow_dispatch, workflow_call,
# schedule, repository_dispatch, release and the rest pass.
# A caller's guard on a merge to devel that published nothing (.github#297) is checked too: an expression that reads
# needs.<job>.outputs.skipped, <job> calling build-rpm.yml or build-deb.yml, in any case and by dot or by index
# (needs['<job>']['outputs']['skipped']), compares it with the quoted string 'true' (== or !=, either side); any other comparison (true unquoted, "true", which is no string in GitHub's grammar) and an
# `if:` that tests it bare are refused, naming file, job and expression: the output is a string, and an unquoted true
# compares it with a boolean, so the guard never skips.
# Output: one `TRIGGER-REFUSED <file>: <trigger>` per refusal then a summary line and exit 1; clean prints
# `TRIGGER-GATE OK <n> workflows`. Reading no workflow is a failure, and so is a file that does not parse.
set -euo pipefail

gate() {  # gate <lint-file> <root>
  python3 - "$1" "$2" <<'PY'
import glob, os, re, sys
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
    # the skipped output of a build-rpm.yml / build-deb.yml call is compared with the quoted 'true' alone (.github#297)
    jobs = doc.get("jobs") if isinstance(doc.get("jobs"), dict) else {}
    calls = {j for j, b in jobs.items() if isinstance(b, dict) and re.search(r"/workflows/build-(rpm|deb)\.yml(@|$)", str(b.get("uses", "")))}
    if calls:
        # GitHub reads property names case-insensitively, by dot or by index: needs.RPM.Outputs.skipped,
        # needs['rpm'].outputs['skipped'] and needs['rpm']['outputs']['skipped'] are the same read
        def prop(n):
            return r"(?:\s*\.\s*%s\b|\s*\[\s*\x27%s\x27\s*\])" % (n, n)
        names = "|".join(re.escape(c) for c in sorted(calls))
        ref = re.compile(r"\bneeds" + prop("(?:%s)" % names) + prop("outputs") + prop("skipped"), re.IGNORECASE)
        def walk(node, job, key):
            if isinstance(node, dict):
                for k, v in node.items():
                    walk(v, job, k)
            elif isinstance(node, list):
                for v in node:
                    walk(v, job, key)
            elif isinstance(node, str):
                for m in ref.finditer(node):
                    # an operand: a quoted string (\x27 single, \x22 double) or a bare word
                    after = re.match(r"\s*(==|!=)\s*(\x27[^\x27]*\x27|\x22[^\x22]*\x22|[^\s)&|]+)", node[m.end():])
                    before = re.search(r"(\x27[^\x27]*\x27|\x22[^\x22]*\x22|[^\s(&|!]+)\s*(==|!=)\s*$", node[:m.start()])
                    operand = after.group(2) if after else before.group(1) if before else None
                    if operand == "'true'" or (operand is None and key != "if"):
                        continue
                    refused.append((name, "job %s: %s (compare outputs.skipped with the quoted 'true')" % (job, node.strip())))
        for j, b in jobs.items():
            walk(b, j, None)
    if "push" in trig:
        p = trig["push"]
        # the release: tags, and/or the branch devel itself (a merge to devel publishes to staging), no other filter
        release = isinstance(p, dict) and (p.get("tags") or p.get("branches") == ["devel"]) \
            and p.get("branches", ["devel"]) == ["devel"] and not any(k in p for k in ("branches-ignore", "paths", "paths-ignore"))
        if not release:
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
  # a merge to devel publishes to the staging channel (owner, 2026-11-25; .github#289): the release workflow's push
  # may name the branch devel beside its tags, and devel alone
  printf 'on:\n  push:\n    tags: ["v*"]\n    branches: [devel]\njobs: {}\n' > "$w/rel.yml"
  expect 0 "the release on tags and on a push to devel"
  printf 'on:\n  push:\n    branches: [devel]\njobs: {}\n' > "$w/rel.yml"
  expect 0 "a push to devel alone"
  printf 'on:\n  push:\n    tags: ["v*"]\n    branches: [devel, main]\njobs: {}\n' > "$w/rel.yml"
  expect 1 "a push to devel and to another branch"
  printf 'on:\n  push:\n    branches: ["dev*"]\njobs: {}\n' > "$w/rel.yml"
  expect 1 "a branch pattern that is not devel itself"
  printf 'on:\n  push:\n    branches: [devel]\n    paths: ["a"]\njobs: {}\n' > "$w/rel.yml"
  expect 1 "a push to devel with a paths filter"
  printf 'on:\n  push:\n    tags: ["v*"]\njobs: {}\n' > "$w/rel.yml"
  printf 'on: push\njobs: {}\n' > "$w/ps.yml"
  expect 1 "push with no filter"; rm "$w/ps.yml"
  printf 'on:\n  push:\n    tags: ["v*"]\n    paths: ["a"]\njobs: {}\n' > "$w/pp.yml"
  expect 1 "push with tags and paths"; rm "$w/pp.yml"
  printf 'on:\n  merge_group:\njobs: {}\n' > "$w/mg.yml"
  expect 1 "merge_group"; rm "$w/mg.yml"
  printf 'on:\n  pull_request_target:\njobs: {}\n' > "$w/prt.yml"
  expect 1 "pull_request_target"; rm "$w/prt.yml"
  # a caller's guard on a skipped merge to devel (.github#297) compares needs.<call>.outputs.skipped with the quoted
  # string 'true': GitHub's outputs are strings, so an unquoted true compares a string with a boolean and never skips
  sk() {  # sk <if expression>: a caller whose install check reads the skipped output of its build-rpm.yml call
    printf 'on: [workflow_dispatch]\njobs:\n  rpm:\n    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1\n  check:\n    needs: rpm\n    if: %s\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' "$1" > "$w/sk.yml"
  }
  sk "needs.rpm.outputs.skipped != 'true'"; expect 0 "a quoted guard on outputs.skipped"
  sk "\${{ 'true' == needs.rpm.outputs.skipped && false }}"; expect 0 "a quoted guard written the other way round"
  sk "needs.rpm.outputs.skipped != true"; expect 1 "an unquoted != true on outputs.skipped"
  grep -qF "TRIGGER-REFUSED sk.yml: job check: needs.rpm.outputs.skipped != true" "$t/out" || { echo "self-test FAILED: the unquoted guard is not named with file, job and expression"; cat "$t/out"; exit 1; }
  sk "needs.rpm.outputs.skipped == true"; expect 1 "an unquoted == true on outputs.skipped"
  # GitHub's expression grammar has single-quoted strings only: "true" is not a string literal there (actionlint
  # refuses it as well)
  sk "needs.rpm.outputs.skipped != \"true\""; expect 1 "a double-quoted \"true\" on outputs.skipped"
  sk "needs.rpm.outputs.skipped"; expect 1 "a bare truthiness test of outputs.skipped"
  sk "\${{ !needs.rpm.outputs.skipped }}"; expect 1 "a negated truthiness test of outputs.skipped"
  # property names are case-insensitive in GitHub's expressions, and a property can be read by index: every spelling
  # is judged, an unquoted true refused and the quoted 'true' passing
  for form in "needs.rpm.outputs.Skipped" "Needs.RPM.Outputs.SKIPPED" "needs['rpm'].outputs.skipped" \
              "needs.rpm.outputs['skipped']" "needs['rpm']['outputs']['skipped']" "needs[ 'Rpm' ][ 'Outputs' ].skipped"; do
    sk "$form != true"; expect 1 "an unquoted != true on $form"
    sk "$form != 'true'"; expect 0 "a quoted guard on $form"
  done
  # over-strict by design: only the single quoted comparison is taken
  sk "fromJSON(needs.rpm.outputs.skipped)"; expect 1 "fromJSON of outputs.skipped in an if"
  sk "needs.rpm.outputs.skipped == 'false'"; expect 1 "a comparison of outputs.skipped with 'false'"
  printf 'on: [workflow_dispatch]\njobs:\n  other:\n    uses: ./.github/workflows/x.yml\n  check:\n    needs: other\n    if: needs.other.outputs.skipped\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' > "$w/sk.yml"
  expect 0 "the skipped output of a job that calls neither build-rpm.yml nor build-deb.yml"
  rm "$w/sk.yml"
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
