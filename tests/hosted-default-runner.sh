#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The default runner of the reusable workflows is GitHub-hosted. A runner input (runner, runs-on) defaults to a hosted
# label, and every job whose runs-on reads it lands on a hosted runner when the caller passes nothing, whatever the
# organisation variable OMX_RUNNER says: no reusable's runs-on reads vars.OMX_RUNNER. The input stays: a caller that
# passes arc-freemixer gets it on a pull request of its own repository. A job that needs a private runner is named in
# tests/fixtures/needs-private-jobs.txt and names the ARC scale set itself.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/check.py" <<'PY'
import re, sys, yaml

HOSTED = re.compile(r"^(ubuntu|macos|windows)-[a-z0-9.-]+$")
ARC = "arc-freemixer"

def get(ctx, path):
    cur = ctx
    for k in path.split(".")[1:]:
        cur = cur.get(k) if isinstance(cur, dict) else None
    return cur

def evaluate(expr, ctx):
    e = expr.strip()
    if not (e.startswith("${{") and e.endswith("}}")):
        return e
    e = e[3:-2]
    e = re.sub(r"\b(github|inputs|vars|matrix)((?:\.[A-Za-z0-9_-]+)+)", lambda m: f"R({m.group(0)!r})", e)
    e = e.replace("startsWith(", "S(").replace("||", " or ").replace("&&", " and ")
    e = re.sub(r"!(?!=)", " not ", e)
    e = re.sub(r"\bfalse\b", "False", re.sub(r"\btrue\b", "True", e))
    env = {"R": lambda p: get(ctx[p.split(".")[0]], p), "S": lambda a, b: str(a or "").startswith(b)}
    return eval(e, {"__builtins__": {}}, env)

def cases(inputs):
    for ev, ref in (("pull_request", "refs/pull/5/merge"), ("push", "refs/heads/main"), ("push", "refs/tags/v1.2.3"),
                    ("workflow_dispatch", "refs/heads/main")):
        for private in (False, True):
            for arch in ("x86_64", "amd64", "aarch64", "arm64"):
                yield dict(github=dict(event_name=ev, ref=ref, repository="o/r",
                                       event=dict(repository=dict(private=private),
                                                  pull_request=dict(head=dict(repo=dict(full_name="o/r", fork=False))))),
                           inputs=dict(inputs), vars=dict(OMX_RUNNER=ARC), matrix=dict(arch=arch, fedora="44", suite="trixie"))

f, listing = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(f))
on = d.get(True) or d.get("on")
name = f.split("/")[-1]
needs = {l.split()[1] for l in open(listing) if l.strip() and not l.startswith("#") and l.split()[0] == name}
declared = ((on.get("workflow_call") or {}).get("inputs") or {}) if isinstance(on, dict) and "workflow_call" in on else {}
defaults = {k: v.get("default") for k, v in declared.items() if isinstance(v, dict)}
for k in ("runner", "runs-on"):
    if k in declared:
        assert HOSTED.match(str(defaults.get(k) or "")), f"{name}: input {k} defaults to {defaults.get(k)!r}, not a hosted runner"
jobs = d.get("jobs") or {}
for j in needs:
    assert j in jobs, f"{name}: needs-private job {j} is not a job of the workflow"
for jn, job in jobs.items():
    ro = str(job.get("runs-on", ""))
    if not ro:
        continue
    if jn in needs:
        assert ARC in ro and "vars.OMX_RUNNER" not in ro, f"{name}: job {jn} needs a private runner and does not name {ARC}: {ro}"
        continue
    assert "vars.OMX_RUNNER" not in ro, f"{name}: job {jn} reads vars.OMX_RUNNER: {ro}"
    for ctx in cases(defaults):
        got = evaluate(ro, ctx)
        assert isinstance(got, str) and HOSTED.match(got), \
            f"{name}: job {jn} ({ctx['github']['event_name']} {ctx['github']['ref']} private={ctx['github']['event']['repository']['private']} {ctx['matrix']['arch']}) runs on {got!r} with the caller passing nothing"
    for k in ("runner", "runs-on"):
        if k in declared and ro.startswith("${{"):
            assert f"inputs.{k}" in ro, f"{name}: job {jn} chooses its runner without reading the caller's {k}: {ro}"
            ctx = next(cases({**defaults, k: ARC}))
            ctx["matrix"]["arch"] = "x86_64"
            got = evaluate(ro, ctx)
            assert got == ARC, f"{name}: job {jn} ignores a caller's {k}: {ARC} on a pull request of its own repository -> {got!r}"
