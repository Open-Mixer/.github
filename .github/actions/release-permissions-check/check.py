# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""A called workflow cannot raise its caller's token. For every job of the given release workflow that calls one of
this repository's reusable workflows, the permissions the caller grants (the job's, else the top level's) must cover
the permissions the callee asks for (its top level and any of its jobs). Absent grants are refused: the default token
is whatever the repository setting says, which is not a thing a release can lean on."""
import os, sys, yaml

RANK = {"none": 0, "read": 1, "write": 2}
ALL = ["actions", "attestations", "checks", "contents", "deployments", "discussions", "id-token", "issues",
       "models", "packages", "pages", "pull-requests", "security-events", "statuses"]


def norm(p):
    """permissions block -> {scope: rank}; None when absent"""
    if p is None:
        return None
    if p in ("read-all", "write-all"):
        return {s: RANK[p.split("-")[0]] for s in ALL}
    return {k: RANK[str(v)] for k, v in (p or {}).items()}


def needs(workflow):
    out = {}
    for block in [workflow.get("permissions")] + [j.get("permissions") for j in (workflow.get("jobs") or {}).values()]:
        for k, v in (norm(block) or {}).items():
            out[k] = max(out.get(k, 0), v)
    return {k: v for k, v in out.items() if v}


def check(path, shared):
    d = yaml.safe_load(open(path))
    top = norm(d.get("permissions"))
    bad = []
    for name, job in (d.get("jobs") or {}).items():
        uses = str(job.get("uses", ""))
        if not uses.startswith("Open-Mixer/.github/.github/workflows/"):
            continue
        callee = uses.split("/workflows/")[1].split("@")[0]
        want = needs(yaml.safe_load(open(os.path.join(shared, callee))))
        granted = norm(job["permissions"]) if "permissions" in job else top
        if granted is None:
            bad.append(f"{path}: job {name} calls {callee} and grants no permissions block (job or top level)")
            continue
        for scope, rank in sorted(want.items()):
            if granted.get(scope, 0) < rank:
                have = {v: k for k, v in RANK.items()}[granted.get(scope, 0)]
                need = {v: k for k, v in RANK.items()}[rank]
                bad.append(f"{path}: job {name} calls {callee}, which needs {scope}: {need}; the caller grants {scope}: {have}")
    return bad


if __name__ == "__main__":
    shared = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "workflows")
    bad = []
    for f in sys.argv[1:]:
        bad += check(f, shared)
    for b in bad:
        print("::error::" + b)
    sys.exit(1 if bad else 0)
