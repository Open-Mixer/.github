#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The fedora-cells check (.github/actions/fedora-cells), offline, over fixture workflow directories. Rule 11-10 runs
# fc45 beside fc44 in every check, and ruling D25 takes every job's cells from release-matrix or check-matrix, whose
# quick.txt carries both. A Fedora release written into a job is therefore red, wherever it is written:
#   A. a job's container image (fedora:44) is red, and named with its file, job and line;
#   B. a matrix list of Fedora images or releases is red;
#   C. the whole matrix handed to check-matrix, release-matrix or build-rpm (rpm-releases:, releases:) is green;
#   D. a job that takes its cells from a plan's output (fromJSON(needs.plan.outputs.rpm)) is green;
#   E. a line marked "# tool image: <why>" is green (fedora:44 used as a toolbox over the whole repository, not a
#      cell), and a marker with no reason is red;
#   F. a directory with no workflow at all is not measured (exit 2), never green.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
check=$here/.github/actions/fedora-cells/check.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }

wf() { mkdir -p "$t/$1"; cat > "$t/$1/ci.yml"; }

wf a <<'EOF'
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container: fedora:44
    steps: [{ run: make check }]
EOF
wf b <<'EOF'
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    container: { image: '${{ matrix.image }}' }
    strategy: { matrix: { image: ["fedora:44", "debian:trixie"] } }
    steps: [{ run: make check }]
EOF
wf cd <<'EOF'
on: push
jobs:
  plan:
    runs-on: ubuntu-latest
    outputs: { rpm: '${{ steps.m.outputs.rpm }}' }
    steps:
      - id: m
        uses: Open-Mixer/.github/.github/actions/check-matrix@openmixer-v1
        with:
          wave: ${{ vars.OMX_RELEASE_MATRIX }}
          rpm-releases: '["44", "45"]'
  test:
    needs: plan
    runs-on: ubuntu-latest
    container: { image: '${{ matrix.cell.image }}' }
    strategy: { matrix: { cell: '${{ fromJSON(needs.plan.outputs.rpm) }}' } }
    steps: [{ run: make check }]
  rpm:
    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1
    with:
      releases: '["44", "45"]'
EOF
wf e <<'EOF'
on: push
jobs:
  prune:
    runs-on: ubuntu-latest
    container:
      image: fedora:44 # tool image: createrepo and rpm-sign over the whole repository, once
    steps: [{ run: ./prune.sh }]
EOF
wf e2 <<'EOF'
on: push
jobs:
  prune:
    runs-on: ubuntu-latest
    container:
      image: fedora:44 # tool image:
    steps: [{ run: ./prune.sh }]
EOF
mkdir -p "$t/f"

run() { out=$("$check" "$t/$1" 2>&1); rc=$?; }
set +e
run a; [ $rc = 1 ] && grep -q "ci.yml job test.*fedora:44" <<<"$out" && yes "A  a container fedora:44 is red, named" || no "A  exit $rc: $out"
run b; [ $rc = 1 ] && grep -q "ci.yml job test" <<<"$out" && yes "B  a matrix list of Fedora images is red" || no "B  exit $rc: $out"
run cd; [ $rc = 0 ] && yes "C,D  the matrix handed to check-matrix and build-rpm, and cells from the plan, are green" || no "C,D  exit $rc: $out"
run e; [ $rc = 0 ] && yes "E  a tool image with its reason is green" || no "E  exit $rc: $out"
run e2; [ $rc = 1 ] && grep -q "tool image" <<<"$out" && yes "E  a tool-image marker with no reason is red" || no "E  exit $rc: $out"
run f; [ $rc = 2 ] && yes "F  no workflow: not measured" || no "F  exit $rc: $out"
set -e
exit $fail
