#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The reusable workflows: each is callable (workflow_call), names every input it reads, and calls this repository's
# actions and workflows at v1, never at a branch; the no-local-copies check proves itself. A job whose runner the
# caller can choose (its runs-on or runner input, or a repository variable) falls back to a GitHub-hosted runner for a
# pull request from a fork before any of those is read, so fork pull requests never reach a self-hosted runner.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/check.py" <<'PY'
import re, sys, yaml
f = sys.argv[1]; text = open(f).read(); d = yaml.safe_load(text)
on = d.get(True) or d.get("on")
assert isinstance(on, dict) and "workflow_call" in on, f"{f}: not callable"
declared = set(((on["workflow_call"] or {}).get("inputs") or {}).keys())
used = set(re.findall(r"inputs\.([a-z0-9-]+)", text))
assert used <= declared, f"{f}: reads undeclared inputs {sorted(used - declared)}"
for ref in re.findall(r"uses: (FreeMixer/\.github/\S+)", text):
    assert ref.endswith("@v1"), f"{f}: {ref} is not called at v1"
fork = ("startsWith(github.event_name, 'pull_request') && github.event.pull_request.head.repo.full_name != "
        "github.repository && 'ubuntu-latest'")
chosen = re.compile(r"inputs\.(runs-on|runner)\b|vars\.")
for name, job in (d.get("jobs") or {}).items():
    ro = str(job.get("runs-on", ""))
    first = chosen.search(ro)
    if not first:
        continue
    at = ro.find(fork)
    assert at >= 0 and ro[at - 3:at] in ("{{ ", "|| ") and ro[at + len(fork):].startswith(" ||"), \
        f"{f}: job {name} takes a caller-chosen runner without the fork fallback: {ro}"
    assert at < first.start(), \
        f"{f}: job {name} reads a caller-chosen runner before the fork fallback: {ro}"
print(f"ok   {f.split('/')[-1]}")
PY
check() { python3 -I "$t/check.py" "$1"; }

for w in public-sources-check ci-node ci-c fuzz release-c-lib release-npm build-rpm build-deb purge-staging; do
  check "$here/.github/workflows/$w.yml" || fail=1
done
"$here/.github/actions/no-local-copies/check.sh" --self-test >/dev/null || { echo "FAIL no-local-copies self-test"; fail=1; }

# sabotage: an input read but not declared is caught
sed 's/\${{ inputs.commands }}/${{ inputs.undeclared }}/' "$here/.github/workflows/ci-c.yml" > "$t/ci-c.yml"
if check "$t/ci-c.yml" >/dev/null 2>&1; then echo "FAIL sabotage: an undeclared input passes"; fail=1
else echo "ok   sabotage: an undeclared input is red"; fi

# sabotage: each job's runner with the fork fallback taken out, one job at a time, and for the matrix jobs with the
# caller's runner read before it, is caught
cat > "$t/sabotage.py" <<'PY'
import sys
src, n, how, out = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
fork = ("startsWith(github.event_name, 'pull_request') && github.event.pull_request.head.repo.full_name != "
        "github.repository && 'ubuntu-latest' || ")
caller = "(inputs.runner != 'ubuntu-latest' && inputs.runner) || "
lines = open(src).read().split("\n")
line = lines[n - 1]
lines[n - 1] = line.replace(fork, "") if how == "strip" else line.replace(fork + caller, caller + fork)
open(out, "w").write("\n".join(lines))
sys.exit(0 if lines[n - 1] != line else 3)
PY
for w in ci-node ci-c fuzz build-rpm build-deb; do
  src=$here/.github/workflows/$w.yml
  lines=$(grep -n "runs-on: .*github.event.pull_request.head.repo.full_name != github.repository" "$src" | cut -d: -f1 || true)
  [ -n "$lines" ] || { echo "FAIL sabotage: $w.yml has no fork fallback to strip"; fail=1; continue; }
  for n in $lines; do
    for how in strip reorder; do
      rc=0; python3 -I "$t/sabotage.py" "$src" "$n" "$how" "$t/$w.yml" || rc=$?
      if [ "$rc" = 3 ]; then
        [ "$how" = strip ] && { echo "FAIL sabotage: $w.yml:$n has no fork fallback to strip"; fail=1; }; continue
      fi
      if check "$t/$w.yml" >/dev/null 2>&1; then echo "FAIL sabotage: $w.yml:$n ($how) passes"; fail=1
      else echo "ok   sabotage: $w.yml:$n ($how) is red"; fi
    done
  done
done
exit "$fail"
