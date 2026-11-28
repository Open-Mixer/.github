#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The full matrix, every package in every cell (owner ruling 2026-11-26), offline: amd64 went missing one layer at a
# time (pdq's release arches, plugin-hostd's push arch-matrix, omx-plugins' arch-matrix ["arm64"], a staged dispatch
# told nothing that built the quick set), each a line that narrowed the architectures with nothing red.
# Proves:
#   - .github/actions/release-matrix/full.txt is the four cells, fc45 x86_64 and aarch64, trixie amd64 and arm64; the
#     quick set is inside it; build-rpm.yml's and build-deb.yml's input defaults (fedora-versions, suite-matrix,
#     arch-matrix) and check-matrix's (rpm-arches, deb-arches) are exactly its releases and architectures;
#   - tools/arch-coverage.py, on fixture callers rendered through this tree's build-rpm.yml, build-deb.yml and
#     matrix.sh: a caller that passes nothing covers every cell on a merge to devel, a tag and a staged dispatch (exit
#     0); an arch-matrix of ["arm64"] is ARCH-NARROW naming the job, the run and amd64; a dispatch whose matrix input
#     defaults to quick is ARCH-NARROW on its staged run; the pull request dry-run guard (event != push && arm false)
#     is not; a job that builds its own rpm for x86_64 alone in a fedora container (mod-host) is ARCH-NARROW naming
#     aarch64; a .github/release-matrix.json (plugin-qualify) or packaging/release-arches (plugin-db-qualification)
#     that declares fewer architectures is ARCH-NARROW; a caller whose cells come from another job is DERIVED and named,
#     never a silent pass; a target with no workflow is exit 2;
#   - sabotage, each on a copy: the coverage comparison of the tool disabled (the arm64-only caller passes), the
#     own-build comparison disabled (mod-host passes), a shared tree whose staged default is quick again (the caller
#     that passes nothing goes red on its staged run), a shared tree whose deb arch-matrix default is ["arm64"] (the
#     defaults check and the caller both go red).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }
tool=$here/tools/arch-coverage.py

# ---- the declaration and the defaults that restate it
defaults() { # <shared tree>: the defaults check, exit 1 naming a default that is not full.txt
python3 -I - "$1" <<'PY'
import sys, yaml
root = sys.argv[1]
full = [l.split() for l in open(f"{root}/.github/actions/release-matrix/full.txt") if l.split() and not l.startswith("#")]
assert full == [["rpm", "45", "x86_64"], ["rpm", "45", "aarch64"], ["deb", "trixie", "amd64"], ["deb", "trixie", "arm64"]], f"full.txt is {full}"
quick = [l.split() for l in open(f"{root}/.github/actions/release-matrix/quick.txt") if l.split() and not l.startswith("#")]
assert all(q in full for q in quick), f"quick.txt {quick} is not inside full.txt"
rel = lambda k: sorted({c[1] for c in full if c[0] == k})
arch = lambda k: sorted({c[2] for c in full if c[0] == k})
bad = []
for wf, k, rin in (("build-rpm.yml", "rpm", "fedora-versions"), ("build-deb.yml", "deb", "suite-matrix")):
    d = yaml.safe_load(open(f"{root}/.github/workflows/{wf}"))
    inp = (d.get(True) or d.get("on"))["workflow_call"]["inputs"]
    for name, want in ((rin, rel(k)), ("arch-matrix", arch(k))):
        got = sorted(yaml.safe_load(inp[name]["default"]))
        if got != want:
            bad.append(f"{wf} {name} defaults to {got}, full.txt says {want}")
cm = yaml.safe_load(open(f"{root}/.github/actions/check-matrix/action.yml"))["inputs"]
for name, k in (("rpm-arches", "rpm"), ("deb-arches", "deb")):
    got = sorted(yaml.safe_load(cm[name]["default"]))
    if got != arch(k):
        bad.append(f"check-matrix {name} defaults to {got}, full.txt says {arch(k)}")
print("\n".join(bad) if bad else "the defaults are full.txt")
sys.exit(1 if bad else 0)
PY
}
if out=$(defaults "$here"); then yes "full.txt is the four cells, quick.txt is inside it, and every shared default is full.txt"; else no "$out"; fi

