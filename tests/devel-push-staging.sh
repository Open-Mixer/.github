#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A merge to devel builds the REAL package once and publishes it to the staging channel, and that build is what the
# promotion copies to the channel root, byte for byte (owner, 2026-11-25; .github#289). Offline:
#   1. build-rpm.yml and build-deb.yml, their conditions evaluated for each kind of run: a push to devel reads its
#      version, publishes (require-tag off, devel-version set), builds the real version (real: true) on the full
#      matrix and runs the step that publishes to staging, never the real channel's jobs; a pull request into devel
#      publishes nothing; a tag publishes the release as before; a staged dispatch stays a +git snapshot (real: false).
#   2. already-served.sh, as the preflight runs it for a merge to devel (STAGING=true): a version the channel root or
#      staging holds is refused by name; a version neither holds passes; without STAGING, staging is not read.
#   3. collect.py, the promotion's first step, over a staging tree holding the real package of a merge to devel: it
#      reports commit "real" and copies every file with the checksum the staged file has; a staging tree holding the
#      real package and a snapshot of the same version is refused.
#   4. trigger-gate's self-test (a push limited to devel passes, any other branch is refused).
#   build-devel-real.sh, in a Fedora container, builds the real NEVRA with build-rpm.sh -r.
#
#   devel-push-staging.sh [root]
set -euo pipefail
root=$(readlink -f "${1:-$(dirname "$(readlink -f "$0")")/..}")
python3 -I - "$root/.github/workflows/build-rpm.yml" "$root/.github/workflows/build-deb.yml" <<'PY'
import re, sys, yaml

def ev(expr, ctx):
    """The GitHub expression subset these conditions use: names, 'strings', true/false, ==, !=, !, &&, ||, (), and
    startsWith(a, b), cancelled(), always()."""
    e = str(expr).strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2]
    toks = re.findall(r"startsWith|cancelled\(\)|always\(\)|\(|\)|,|==|!=|&&|\|\||!|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*", e)
    out = []
    for t in toks:
        if t == "&&": out.append(" and ")
        elif t == "||": out.append(" or ")
        elif t == "!": out.append(" not ")
        elif t == "startsWith": out.append(" sw")
        elif t == "cancelled()": out.append(" False ")
        elif t == "always()": out.append(" True ")
        elif t in ("==", "!=", "(", ")", ","): out.append(f" {t} ")
        elif t.startswith("'"): out.append(repr(t[1:-1]))
        elif t in ("true", "false"): out.append(repr(t == "true"))
        else:
            if t not in ctx: raise SystemExit(f"FAIL: the expression names {t}, which the test does not model: {expr}")
            out.append(repr(ctx[t]))
    # GitHub's || and && return an operand, not a boolean: Python's or/and do the same
    return eval("".join(out), {"__builtins__": {}, "sw": lambda a, b: str(a).lower().startswith(str(b).lower())})

def truthy(v):
    return v not in (False, None, "", "false", 0)

