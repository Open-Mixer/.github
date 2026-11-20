#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Owner ruling 2026-11-20: vars.OMX_RUNNER stays ubuntu-latest for everything; ONLY the language-pack fill job names the
# self-hosted label (arc-freemixer, the ARC scale set; build-rpm.yml and public-sources-check.yml name it the same way).
# The fill workflow's job runs on that label, never reads vars.OMX_RUNNER, always hands its container the cluster DNS
# (no condition: it only ever runs on our pool), and never runs for a fork or outside a pull request. The caller's
# check-only job stays on vars.OMX_RUNNER with no DNS (the langpacks action documents that split).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/check.py" <<'PY'
import sys, yaml
f = sys.argv[1]
d = yaml.safe_load(open(f))
j = d["jobs"]["fill"]
assert j["runs-on"] == "arc-freemixer", f"fill runs-on is {j['runs-on']!r}, not the self-hosted label arc-freemixer"
opts = str(j["container"]["options"])
assert "${{" not in opts, f"the cluster DNS is conditional: {opts}"
assert "--dns 10.43.0.10" in opts, f"the cluster DNS is not handed to the fill container: {opts}"
cond = " ".join(str(j.get("if", "")).split())
want = "github.event_name == 'pull_request' && !github.event.pull_request.head.repo.fork || github.event_name == 'workflow_dispatch'"
assert cond == want, f"the fill's job if is not the same-repository pull request or a dispatch: {cond!r}"
steps = j["steps"]
chk = [i for i, x in enumerate(steps) if "pulls?head=" in str(x.get("run", "")) and "state=open" in str(x.get("run", ""))]
fill = [i for i, x in enumerate(steps) if "actions/langpacks@" in str(x.get("uses", ""))]
assert chk and fill and chk[0] < fill[0], "the open-pull-request check does not come before the fill"
assert "steps.pr.outputs.head-sha" in str(steps[fill[0]]["with"].get("dispatch-head")), "the fill is not given the proved head sha"
print("ok   langpacks-fill.yml fill")
PY
check() { python3 -I "$t/check.py" "$1"; }
w=$here/.github/workflows/langpacks-fill.yml
check "$w" || fail=1
grep -q 'langpacks-fill.yml fill' "$here/tests/fixtures/needs-private-jobs.txt" || { echo "FAIL the fill job is not listed as needing a private runner"; fail=1; }
grep -q 'vars.OMX_RUNNER' "$w" && { echo "FAIL the fill workflow reads vars.OMX_RUNNER"; fail=1; }
sab() { # name sed-expr
  sed "$2" "$w" > "$t/s.yml"; cmp -s "$w" "$t/s.yml" && { echo "FAIL sabotage $1: nothing to break"; fail=1; return; }
  if check "$t/s.yml" >/dev/null 2>&1; then echo "FAIL sabotage: $1 passes"; fail=1; else echo "ok   sabotage: $1 is red"; fi
}
sab "the fill on the organisation variable" 's/^    runs-on: arc-freemixer/    runs-on: ${{ vars.OMX_RUNNER || '"'ubuntu-latest'"' }}/'
sab "the fill on a hosted label" 's/^    runs-on: arc-freemixer/    runs-on: ubuntu-latest/'
sab "a conditional cluster DNS" 's/options: --dns 10.43.0.10/options: ${{ vars.OMX_RUNNER \&\& '"'--dns 10.43.0.10'"' }} --dns 10.43.0.10/'
sab "a dispatch fill with no open-pull-request check" 's/pulls?head=/pulls?x=/'
sab "a fill that is dispatch only" "s/if: github.event_name == 'pull_request' \&\& !github.event.pull_request.head.repo.fork || /if: /"
sab "a fill not told the proved head" 's/dispatch-head: /x-head: /'
sab "no cluster DNS" 's/--dns 10.43.0.10 //'
sab "a fill for a fork" "s/ && !github.event.pull_request.head.repo.fork//"

# fill.py refuses by name a push to the default branch or a kept name (main, openmixer-v*, release/*, settle/*), on the pull
# request (GITHUB_HEAD_REF) and the dispatch (GITHUB_REF_NAME, which the action hands over as GITHUB_HEAD_REF) path alike
cat > "$t/kept.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fill", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for r in ("main", "openmixer-v1", "openmixer-v2", "release/3.1", "settle/12", "trunk"):
    assert m.kept_ref(r, "trunk"), f"{r} is not refused"
for r in ("lane/langpacks", "lane/main-fix", "feature", "releases/x", "mainline"):
    assert not m.kept_ref(r, "trunk"), f"{r} is refused"
print("ok   fill.py refuses the default branch and every kept name, allows lane/*")
PY
fillpy=$here/.github/actions/langpacks/fill.py
python3 -I "$t/kept.py" "$fillpy" || fail=1
ksab() { # name sed-expr
  sed "$2" "$fillpy" > "$t/fill-s.py"; cmp -s "$fillpy" "$t/fill-s.py" && { echo "FAIL sabotage $1: nothing to break"; fail=1; return; }
  if python3 -I "$t/kept.py" "$t/fill-s.py" >/dev/null 2>&1; then echo "FAIL sabotage: $1 passes"; fail=1; else echo "ok   sabotage: $1 is red"; fi
}
ksab "the kept-name check removed" 's/^    return bool(ref) and (ref == default.*/    return False/'
ksab "the release branches no longer kept" 's/"openmixer-v", "release\/", "settle\/"/"openmixer-v", "settle\/"/'
ksab "the default branch no longer kept" 's/ref == default or //'
grep -q 'kept_ref(env\["GITHUB_HEAD_REF"\]' "$fillpy" || { echo "FAIL fill.py does not apply kept_ref to the push target"; fail=1; }
exit "$fail"
