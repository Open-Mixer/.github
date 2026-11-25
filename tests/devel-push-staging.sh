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
    toks = re.findall(r"startsWith|format|cancelled\(\)|always\(\)|\(|\)|,|==|!=|&&|\|\||!|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*", e)
    out = []
    for t in toks:
        if t == "&&": out.append(" and ")
        elif t == "||": out.append(" or ")
        elif t == "!": out.append(" not ")
        elif t == "startsWith": out.append(" sw")
        elif t == "format": out.append(" fmt")
        elif t == "cancelled()": out.append(" False ")
        elif t == "always()": out.append(" True ")
        elif t in ("==", "!=", "(", ")", ","): out.append(f" {t} ")
        elif t.startswith("'"): out.append(repr(t[1:-1]))
        elif t in ("true", "false"): out.append(repr(t == "true"))
        else:
            if t not in ctx: raise SystemExit(f"FAIL: the expression names {t}, which the test does not model: {expr}")
            out.append(repr(ctx[t]))
    # GitHub's || and && return an operand, not a boolean: Python's or/and do the same
    return eval("".join(out), {"__builtins__": {}, "sw": lambda a, b: str(a).lower().startswith(str(b).lower()),
                                        "fmt": lambda f, *a: f.format(*a)})

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
                "inputs.publish": publish, "inputs.staging": False, "github.repository": "Open-Mixer/omx-a",
                "inputs.target-repo": "Open-Mixer/open-mixer.github.io", "github.run_id": "4242", "inputs.matrix": "", "inputs.stage": "all",
                "inputs.bootstrap-only": False, "inputs.verify-install": True,
                "needs.preflight.result": "success", "needs.preflight.outputs.count": "1", "needs.build.result": "success",
                "needs.publish.result": "success", "needs.publish-release.result": "skipped",
                "steps.devel.outputs.version": "1.2.0" if run in ("a push to devel", "a staged dispatch") else ""}

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
    want = {  # run: devel step, preflight publish, require-tag, real, matrix full, staging publish, publish job, real channel
        "a push to devel":           (True,  True,  False, True,  True,  True,  True,  False),
        "a pull request into devel": (False, False, True,  False, False, False, True,  False),
        "a push of a tag":           (False, True,  True,  False, False, False, False, True),
        "a push to main":            (False, False, True,  False, False, False, True,  False),
        "a staged dispatch":         (True,  True,  False, False, False, True,  True,  False),
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
        # the version the devel step read goes to the preflight as devel-version for a merge to devel, as staged-version
        # (a real build of it refuses the snapshot, F3) for a staged dispatch, and as neither for any other run
        dv, sv = (str(ev(pre["with"].get(k, "''"), c)) for k in ("devel-version", "staged-version"))
        jdv = str(ev(jobs["preflight"]["outputs"]["devel-version"], c))
        want_v = {"a push to devel": ("1.2.0", ""), "a staged dispatch": ("", "1.2.0")}.get(run, ("", ""))
        if (dv, sv) != want_v or jdv != want_v[0]:
            fails.append(f"{wf}: {run}: devel-version={dv!r} (job output {jdv!r}), staged-version={sv!r}, want {want_v}")
        # F2: a merge to devel refuses a file the channel holds, and publishes in a group of its repository and kind
        refuse = truthy(ev(staging_pub["with"].get("refuse-served", "false"), c))
        if refuse != (run == "a push to devel"):
            fails.append(f"{wf}: {run}: the staging publish's refuse-served={refuse}")
        group = re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(ev(m.group(1), c)), str(jobs["publish"]["concurrency"]["group"]))
        want_group = {"a push to devel": f"devel-publish-Open-Mixer/omx-a-{kind}",
                      "a staged dispatch": "publish-Open-Mixer/open-mixer.github.io-live"}.get(run, "publish-Open-Mixer/open-mixer.github.io-4242")
        if group != want_group:
            fails.append(f"{wf}: {run}: the publish job's concurrency group is {group}, want {want_group}")
        if str(jobs["publish"]["concurrency"].get("cancel-in-progress")).lower() != "false":
            fails.append(f"{wf}: the publish job cancels a publish in progress")
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

