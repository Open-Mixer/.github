#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The install-check cells of a DEB release are the build cells, offline: build-deb.yml's build and verify jobs take
# strategy.matrix.include from the same fromJSON(needs.preflight.outputs.cells), the cells release-matrix computed from
# quick.txt, so a quick set of trixie arm64 yields no amd64 install cell (plugin-qualify#121: "Artifact not found
# plugin-qualify-debs-trixie-amd64" came from a caller's own hand-written install matrix, not from here). Also: with the
# quick set, release-matrix's deb cells hold no amd64 cell.
# Sabotage: a verify job with a literal amd64 cell, or one reading other cells, goes red.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
wf=${BUILD_DEB_WORKFLOW:-$here/.github/workflows/build-deb.yml}
cat > "$t/check.py" <<'PY'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1]))["jobs"]
want = "${{ fromJSON(needs.preflight.outputs.cells) }}"
for name in ("build", "verify"):
    inc = j[name]["strategy"]["matrix"].get("include")
    assert inc == want, f"{name}: matrix include is {inc!r}, not the preflight cells"
    assert set(j[name]["strategy"]["matrix"]) == {"include"}, f"{name}: another matrix dimension beside the cells"
PY
python3 -I "$t/check.py" "$wf" && echo "ok   build and install cells are one matrix" || { echo "FAIL build and install cells differ"; exit 1; }
out=$(KIND=deb RELEASES='["trixie"]' ARCHES='["amd64", "arm64"]' MATRIX=quick WAVE='' STAGED='' SOURCE_REF='' CATCH_UP='' EVENT='' REF_TYPE='' \
    GITHUB_OUTPUT=/dev/stdout "$here/.github/actions/release-matrix/matrix.sh" | sed -n 's/^cells=//p')
if grep -q amd64 <<< "$out"; then echo "FAIL quick deb cells hold amd64: $out"; exit 1; else echo "ok   quick deb cells: $out"; fi
sed '/^  verify:/,$ s|include: ${{ fromJSON(needs.preflight.outputs.cells) }}|include: [{suite: trixie, arch: amd64}]|' "$wf" > "$t/sab.yml"
if BUILD_DEB_WORKFLOW=$t/sab.yml bash "$0" >/dev/null 2>&1; then echo "FAIL sabotage: a literal amd64 install cell passes"; exit 1; else echo "ok   sabotage: a literal amd64 install cell is red"; fi
