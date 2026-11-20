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
cond = str(j.get("if", ""))
assert "pull_request" in cond and "fork" in cond, f"the fill is not held to a same-repository pull request: {cond!r}"
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
sab "no cluster DNS" 's/--dns 10.43.0.10 //'
sab "a fill for a fork" "s/ && !github.event.pull_request.head.repo.fork//"
exit "$fail"