# ---- 5. the version a merge to devel publishes is read by the packaging tool, not by a text match (F6b): a spec whose
#      Version is a macro gives its value, and a debian/changelog entry 1.2.0-1 gives 1.2.0, the version a channel file
#      name and a v<version> tag carry. The preflight's own step is run, with stub tools where the desk has none.
step=$root/tests/run_step.py
mkdir -p "$t/bin" "$t/vt/packaging" "$t/vt/debian"
command -v dpkg-parsechangelog >/dev/null || cat > "$t/bin/dpkg-parsechangelog" <<'STUB'
#!/bin/bash
# the one call tree-version.sh makes: -l <changelog> -S Version
f=debian/changelog; while [ $# -gt 0 ]; do case $1 in -l) f=$2; shift ;; esac; shift; done
sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$f"
STUB
chmod +x "$t/bin/"* 2>/dev/null || true
printf '%%global upstream 1.2.0\nName: omx-a\nVersion: %%{upstream}\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\n%%description\nt\n' \
    > "$t/vt/packaging/omx-a.spec"
printf 'omx-a (1.2.0-1) trixie; urgency=medium\n\n  * t\n\n -- T <t@example.org>  Tue, 25 Nov 2026 12:00:00 +0000\n' > "$t/vt/debian/changelog"
for kind in rpm deb; do
    python3 -I "$step" "$root" "$root/.github/workflows/build-$kind.yml" preflight id=devel "$t/devel-$kind.sh"
    : > "$t/out-$kind"
    (cd "$t/vt" && PATH=$t/bin:$PATH GITHUB_OUTPUT=$t/out-$kind bash "$t/devel-$kind.sh") > "$t/log-$kind" 2>&1 ||
        { cat "$t/log-$kind"; fail "build-$kind.yml: the devel version step failed on a tree packaging 1.2.0"; }
    got=$(sed -n 's/^version=//p' "$t/out-$kind")
    [ "$got" = 1.2.0 ] || { cat "$t/log-$kind"; fail "build-$kind.yml: a merge to devel reads version '$got' from a tree packaging 1.2.0"; }
done
echo "the version of a merge to devel is the spec's expanded Version and the changelog's without its revision: ok"

# ---- 6. promote-staged's install checks take the real package when the find job says the promoted build is real (F1):
#      verify-rpm requires %{VERSION} = the version and a release with no .git, verify-deb pins the exact version with
#      no +git from madison; a snapshot is checked by its commit as before. Each step's own text runs over stub
#      dnf/rpm/apt-get/apt-cache, the channel holding the real 1.2.0 beside a snapshot of it.
pw=$root/.github/workflows/promote-staged.yml
mkdir -p "$t/pbin"
cat > "$t/pbin/dnf" <<'STUB'
#!/bin/bash
case $1 in
  install) echo "$*" >> "$STATE/dnf.log" ;;
  repoquery) echo openmixer ;;
