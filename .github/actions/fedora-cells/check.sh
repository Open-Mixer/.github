#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# fedora-cells: no Fedora release is written into a job of the caller's workflows (rule 11-10: fc45 beside fc44 in
# every check; ruling D25: every job's cells come from release-matrix or check-matrix, whose quick.txt carries both).
#
#   check.sh [DIR]   DIR the workflows (default .github/workflows); exit 0 green, 1 red (each finding named with its
#                    file, job and line), 2 not measured (no workflow)
#
# Red: a Fedora image or release (fedora:44, fc44, "44" in a matrix) written into a job: its container, its matrix,
# its steps. Green: the whole matrix handed to check-matrix, release-matrix or build-rpm (a rpm-releases: or
# releases: line), cells taken from a plan's output, and a line marked "# tool image: <why>" (fedora:44 as a toolbox
# over the whole repository, not a cell; the reason is required).
set -uo pipefail
dir=${1:-.github/workflows}
shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
[ ${#files[@]} -gt 0 ] || { echo "fedora-cells: not measured: no workflow in $dir"; exit 2; }
python3 -I - "${files[@]}" <<'PY'
import os, re, sys
lit = re.compile(r"fedora:\s*4\d\b|\bfc4\d\b|['\"]4\d['\"]")
declare = re.compile(r"^\s*(rpm-)?releases\s*:")
tool = re.compile(r"#\s*tool image:\s*(\S.*)?$")
errs = []
for path in sys.argv[1:]:
    name = os.path.basename(path)
    job, in_jobs = None, False
    for n, line in enumerate(open(path), 1):
        if re.match(r"^jobs:\s*$", line): in_jobs = True; continue
        if in_jobs:
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m: job = m.group(1)
        if not in_jobs or job is None: continue
        code = line.split("#", 1)[0] if not tool.search(line) else line[:tool.search(line).start()]
        if not lit.search(code): continue
        if declare.match(line): continue
        t = tool.search(line)
        if t:
            if t.group(1): continue
            errs.append(f"{name} job {job} line {n}: a tool-image marker with no reason: {line.strip()}")
            continue
        errs.append(f"{name} job {job} line {n}: a Fedora release written into the job ({lit.search(code).group(0)}): take the cells from check-matrix, or mark a toolbox '# tool image: <why>'")
for e in errs: print("RED  " + e)
print(f"fedora-cells: {len(sys.argv) - 1} workflows, {len(errs)} findings")
sys.exit(1 if errs else 0)
PY
