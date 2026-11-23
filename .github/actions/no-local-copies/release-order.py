#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# release-order.py WORKFLOW...
#
# A job that publishes DEBs (calls build-deb.yml) runs beside the jobs that build RPMs (calls build-rpm.yml) or after
# them; the two publish jobs share one concurrency group per target, so their pushes never race. What it may not do
# is skip a gate: beside an RPM job it needs everything that RPM job needs, and after one it needs that job. An `if`
# that can run a job whose needs failed (`!cancelled()`, `always()`, `failure()`) must still demand
# needs.<job>.result == 'success' for every job it needs. A workflow with no DEB job is not judged.
import re
import sys

import yaml

bad = 0
for path in sys.argv[1:]:
    doc = yaml.safe_load(open(path)) or {}
    jobs = doc.get("jobs") or {}
    rpm = [n for n, j in jobs.items() if "build-rpm.yml" in str((j or {}).get("uses", ""))]
    for name, job in jobs.items():
        job = job or {}
        if "build-deb.yml" not in str(job.get("uses", "")) or not rpm:
            continue
        needs = job.get("needs") or []
        needs = [needs] if isinstance(needs, str) else list(needs)
        cond = str(job.get("if", "")) if "if" in job else ""
        for r in rpm:
            if r in needs:
                continue
            own = (jobs[r] or {}).get("needs") or []
            own = [own] if isinstance(own, str) else list(own)
            for n in own:
                if n not in needs:
                    print(f"release-order: {path}: job {name} publishes DEBs beside {r} without needs: {n}", file=sys.stderr)
                    bad = 1
        if re.search(r"cancelled\(\)|always\(\)|failure\(\)", cond):
            loose = [n for n in needs if not re.search(r"needs\.%s\.result\s*==\s*'success'" % re.escape(n), cond)]
            if loose or not needs:
                print(f"release-order: {path}: job {name} has an if ({cond.strip()}) that lets it run after a failed "
                      f"{', '.join(loose) or 'gate'}", file=sys.stderr)
                bad = 1
sys.exit(bad)