esac
exit 0
STUB
cat > "$t/pbin/rpm" <<'STUB'
#!/bin/bash
# rpm -q --qf '%{RELEASE}' <bin> | '%{VERSION}' <bin>: the build the stub channel installed
case "$*" in *RELEASE*) printf '%s' "$RPM_RELEASE" ;; *VERSION*) printf '%s' "$RPM_VERSION" ;; esac
STUB
cat > "$t/pbin/apt-cache" <<'STUB'
#!/bin/bash
# madison: newest first, as apt prints it
printf ' %s | %s | https://www.openmixer.org/deb/debian/trixie ./ Packages\n' "$2" 1.2.0+git1700000000.0123abc "$2" 1.2.0 "$2" 1.1.0
STUB
cat > "$t/pbin/apt-get" <<'STUB'
#!/bin/bash
[ "$1" = update ] && exit 0
echo "$*" >> "$STATE/apt.log"
STUB
printf '#!/bin/bash\nexit 0\n' > "$t/pbin/sleep"
printf '#!/bin/bash\necho "$4 installed"\n' > "$t/pbin/dpkg-query"
chmod +x "$t/pbin/"*
python3 -I "$step" "$root" "$pw" verify-rpm "name=Install the promoted version from the channel" "$t/vrpm.sh"
python3 -I "$step" "$root" "$pw" verify-deb "name=Install the promoted version from the channel" "$t/vdeb.sh"
grep -qF 'REAL: ${{ needs.find.outputs.real }}' <(python3 -I -c 'import sys, yaml; j = yaml.safe_load(open(sys.argv[1]))["jobs"]
for n in ("verify-rpm", "verify-deb"):
    for s in j[n]["steps"]:
        if s.get("name") == "Install the promoted version from the channel": print(n, s["env"].get("REAL"))
print(j["find"]["outputs"].get("real"))' "$pw" | sed 's/^verify-[a-z]* /REAL: /') ||
    fail "promote-staged.yml: the install checks do not read the find job's real output"
vcheck() { # vcheck <rpm|deb> <real> <short> <rpm release> -> exit status; logs in $t/v.out, $t/state
    rm -rf "$t/state"; mkdir -p "$t/state"
    STATE=$t/state PATH=$t/pbin:$PATH REAL=$2 SHORT=$3 RPM_RELEASE=$4 RPM_VERSION=1.2.0 VERSION=1.2.0 NAME=omx-a BINARIES=omx-a \
        BASE_URL=https://www.openmixer.org URL=https://www.openmixer.org/deb SUITE=trixie bash "$t/v$1.sh" > "$t/v.out" 2>&1
}
vcheck rpm true 0123abc 1.fc45 || { cat "$t/v.out"; fail "verify-rpm refused the real omx-a 1.2.0-1.fc45 a real promotion installs"; }
vcheck rpm true 0123abc 1.git1700000000.0123abc.fc45 && { cat "$t/v.out"; fail "verify-rpm took a snapshot for the real package"; }
vcheck rpm false 0123abc 1.git1700000000.0123abc.fc45 || { cat "$t/v.out"; fail "verify-rpm refused the snapshot of the commit a snapshot promotion installs"; }
vcheck rpm false 0123abc 1.fc45 && { cat "$t/v.out"; fail "verify-rpm took the real package for a snapshot promotion"; }
vcheck deb true 0123abc - || { cat "$t/v.out"; fail "verify-deb found no real omx-a 1.2.0 to install"; }
grep -qx 'install -y --no-install-recommends omx-a=1.2.0' "$t/state/apt.log" || { cat "$t/state/apt.log"; fail "verify-deb did not pin the real omx-a=1.2.0"; }
vcheck deb false 0123abc - || { cat "$t/v.out"; fail "verify-deb found no snapshot of the commit"; }
grep -qx 'install -y --no-install-recommends omx-a=1.2.0+git1700000000.0123abc' "$t/state/apt.log" || { cat "$t/state/apt.log"; fail "verify-deb did not pin the snapshot of the commit"; }
echo "promote-staged's install checks take the real package of a real promotion, and the snapshot of its commit otherwise: ok"

# ---- 7. a merge to devel REFUSES a file the channel already holds, never keeps it (F2): with REFUSE_SERVED=true both
#      tree scripts check every file up front and refuse, naming each one, before anything is placed or signed. The
#      staging publish step of each workflow passes refuse-served for a push to devel alone (section 1 evaluates it).
for kind in rpm deb; do
    tr=$t/refuse-$kind; rm -rf "$tr"; mkdir -p "$tr/src/trixie"
    if [ "$kind" = rpm ]; then
        held=fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm; held2=fedora/45/SRPMS/omx-a-1.2.0-1.fc45.src.rpm
        new=omx-a-devel-1.2.0-1.fc45.x86_64.rpm; srcd=$tr/src
    else
        held=debian/trixie/amd64/omx-a_1.2.0_amd64.deb; held2=debian/trixie/all/omx-a-data_1.2.0_all.deb
        new=omx-a-dev_1.2.0_amd64.deb; srcd=$tr/src/trixie
    fi
    mkdir -p "$tr/tree/$(dirname "$held")" "$tr/tree/$(dirname "$held2")"
    echo served > "$tr/tree/$held"; echo served > "$tr/tree/$held2"
    echo rebuilt > "$srcd/$(basename "$held")"; echo rebuilt > "$srcd/$(basename "$held2")"; echo new > "$srcd/$new"
    # the same deb file name in another suite is not this suite's file
    [ "$kind" = rpm ] || { mkdir -p "$tr/tree/debian/bookworm/amd64"; echo other > "$tr/tree/debian/bookworm/amd64/$new"; }
    REFUSE_SERVED=true bash "$root/.github/actions/publish-${kind}s/publish-tree.sh" "$tr/tree" "$tr/src" > "$tr/log" 2>&1 &&
        { cat "$tr/log"; fail "publish-${kind}s: a merge to devel over files the channel holds was published"; }
    for h in "$held" "$held2"; do
        grep -qF "refused $h: the channel holds it already" "$tr/log" || { cat "$tr/log"; fail "publish-${kind}s: the refusal does not name $h"; }
        [ "$(cat "$tr/tree/$h")" = served ] || fail "publish-${kind}s: the served $h was replaced"
    done
    grep -qF "refused" <(grep -F "$new" "$tr/log") && fail "publish-${kind}s: $new, which the channel does not hold, was refused"
    [ ! -e "$tr/tree/$(dirname "$held")/$new" ] || fail "publish-${kind}s: $new was placed although the run refused"
done
python3 -I - "$root" <<'PY2' || fail "a publish action does not hand refuse-served to its tree script and its lost-race rebuild"
import sys, yaml
for kind in ("rpm", "deb"):
    steps = yaml.safe_load(open(f"{sys.argv[1]}/.github/actions/publish-{kind}s/action.yml"))["runs"]["steps"]
    hits = [s for s in steps if s.get("env", {}).get("REFUSE_SERVED_IN") == "${{ inputs.refuse-served }}"
            and 'echo "REFUSE_SERVED=$REFUSE_SERVED_IN" >> "$GITHUB_ENV"' in s.get("run", "")]
    assert len(hits) == 1, kind
PY2
echo "a merge to devel refuses, naming each, the files the channel holds already, and places nothing: ok"

# ---- 4. the trigger gate lets the release workflow run on a push to devel, and on no other branch
bash "$root/.github/actions/trigger-gate/check.sh" --self-test >/dev/null || fail "trigger-gate's self-test"
echo "trigger-gate: a push to devel passes, any other branch is refused: ok"
echo "devel-push-staging: all passed"