print(f"ok   {name}")
PY
check() { python3 -I "$t/check.py" "$1" "$2"; }
list=$here/tests/fixtures/needs-private-jobs.txt
n=0
for w in "$here"/.github/workflows/*.yml; do
  grep -q '^  workflow_call:' "$w" || continue
  check "$w" "$list" || fail=1
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "FAIL no reusable workflow read"; fail=1; }

# sabotage: the matrix build's old tail, the organisation variable read when the caller passes the default, is red
sed "s/|| inputs.runner || 'ubuntu-latest' }}/|| (inputs.runner != 'ubuntu-latest' \&\& inputs.runner) || vars.OMX_RUNNER || 'ubuntu-latest' }}/" \
  "$here/.github/workflows/build-rpm.yml" > "$t/build-rpm.yml"
cmp -s "$here/.github/workflows/build-rpm.yml" "$t/build-rpm.yml" && { echo "FAIL sabotage: build-rpm.yml has no hosted tail to break"; fail=1; }
if check "$t/build-rpm.yml" "$list" >/dev/null 2>&1; then echo "FAIL sabotage: a job reading vars.OMX_RUNNER passes"; fail=1
else echo "ok   sabotage: a job reading vars.OMX_RUNNER is red"; fi
# sabotage: a job pinned to the ARC pool without being listed (no variable read, so only the evaluation sees it) is red
sed "s/|| inputs.runner || 'ubuntu-latest' }}/|| 'arc-freemixer' }}/" "$here/.github/workflows/build-deb.yml" > "$t/build-deb-arc.yml"
cmp -s "$here/.github/workflows/build-deb.yml" "$t/build-deb-arc.yml" && { echo "FAIL sabotage: build-deb.yml has no hosted tail to pin"; fail=1; }
if check "$t/build-deb-arc.yml" "$list" >/dev/null 2>&1; then echo "FAIL sabotage: an unlisted job pinned to ARC passes"; fail=1
else echo "ok   sabotage: an unlisted job pinned to ARC is red"; fi
# sabotage: a runner input that defaults to the ARC pool is red
sed "0,/default: 'ubuntu-latest'/s//default: 'arc-freemixer'/" "$here/.github/workflows/promote-staged.yml" > "$t/promote-staged.yml"
grep -q "default: 'arc-freemixer'" "$t/promote-staged.yml" || { echo "FAIL sabotage: promote-staged.yml has no hosted default to break"; fail=1; }
python3 -I - "$t/promote-staged.yml" <<'PY' || { echo "FAIL sabotage: the arc default did not land on the runner input"; fail=1; }
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); on = d.get(True) or d.get("on")
assert on["workflow_call"]["inputs"]["runner"]["default"] == "arc-freemixer"
PY
if check "$t/promote-staged.yml" "$list" >/dev/null 2>&1; then echo "FAIL sabotage: a runner input defaulting to ARC passes"; fail=1
else echo "ok   sabotage: a runner input defaulting to ARC is red"; fi
# sabotage: a caller's runner dropped (the job pinned to hosted) is red, the input must still choose
sed "s/|| inputs.runner || 'ubuntu-latest' }}/|| 'ubuntu-latest' }}/" "$here/.github/workflows/build-deb.yml" > "$t/build-deb.yml"
if check "$t/build-deb.yml" "$list" >/dev/null 2>&1; then echo "FAIL sabotage: a job ignoring the caller's runner passes"; fail=1
else echo "ok   sabotage: a job ignoring the caller's runner is red"; fi
# sabotage: a job listed as needing a private runner that reads vars.OMX_RUNNER (or a hosted label) is red
{ cat "$list"; echo "build-rpm.yml build"; } > "$t/needs.txt"
if check "$here/.github/workflows/build-rpm.yml" "$t/needs.txt" >/dev/null 2>&1; then echo "FAIL sabotage: a needs-private job off ARC passes"; fail=1
else echo "ok   sabotage: a needs-private job off ARC is red"; fi
# control: the same job listed and naming the ARC scale set passes
python3 -I - "$here/.github/workflows/build-rpm.yml" "$t/build-rpm-arc.yml" > "$t/first-job" <<'PY2'
import re, sys, yaml
src, out = sys.argv[1:3]
lines = open(src).read().split("\n")
n = next(i for i, l in enumerate(lines) if re.match(r"^    runs-on: .*inputs\.runner", l))
lines[n] = "    runs-on: arc-freemixer"
open(out, "w").write("\n".join(lines))
print(next(k for k, j in yaml.safe_load(open(out))["jobs"].items() if j.get("runs-on") == "arc-freemixer"))
PY2
{ cat "$list"; echo "build-rpm-arc.yml $(cat "$t/first-job")"; } > "$t/needs.txt"
if check "$t/build-rpm-arc.yml" "$t/needs.txt" >/dev/null 2>&1; then echo "ok   control: a needs-private job naming ARC passes"
else echo "FAIL control: a needs-private job naming ARC is red"; fail=1; fi
exit "$fail"
