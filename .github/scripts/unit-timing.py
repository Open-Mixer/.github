#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""The wall clock of a release-unit.yml run, from its start to would-publish (the end of the integration box),
per level and per member, and the critical path (the release-units design, section 9).

    unit-timing.py <owner/repo> <run id>        (GH_TOKEN in the environment)
    unit-timing.py --jobs <jobs.json> <run.json> (offline: the API's two answers, saved)

Prints a markdown table. Minutes are from the run's start; a member's span is its first job's start to its last
job's end (its preflight, every cell, and the unsigned tree), so a level's end is what the next level waited for.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime


def api(path):
    req = urllib.request.Request(f"https://api.github.com/{path}", headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def fetch(repo, run):
    jobs, page = [], 1
    while True:
        got = api(f"repos/{repo}/actions/runs/{run}/jobs?per_page=100&filter=latest&page={page}")["jobs"]
        jobs += got
        if len(got) < 100:
            break
        page += 1
    return jobs, api(f"repos/{repo}/actions/runs/{run}")


def t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def report(jobs, run):
    t0 = t(run.get("run_started_at") or run["created_at"])
    m = lambda x: (x - t0).total_seconds() / 60  # noqa: E731
    groups = {}
    for j in jobs:
        if not j.get("started_at") or j.get("conclusion") == "skipped":
            continue
        top, _, rest = j["name"].partition(" / ")
        level, _, member = top.partition(" (")
        member = member.rstrip(")").split(",")[0].strip() if member else ""
        g = groups.setdefault(level, {})
        span = g.setdefault(member or "-", [t(j["started_at"]), t(j["completed_at"]) or t(j["started_at"]), set(), 0.0])
        span[0] = min(span[0], t(j["started_at"]))
        span[1] = max(span[1], t(j["completed_at"]) or span[1])
        span[2].add(j.get("conclusion") or "running")
        if j.get("completed_at"):
            span[3] += (t(j["completed_at"]) - t(j["started_at"])).total_seconds() / 60
    out = [f"run {run['id']} {run['html_url']} ({run['status']}/{run.get('conclusion')})", "",
           "| job | member | start | end | span | job minutes | result |", "|---|---|---:|---:|---:|---:|---|"]
    order = lambda k: (k.split()[0] if k[:3] in ("rpm", "deb") else "z" + k, k)  # noqa: E731
    ends = {}
    for level in sorted(groups, key=order):
        for member, (a, b, res, busy) in sorted(groups[level].items(), key=lambda kv: kv[1][0]):
            out.append(f"| {level} | {member} | {m(a):.1f} | {m(b):.1f} | {m(b) - m(a):.1f} | {busy:.1f} | "
                       f"{'/'.join(sorted(res))} |")
            ends[level] = max(ends.get(level, 0), m(b))
    out.append("")
    for kind in ("rpm", "deb"):
        chain = [k for k in sorted(ends, key=order) if k.startswith(kind + " level")]
        prev = 0.0
        steps = []
        for k in chain:
            steps.append(f"{k.split()[-1]}:{ends[k] - prev:.1f}")
            prev = ends[k]
        out.append(f"{kind} chain, minutes per level (end to end): {' '.join(steps)}; done at {prev:.1f}")
    pub = max((ends[k] for k in ends if k.startswith("Install the unit")), default=None)
    if pub is not None:
        crit = max(("rpm", "deb"), key=lambda k: max((ends[x] for x in ends if x.startswith(k + " level")), default=0))
        out.append(f"would-publish at {pub:.1f} min from the run's start; the critical path is the {crit} chain")
    return "\n".join(out)


def main(argv):
    if len(argv) == 3 and argv[0] == "--jobs":
        with open(argv[1], encoding="utf-8") as f:
            jobs = json.load(f)
        with open(argv[2], encoding="utf-8") as f:
            run = json.load(f)
        jobs = jobs.get("jobs", jobs)
    elif len(argv) == 2:
        jobs, run = fetch(argv[0], argv[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(report(jobs, run))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
