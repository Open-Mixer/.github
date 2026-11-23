#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The dependency floors of packaging/deps.txt are checked on the release path and on every repository that has the
# file, not only where a repository wired deps-render into its own CI (.github#237: plugin-db, omx-clap-core and
# plugin-hostd tagged-ready heads carried deps.txt floors below their specs; the check ran on pull requests alone, and
# plugin-hostd's pull request never ran it). Arms:
#   - floors.sh on a planted tree: deps.txt behind the spec and control (plugin-db's drift, omx-contract-devel 3.20.0
#     against 3.21.0) is red and names the package; the same tree in step is green; a tree with no deps.txt is green
#     and says so;
#   - release-preflight, the action build-rpm.yml and build-deb.yml run before any build, carries the floors step;
#     the step is read out of the action file and run against the planted trees, on a dry run as on a release;
#   - build-rpm.yml and build-deb.yml check the caller's tree out before release-preflight, in the preflight job every
#     build needs;
#   - public-sources-check.yml, the workflow every repository calls on its pull requests, has a job running the
#     deps-render action when packaging/deps.txt exists.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

plant() { # <dir> <deps.txt floor of omx-contract-devel>
  rm -rf "$1"; mkdir -p "$1/packaging" "$1/debian"
  printf 'omx-contract-devel  libomx-contract-dev  %s\n' "$2" > "$1/packaging/deps.txt"
  printf 'Name: t\nBuildRequires: omx-contract-devel >= 3.21.0\nRequires: omx-contract-devel >= 3.21.0\n' > "$1/packaging/t.spec"
  printf 'Source: t\nBuild-Depends: debhelper-compat (= 13), libomx-contract-dev (>= 3.21.0~)\n\nPackage: t\nDepends: ${misc:Depends}\n' > "$1/debian/control"
}
plant "$tmp/stale" 3.20.0
plant "$tmp/true" 3.21.0
mkdir -p "$tmp/none/packaging"; printf 'Name: t\nBuildRequires: gcc\n' > "$tmp/none/packaging/t.spec"

# floors.sh, the one entry both paths share
[ -x "$act/deps-render/floors.sh" ] || fail "no .github/actions/deps-render/floors.sh"
"$act/deps-render/floors.sh" "$tmp/stale" > "$tmp/out" 2>&1 && { cat "$tmp/out"; fail "floors.sh passed a deps.txt behind its spec"; }
grep -q 'omx-contract-devel at a floor other than 3.20.0' "$tmp/out" || { cat "$tmp/out"; fail "the red does not name the package"; }
grep -q '^::error[ :]' "$tmp/out" || { cat "$tmp/out"; fail "the red carries no ::error:: line"; }
"$act/deps-render/floors.sh" "$tmp/true" > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "floors.sh refused a tree in step"; }
"$act/deps-render/floors.sh" "$tmp/none" > "$tmp/out" 2>&1 || { cat "$tmp/out"; fail "floors.sh refused a tree with no deps.txt"; }
grep -q 'no packaging/deps.txt' "$tmp/out" || { cat "$tmp/out"; fail "floors.sh did not say the tree declares no floors"; }

# the release path: the step of release-preflight, read out of the action, run as the runner runs it
python3 -I - "$act/release-preflight/action.yml" "$tmp/step.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
hits = [s for s in steps if "deps-render/floors.sh" in s.get("run", "")]
if len(hits) != 1:
    sys.exit("release-preflight: %d steps run deps-render/floors.sh, want 1" % len(hits))
if "if" in hits[0]:
    sys.exit("release-preflight: the floors step is conditional (%r): a dry run and a release both check" % hits[0]["if"])
open(sys.argv[2], "w").write(hits[0]["run"])
PY
step() { GITHUB_ACTION_PATH=$act/release-preflight GITHUB_WORKSPACE=$1 bash "$tmp/step.sh" > "$tmp/out" 2>&1; }
step "$tmp/stale" && { cat "$tmp/out"; fail "release-preflight passed a deps.txt behind its spec"; }
grep -q 'omx-contract-devel at a floor other than 3.20.0' "$tmp/out" || { cat "$tmp/out"; fail "release-preflight's red does not name the package"; }
step "$tmp/true" || { cat "$tmp/out"; fail "release-preflight refused a tree in step"; }
step "$tmp/none" || { cat "$tmp/out"; fail "release-preflight refused a tree with no deps.txt"; }

# build-rpm.yml and build-deb.yml: the caller's tree is checked out before release-preflight, in preflight, which
# every build job needs
python3 -I - "$here/.github/workflows" <<'PY'
import sys, yaml
for name in ("build-rpm.yml", "build-deb.yml"):
    jobs = yaml.safe_load(open("%s/%s" % (sys.argv[1], name)))["jobs"]
    steps = jobs["preflight"]["steps"]
    uses = [s.get("uses", "") for s in steps]
    pre = [i for i, u in enumerate(uses) if "/actions/release-preflight" in u]
    co = [i for i, s in enumerate(steps) if s.get("uses", "").startswith("actions/checkout")
          and "inputs.source-repository || github.repository" in str(s.get("with", {}).get("repository", ""))]
    if not pre or not co or co[0] > pre[0]:
        sys.exit("%s: preflight does not check the caller out before release-preflight" % name)
    needs = jobs["build"].get("needs")
    if "preflight" not in ([needs] if isinstance(needs, str) else needs or []):
        sys.exit("%s: build does not need preflight" % name)
PY

# every repository's pull requests: public-sources-check.yml runs deps-render where deps.txt exists
python3 -I - "$here/.github/workflows/public-sources-check.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
for name, job in jobs.items():
    for s in job.get("steps", []):
        if "/actions/deps-render@" in s.get("uses", ""):
            if "if" in job:
                sys.exit("public-sources-check: the floors job %s is conditional (%r)" % (name, job["if"]))
            if "hashFiles('packaging/deps.txt')" not in str(s.get("if", "")):
                sys.exit("public-sources-check: the deps-render step of %s does not skip a tree with no deps.txt" % name)
            sys.exit(0)
sys.exit("public-sources-check: no job runs deps-render")
PY
echo "release-floors: a stale deps.txt is red on the release path and on every pull request, by name"
