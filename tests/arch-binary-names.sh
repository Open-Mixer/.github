#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# build-deb.yml and build-rpm.yml take arch-binary-names: a package whose binaries differ by architecture (a records
# set built for the one machine class it was measured on) names each architecture's binaries, and every step of a
# matrix job that checks or installs the binaries reads that architecture's names, falling back to binary-names. A
# step that read binary-names alone would demand an arm64-only binary on amd64 and fail the build. The sabotage puts
# one step back on binary-names and must be red.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/check.py" <<'PY'
import sys, yaml
f = sys.argv[1]; d = yaml.safe_load(open(f))
on = d.get(True) or d.get("on")
inputs = on["workflow_call"]["inputs"]
assert inputs["arch-binary-names"]["default"] == "{}", f"{f}: arch-binary-names must default to an empty object"
per_arch = "${{ fromJSON(inputs.arch-binary-names)[matrix.arch] || inputs.binary-names }}"
seen = 0
for name, job in d["jobs"].items():
    in_matrix = "arch" in (((job.get("strategy") or {}).get("matrix")) or {})
    for step in job.get("steps") or []:
        b = (step.get("env") or {}).get("BINARIES")
        if b is None:
            continue
        if in_matrix:
            assert b == per_arch, f"{f}: job {name}, step {step.get('name')!r} reads {b}, not the architecture's names"
            seen += 1
assert seen >= 2, f"{f}: {seen} matrix steps read the binaries; the build check and the install check both must"
print(f"ok   {f.split('/')[-1]}: {seen} matrix steps read the architecture's binaries")
PY
for w in build-deb build-rpm; do
  python3 -I "$t/check.py" "$here/.github/workflows/$w.yml" || fail=1
done
for w in build-deb build-rpm; do
  python3 - "$here/.github/workflows/$w.yml" "$t/$w.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("${{ fromJSON(inputs.arch-binary-names)[matrix.arch] || inputs.binary-names }}", "${{ inputs.binary-names }}", 1)
open(sys.argv[2], "w").write(s)
PY
  if python3 -I "$t/check.py" "$t/$w.yml" >/dev/null 2>&1; then echo "FAIL sabotage: $w with a step on binary-names alone passes"; fail=1
  else echo "ok   sabotage: $w with a step on binary-names alone is red"; fi
done
exit $fail
