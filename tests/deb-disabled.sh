#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# build-deb.yml's `enabled: false` (a source that ships no Debian package): the input exists, defaults on, and with it
# off no job of the workflow can run on any trigger -- the preflight is skipped and every other job either needs it
# directly or through a job that does, with an `if` that does not rescue a skipped need. A job added later that needs
# nothing, or `always()`s past it, is red here by name.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
python3 -I - "$here/../.github/workflows/build-deb.yml" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True) or d.get("on")
decl = on["workflow_call"]["inputs"]
assert decl.get("enabled", {}).get("type") == "boolean" and decl["enabled"].get("default") is True, "build-deb.yml: no boolean input `enabled` defaulting on"
jobs = d["jobs"]
assert re.sub(r"\s", "", str(jobs["preflight"].get("if", ""))) == "${{inputs.enabled}}", "build-deb.yml: the preflight is not gated on inputs.enabled"
def needs(j):
    n = jobs[j].get("needs", [])
    return [n] if isinstance(n, str) else n
# a job runs with `enabled` off only if it can run while the preflight is skipped
def can_run(j, memo={}):
    if j == "preflight":
        return False
    if j in memo:
        return memo[j]
    cond = str(jobs[j].get("if", ""))
    n = needs(j)
    memo[j] = False  # no cycles in needs
    if not n:
        memo[j] = True
    elif "contains(needs.*.result, 'failure')" in cond:
        # a failure report: runs only when some need failed or was cancelled, so only if some need can run at all
        memo[j] = any(can_run(x) for x in n)
    elif "always()" in cond:
        memo[j] = True  # runs past a skipped need
    elif "!cancelled()" in cond or "success()" in cond:
        # `!cancelled()` replaces the implicit success(): the job runs past skipped needs unless its own condition names
        # a result it must have; it then runs only if one of those jobs can
        names = re.findall(r"needs\.([a-z-]+)\.result\s*==\s*'success'", cond)
        memo[j] = not names or any(can_run(x) for x in names)
    else:
        memo[j] = all(can_run(x) for x in n)
    return memo[j]
bad = [j for j in jobs if j != "preflight" and can_run(j)]
assert not bad, f"build-deb.yml: with enabled false these jobs can still run: {bad}"
print("ok   build-deb.yml: enabled false skips every job")
PY

# clap-headers-deb.yml is a workflow of its own (a tag clap-headers-*), not a call of build-deb: it ships no Debian
# package either, so each of its jobs that needs nothing is `if: ${{ false }}`, and every other one needs such a job.
python3 -I - "$here/../.github/workflows/clap-headers-deb.yml" <<'PY'
import re, sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
off = lambda j: re.sub(r"\s", "", str(jobs[j].get("if", ""))) == "${{false}}"
def needs(j):
    n = jobs[j].get("needs", [])
    return [n] if isinstance(n, str) else n
def can_run(j):
    if off(j):
        return False
    n = needs(j)
    if not n:
        return True
    cond = str(jobs[j].get("if", ""))
    if "always()" in cond or "!cancelled()" in cond:
        return True
    return all(can_run(x) for x in n)
bad = [j for j in jobs if can_run(j)]
assert not bad, f"clap-headers-deb.yml ships no Debian package, yet these jobs can run: {bad}"
print("ok   clap-headers-deb.yml: no job can run")
PY

