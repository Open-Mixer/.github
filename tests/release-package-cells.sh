#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# release-package.yml builds openmixer-release for EVERY Fedora release of the set, offline, over the workflow as it is
# (fc45, 2026-11-15: the rpm job built in fedora:44 alone, so fedora/45/noarch never served the package and a Fedora 45
# machine got the stable name and no update of it; %1's audit found it the channel's one fc44/fc45 gap):
#   A. the rpm job's matrix is the rows of a release-matrix plan of kind rpm (never a literal, never one container);
#   B. its container image is the matrix row's release, and its artifact is named by the release, so the builds
#      do not overwrite each other;
#   C. the installability gate and the publish download every release's build (a pattern, merged), and the publish
#      checks each release of the plan has its file before anything is signed;
#   D. after the publish, a job runs served-check.sh: the channel serves the package in every release's noarch tree;
#   E. served-check.sh reads its releases from the quick set, never from a list of its own.
# Sabotage: a copy of the workflow with the rpm job back on one container must fail A and B.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
wf=${1:-$here/.github/workflows/release-package.yml}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }

cat > "$t/scan.py" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1])); jobs = d.get("jobs") or {}; errs = []
def step_uses(job, action): return [s for s in (jobs.get(job) or {}).get("steps") or [] if re.search(rf"/actions/{action}(@|$)", s.get("uses", ""))]
rpm = jobs.get("rpm") or {}
inc = str(((rpm.get("strategy") or {}).get("matrix") or {}).get("include", ""))
m = re.search(r"fromJSON\(needs\.([\w-]+)\.outputs\.cells\)", inc)
plan = m.group(1) if m else None
if not plan: errs.append("A: the rpm job's matrix is not the rows of a plan's cells (strategy.matrix.include: fromJSON(needs.<plan>.outputs.cells))")
else:
    ps = step_uses(plan, "release-matrix")
    if not ps: errs.append(f"A: job {plan} runs no release-matrix step")
    elif (ps[0].get("with") or {}).get("kind") != "rpm": errs.append(f"A: job {plan}'s release-matrix is not of kind rpm")
img = str((rpm.get("container") or {}).get("image", rpm.get("container", "")))
if "matrix.fedora" not in img: errs.append(f"B: the rpm job's container is not the matrix row's release: {img!r}")
up = [s for s in rpm.get("steps") or [] if s.get("uses", "").startswith("actions/upload-artifact")]
if not up or "matrix.fedora" not in str((up[0].get("with") or {}).get("name", "")): errs.append("B: the rpm job's artifact is not named by the release (the builds overwrite each other)")
for job in ("installability-rpm", "publish-rpm"):
    dl = [s for s in (jobs.get(job) or {}).get("steps") or [] if s.get("uses", "").startswith("actions/download-artifact")]
    w = (dl[0].get("with") or {}) if dl else {}
    if not dl or "openmixer-release-rpm" not in str(w.get("pattern", "")) or str(w.get("merge-multiple", "")).lower() != "true":
        errs.append(f"C: job {job} does not download every release's build (pattern + merge-multiple)")
pub = "\n".join(str(s.get("run", "")) for s in (jobs.get("publish-rpm") or {}).get("steps") or [])
if not re.search(r"for rel in \$RELEASES", pub) or "no build for fc" not in pub: errs.append("C: the publish does not check each release of the plan has its build before signing")
served = jobs.get("served") or {}
if not served: errs.append("D: no served job after the publish")
else:
    if "served-check.sh" not in "\n".join(str(s.get("run", "")) for s in served.get("steps") or []): errs.append("D: the served job does not run served-check.sh")
    if "verify" not in str(served.get("needs", "")): errs.append("D: the served job does not follow the verify job")
    if "publish == 'true'" not in str(served.get("if", "")): errs.append("D: the served job runs on a dry run too (it reads the live channel)")
print("\n".join(errs)); sys.exit(1 if errs else 0)
PY
if out=$(python3 -I "$t/scan.py" "$wf"); then yes "A-D  release-package.yml builds, gates, publishes and checks every Fedora release of the set"
else while IFS= read -r l; do no "$l"; done <<< "$out"; fi

sc=$here/packaging/openmixer-release/served-check.sh
if [ -x "$sc" ] && grep -q 'release-matrix/quick.txt' "$sc" && ! grep -qE 'for rel in [0-9]' "$sc"; then yes "E    served-check.sh reads its releases from the quick set"
else no "E    served-check.sh is missing, not executable, or lists releases of its own"; fi

# sabotage: the rpm job back on one container, its artifact under one name
python3 -I - "$wf" "$t/sab.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); rpm = d["jobs"]["rpm"]
rpm.pop("strategy", None); rpm["container"] = {"image": "fedora:44"}
for s in rpm["steps"]:
    if s.get("uses", "").startswith("actions/upload-artifact"): s["with"]["name"] = "openmixer-release-rpm"
yaml.safe_dump(d, open(sys.argv[2], "w"), sort_keys=False)
PY
if python3 -I "$t/scan.py" "$t/sab.yml" > "$t/sab.out" 2>&1; then no "sabotage: the rpm job on one container passes"
elif grep -q '^A:' "$t/sab.out" && grep -q '^B:' "$t/sab.out"; then yes "sabotage: the rpm job back on one container is red on A and B"
else no "sabotage: red, but not on A and B: $(tr '\n' ';' < "$t/sab.out")"; fi

[ "$fail" = 0 ] && echo "release-package-cells: all passed" || exit 1