RUNS = {
    # name: event, ref, base_ref, inputs.staged, inputs.publish
    "a push to devel": ("push", "refs/heads/devel", "", False, False),
    "a pull request into devel": ("pull_request", "refs/pull/1/merge", "devel", False, False),
    "a push of a tag": ("push", "refs/tags/v1.2.0", "", False, True),
    "a push to main": ("push", "refs/heads/main", "", False, False),
    "a staged dispatch": ("workflow_dispatch", "refs/heads/devel", "", True, False),
}
fails = []
for wf in sys.argv[1:]:
    kind = "rpm" if wf.endswith("build-rpm.yml") else "deb"
    jobs = yaml.safe_load(open(wf))["jobs"]

    def ctx(run):
        event, ref, base, staged, publish = RUNS[run]
        return {"github.event_name": event, "github.ref": ref, "github.base_ref": base, "inputs.staged": staged,
                "inputs.publish": publish, "inputs.staging": False, "inputs.matrix": "", "inputs.stage": "all",
                "inputs.bootstrap-only": False, "inputs.verify-install": True,
                "needs.preflight.result": "success", "needs.preflight.outputs.count": "1", "needs.build.result": "success",
                "needs.publish.result": "success", "needs.publish-release.result": "skipped"}

    def step(job, pred):
        hits = [s for s in jobs[job]["steps"] if pred(s)]
        if len(hits) != 1:
            fails.append(f"{wf}: {len(hits)} matching steps in {job}"); return None
        return hits[0]

    devel = step("preflight", lambda s: s.get("id") == "devel")
    pre = step("preflight", lambda s: str(s.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/release-preflight@"))
    mtx = step("preflight", lambda s: s.get("id") == "matrix")
    build = step("build", lambda s: str(s.get("uses", "")).startswith(f"Open-Mixer/.github/.github/actions/build-{kind}@"))
    pubs = [s for s in jobs["publish"]["steps"] if str(s.get("uses", "")).startswith(f"Open-Mixer/.github/.github/actions/publish-{kind}s@")]
    staging_pub = [s for s in pubs if truthy(s.get("with", {}).get("staging"))]
    if None in (devel, pre, mtx, build) or len(staging_pub) != 1:
        fails.append(f"{wf}: the steps under test are not all found (publish-{kind}s with staging: {len(staging_pub)})"); continue
    staging_pub = staging_pub[0]
    if str(pre["with"].get("devel-version")) != "${{ steps.devel.outputs.version }}":
        fails.append(f"{wf}: release-preflight's devel-version is {pre['with'].get('devel-version')}, not the version the devel step read")
    want = {  # run: devel step, preflight publish, require-tag, real, matrix full, staging publish, publish job, real channel
        "a push to devel":           (True,  True,  False, True,  True,  True,  True,  False),
        "a pull request into devel": (False, False, True,  False, False, False, True,  False),
        "a push of a tag":           (False, True,  True,  False, False, False, False, True),
        "a push to main":            (False, False, True,  False, False, False, True,  False),
        "a staged dispatch":         (False, True,  False, False, False, True,  True,  False),
    }
    for run, w in want.items():
        c = ctx(run)
        got = (truthy(ev(devel["if"], c)), truthy(ev(pre["with"]["publish"], c)), truthy(ev(pre["with"]["require-tag"], c)),
               truthy(ev(build["with"]["real"], c)), ev(mtx["with"]["matrix"], c) == "full",
               truthy(ev(staging_pub["if"], c)), truthy(ev(jobs["publish"]["if"], c)),
               truthy(ev(jobs["publish-go"]["if"], c)))
        names = ("reads the devel version", "preflight publish", "require-tag", "real build", "full matrix",
                 "publishes to staging", "the publish job runs", "the real channel's publish runs")
        for n, g, x in zip(names, got, w):
            if g != x: fails.append(f"{wf}: {run}: {n}={g}, want {x}")
if fails:
    print("\n".join(f"FAIL: {f}" for f in fails), file=sys.stderr); sys.exit(1)
print("a push to devel publishes the real build to staging; a pull request publishes nothing; tags unchanged: ok")
PY

t=$(mktemp -d "${TMPDIR:-/tmp}/devel-push-staging.XXXXXX"); trap 'rm -rf -- "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---- 2. the already-published version
served=$root/.github/actions/release-preflight/already-served.sh
printf '%s\n' rpm/fedora/45/x86_64/omx-a-1.1.0-1.fc45.x86_64.rpm staging/rpm/fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm \
    staging/deb/debian/trixie/omx-a_1.2.0_amd64.deb > "$t/tree"
STAGING=true bash "$served" v1.2.0 omx-a < "$t/tree" > "$t/out" 2>&1 && { cat "$t/out"; fail "a merge to devel of a version staging holds passed"; }
grep -q 'v1.2.0 is already served: staging/rpm/fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm' "$t/out" ||
    { cat "$t/out"; fail "the refusal of a staged version does not name the staged file"; }
grep -q 'a change after a published build is a new version' "$t/out" || { cat "$t/out"; fail "the refusal does not say a merge to devel needs a new version"; }
STAGING=true bash "$served" v1.1.0 omx-a < "$t/tree" > "$t/out" 2>&1 && { cat "$t/out"; fail "a merge to devel of a version the channel root holds passed"; }
STAGING=true bash "$served" v1.3.0 omx-a < "$t/tree" > "$t/out" 2>&1 || { cat "$t/out"; fail "a version published nowhere was refused"; }
bash "$served" v1.2.0 omx-a < "$t/tree" > "$t/out" 2>&1 || { cat "$t/out"; fail "a tag release read staging (it must not)"; }
echo "a merge to devel of a version the channel root or staging holds is refused by name; a new one passes: ok"

# ---- 3. the promotion copies the staged real package, checksum for checksum
ch=$t/channel; s=$ch/staging/rpm/fedora/45; d=$ch/staging/deb/debian/trixie
mkdir -p "$s/x86_64" "$s/aarch64" "$s/SRPMS" "$d/amd64" "$d/arm64" "$ch/rpm/fedora/45/x86_64" "$ch/deb/debian/trixie"
for f in x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm aarch64/omx-a-1.2.0-1.fc45.aarch64.rpm SRPMS/omx-a-1.2.0-1.fc45.src.rpm; do
    head -c 4096 /dev/urandom > "$s/$f"
done
head -c 4096 /dev/urandom > "$d/amd64/omx-a_1.2.0_amd64.deb"; head -c 4096 /dev/urandom > "$d/arm64/omx-a_1.2.0_arm64.deb"
collect=$root/.github/actions/promote-staged/collect.py
python3 -I "$collect" "$ch" rpm --name omx-a --version 1.2.0 --releases 45 --arches "x86_64 aarch64" --commit 0123abc --out "$t/rpm-out" > "$t/rpm.log" ||
    { cat "$t/rpm.log"; fail "the promotion refused the real package a merge to devel staged (rpm)"; }
grep -qx 'commit real' "$t/rpm.log" || { cat "$t/rpm.log"; fail "collect.py did not report the real package as commit real"; }
for f in x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm aarch64/omx-a-1.2.0-1.fc45.aarch64.rpm SRPMS/omx-a-1.2.0-1.fc45.src.rpm; do
    want=$(sha256sum < "$s/$f" | cut -d' ' -f1); base=${f#*/}
    [ "$(sha256sum < "$t/rpm-out/$base" | cut -d' ' -f1)" = "$want" ] || fail "the promoted $base is not the staged file"
    grep -q "^$want  rpm/fedora/45/$f\$" "$t/rpm-out.sha256" || fail "the promotion's checksums do not list the staged $f"
done
python3 -I "$collect" "$ch" deb --name omx-a --version 1.2.0 --releases trixie --arches "amd64 arm64" --out "$t/deb-out" > "$t/deb.log" ||
    { cat "$t/deb.log"; fail "the promotion refused the real package a merge to devel staged (deb)"; }
for a in amd64 arm64; do
    cmp -s "$d/$a/omx-a_1.2.0_$a.deb" "$t/deb-out/trixie/omx-a_1.2.0_$a.deb" || fail "the promoted omx-a_1.2.0_$a.deb is not the staged file"
done
head -c 64 /dev/urandom > "$s/x86_64/omx-a-1.2.0-1.git1700000000.0123abc.fc45.x86_64.rpm"
python3 -I "$collect" "$ch" rpm --name omx-a --version 1.2.0 --releases 45 --arches "x86_64 aarch64" --out "$t/rpm-two" > "$t/two.log" 2>&1 &&
    { cat "$t/two.log"; fail "a staging tree with the real package and a snapshot of one version was promoted"; }
grep -q 'of 2 commits' "$t/two.log" || { cat "$t/two.log"; fail "the refusal of two builds of one version does not say so"; }
echo "the promotion copies the real package a merge to devel staged, every file at the staged checksum: ok"

# ---- 4. the trigger gate lets the release workflow run on a push to devel, and on no other branch
bash "$root/.github/actions/trigger-gate/check.sh" --self-test >/dev/null || fail "trigger-gate's self-test"
echo "trigger-gate: a push to devel passes, any other branch is refused: ok"
echo "devel-push-staging: all passed"