# ---- fixture callers
caller() { # <dir> <deb with-lines> [<dispatch inputs>]
    mkdir -p "$1/.github/workflows"
    cat > "$1/.github/workflows/release.yml" <<EOF
name: release
on:
  push:
    tags: ['v*']
    branches: [devel]
  workflow_dispatch:
    inputs:
      staged:
        type: boolean
        default: false
      arm:
        type: boolean
        default: true
${3:-}
jobs:
  rpm:
    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1
    with:
      staged: \${{ inputs.staged == true }}
      package-name: x
      publish: \${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/') }}
    secrets: inherit
  deb:
    uses: Open-Mixer/.github/.github/workflows/build-deb.yml@openmixer-v1
    with:
      staged: \${{ inputs.staged == true }}
      package-name: x
      publish: \${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/') }}
$2
    secrets: inherit
EOF
}
rc() { "$@" > "$t/out" 2>&1 && echo 0 || echo $?; }
cov() { python3 -I "$tool" "$@"; }

caller "$t/plain" ""
[ "$(rc cov "$t/plain")" = 0 ] && grep -q "6 publishing run(s) rendered" "$t/out" \
    && yes "a caller that passes nothing covers every cell on a merge to devel, a tag and a staged dispatch" || { no "plain caller"; cat "$t/out"; }

caller "$t/arm64" "      arch-matrix: '[\"arm64\"]'"
[ "$(rc cov "$t/arm64")" = 1 ] && grep -q "ARCH-NARROW $t/arm64/.github/workflows/release.yml: job deb (push-devel): deb trixie builds arm64 (full), lacks amd64" "$t/out" \
    && grep -q "job deb (tag): .*lacks amd64" "$t/out" && grep -q "job deb (staged): .*lacks amd64" "$t/out" \
    && yes "an arch-matrix of [\"arm64\"] (omx-plugins) is ARCH-NARROW on every publishing run, naming amd64" || { no "arm64 caller"; cat "$t/out"; }

caller "$t/quickdefault" "      matrix: \${{ inputs.matrix }}" "      matrix:
        type: choice
        options: [quick, full]
        default: quick"
[ "$(rc cov "$t/quickdefault")" = 1 ] && grep -q "job deb (staged): deb trixie builds arm64 (quick), lacks amd64" "$t/out" \
    && ! grep -q "(push-devel)" "$t/out" \
    && yes "a dispatch whose matrix input defaults to quick (omx-contract, omx-dsp) is ARCH-NARROW on its staged run alone" || { no "quick default"; cat "$t/out"; }

caller "$t/prguard" "      arch-matrix: \${{ (github.event_name != 'push' && inputs.arm == false) && '[\"amd64\"]' || '[\"amd64\", \"arm64\"]' }}"
[ "$(rc cov "$t/prguard")" = 0 ] \
    && yes "the pull request dry-run guard (event != push && arm false) narrows no publishing run" || { no "pr guard"; cat "$t/out"; }

caller "$t/derived" "      arch-matrix: \${{ needs.plan.outputs.deb-arches }}"
[ "$(rc cov "$t/derived")" = 0 ] && grep -q "DERIVED $t/derived/.github/workflows/release.yml: job deb (tag): its cells come from another job (arch-matrix: needs.plan.outputs.deb-arches)" "$t/out" \
    && yes "cells from another job are DERIVED and named, never a silent pass" || { no "derived"; cat "$t/out"; }

mkdir -p "$t/own/.github/workflows"
cat > "$t/own/.github/workflows/release.yml" <<'EOF'
name: release
on:
  push:
    tags: ['v*']
jobs:
  rpm:
    strategy:
      matrix:
        arch: [x86_64]
        fedora: [45]
    runs-on: ubuntu-latest
    container: fedora:${{ matrix.fedora }}
    steps:
      - run: true
  deb:
    strategy:
      matrix:
        arch: [amd64, arm64]
        suite: [trixie]
    runs-on: ubuntu-latest
    container: debian:${{ matrix.suite }}
    steps:
      - run: true
EOF
[ "$(rc cov "$t/own")" = 1 ] && grep -q "job rpm (tag): builds its own rpm for x86_64, lacks aarch64" "$t/out" && ! grep -q "job deb" "$t/out" \
    && yes "a job that builds its own rpm for x86_64 alone (mod-host) is ARCH-NARROW naming aarch64; its full deb job is not" || { no "own build"; cat "$t/out"; }

caller "$t/decl" ""
printf '{"rpm": {"fedora": ["45"], "arches": ["x86_64"]}, "deb": {"suites": ["trixie"], "arches": ["arm64"]}}\n' > "$t/decl/.github/release-matrix.json"
[ "$(rc cov "$t/decl")" = 1 ] && grep -q "release-matrix.json: rpm 45 declares \['x86_64'\], lacks aarch64" "$t/out" \
    && grep -q "release-matrix.json: deb trixie declares \['arm64'\], lacks amd64" "$t/out" \
    && yes "a release-matrix.json that declares fewer architectures (plugin-qualify) is ARCH-NARROW" || { no "decl"; cat "$t/out"; }

caller "$t/ra" ""
mkdir -p "$t/ra/packaging"; printf '# arches\ndeb arm64\nrpm x86_64 aarch64\n' > "$t/ra/packaging/release-arches"
[ "$(rc cov "$t/ra")" = 1 ] && grep -q "release-arches: deb releases arm64, lacks amd64" "$t/out" && ! grep -q "rpm releases" "$t/out" \
    && yes "a packaging/release-arches that releases fewer architectures (plugin-db-qualification) is ARCH-NARROW" || { no "release-arches"; cat "$t/out"; }

mkdir -p "$t/empty"
[ "$(rc cov "$t/empty")" = 2 ] && grep -q "UNCHECKED" "$t/out" && yes "a target with no workflow is not measured (exit 2)" || { no "empty target"; cat "$t/out"; }

# ---- sabotage, each on a copy
mkdir -p "$t/sab"
sed 's/if want and missing:  # COVERAGE-MARK/if False:  # COVERAGE-MARK/' "$tool" > "$t/sab/cov.py"
[ "$(diff "$tool" "$t/sab/cov.py" | grep -c '^>')" = 1 ] || no "sabotage setup: the coverage mark"
[ "$(rc python3 -I "$t/sab/cov.py" --shared "$here" "$t/arm64")" = 0 ] \
    && yes "sabotage: the coverage comparison disabled, the arm64-only caller passes (the arm above catches it)" || { no "coverage sabotage went unseen"; cat "$t/out"; }
sed 's/if missing:  # OWN-MARK/if False:  # OWN-MARK/' "$tool" > "$t/sab/own.py"
[ "$(diff "$tool" "$t/sab/own.py" | grep -c '^>')" = 1 ] || no "sabotage setup: the own mark"
[ "$(rc python3 -I "$t/sab/own.py" --shared "$here" "$t/own")" = 0 ] \
    && yes "sabotage: the own-build comparison disabled, mod-host's x86_64-only rpm passes (the arm above catches it)" || { no "own sabotage went unseen"; cat "$t/out"; }
mkdir -p "$t/shared-quick"; cp -r "$here/.github" "$t/shared-quick/"
python3 -I - "$t/shared-quick/.github/actions/release-matrix/matrix.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'set=${wave:-full} source="a staged run"'
assert s.count(old) == 1, "sabotage setup: the staged default"
open(p, "w").write(s.replace(old, 'set=quick source="a staged run"'))
PY
[ "$(rc cov --shared "$t/shared-quick" "$t/plain")" = 1 ] && grep -q "job deb (staged): deb trixie builds arm64 (quick), lacks amd64" "$t/out" \
    && grep -q "job rpm (staged): rpm 45 builds x86_64 (quick), lacks aarch64" "$t/out" \
    && yes "sabotage: a shared staged default of quick again turns the caller that passes nothing red on its staged run" || { no "shared quick sabotage went unseen"; cat "$t/out"; }
mkdir -p "$t/shared-arm"; cp -r "$here/.github" "$t/shared-arm/"
python3 -I - "$t/shared-arm/.github/workflows/build-deb.yml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      arch-matrix:\n        type: string\n        default: '[\"amd64\", \"arm64\"]'\n"
assert s.count(old) == 1, "sabotage setup: the deb arch default"
open(p, "w").write(s.replace(old, "      arch-matrix:\n        type: string\n        default: '[\"arm64\"]'\n"))
PY
if defaults "$t/shared-arm" > "$t/out" 2>&1; then no "sabotage: a deb arch-matrix default of [\"arm64\"] passed the defaults check"; else
    grep -q "build-deb.yml arch-matrix defaults to \['arm64'\]" "$t/out" && yes "sabotage: a deb arch-matrix default of [\"arm64\"] is named by the defaults check" || { no "defaults sabotage"; cat "$t/out"; }; fi
[ "$(rc cov --shared "$t/shared-arm" "$t/plain")" = 1 ] && grep -q "job deb (tag): deb trixie builds arm64 (full), lacks amd64" "$t/out" \
    && yes "  ... and the caller that passes nothing goes red with it" || { no "shared arm sabotage went unseen by the caller check"; cat "$t/out"; }

[ "$fail" = 0 ] && echo "arch-coverage: all passed" || { echo "arch-coverage: FAILED"; exit 1; }
