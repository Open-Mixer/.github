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
                "steps.devel.outputs.version": "1.2.0" if run != "a push to main" and run != "a push of a tag" else "",
                "needs.preflight.outputs.skip": "false", "inputs.verify-install": True}

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
        "a pull request into devel": (True,  False, True,  False, False, False, True,  False),
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
        # F5: a merge to devel of a published version (preflight skip=true) builds, publishes and verifies nothing; the
        # pull request into devel runs the bump check, with the run's own token
        if run == "a push to devel":
            for skip, want_runs in (("true", False), ("false", True)):
                c2 = dict(c, **{"needs.preflight.outputs.skip": skip})
                for j in ("build", "publish", "verify"):
                    if truthy(ev(jobs[j]["if"], c2)) != want_runs:
                        fails.append(f"{wf}: a push to devel with skip={skip}: the {j} job runs={not want_runs}")
        bump = [x for x in jobs["preflight"]["steps"] if str(x.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/devel-bump-check@")]
        if len(bump) != 1:
            fails.append(f"{wf}: {len(bump)} devel-bump-check steps in the preflight job")
        else:
            if truthy(ev(bump[0]["if"], c)) != (run == "a pull request into devel"):
                fails.append(f"{wf}: {run}: the bump check runs={not (run == 'a pull request into devel')}")
            if bump[0]["with"].get("token") != "${{ github.token }}" or "PAGES_TOKEN" in str(bump[0]):
                fails.append(f"{wf}: the bump check does not read the channel with github.token alone")
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
# a commit never selects the real package: promote-staged ties it to its devel commit and asks for it by name (F6c)
python3 -I "$collect" "$ch" rpm --name omx-a --version 1.2.0 --releases 45 --arches "x86_64 aarch64" --commit 0123abc --out "$t/rpm-sha" > "$t/sha.log" 2>&1 &&
    { cat "$t/sha.log"; fail "collect.py took a commit sha for the real package, which names none"; }
python3 -I "$collect" "$ch" rpm --name omx-a --version 1.2.0 --releases 45 --arches "x86_64 aarch64" --commit real --out "$t/rpm-out" > "$t/rpm.log" ||
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
# shellcheck disable=SC2016 # the stub's own text
printf '#!/bin/bash\necho "$4 installed"\n' > "$t/pbin/dpkg-query"
chmod +x "$t/pbin/"*
python3 -I "$step" "$root" "$pw" verify-rpm "name=Install the promoted version from the channel" "$t/vrpm.sh"
python3 -I "$step" "$root" "$pw" verify-deb "name=Install the promoted version from the channel" "$t/vdeb.sh"
# shellcheck disable=SC2016 # an expression of the workflow, literal
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

# ---- 8. the pull request into devel is where a missing version bump is red (F5): the workflow's own bump step, run on a
#      git tree whose head changes src/ while the channel holds its version, is refused naming the path and the served
#      file; docs, *.md and .github/ alone pass; a new version passes; the channel is read with the run's github.token.
g=$t/pr; rm -rf "$g"; mkdir -p "$g/src" "$g/docs"
gitc() { git -C "$g" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
echo a > "$g/src/a.c"; echo d > "$g/docs/x.md"; echo r > "$g/README.md"
gitc init -q; gitc add -A; gitc commit -q -m base; base=$(gitc rev-parse HEAD)
cat > "$t/pbin/curl" <<'STUB'
#!/bin/bash
out=
for a in "$@"; do case $a in "Authorization: "*) echo "$a" >> "$STATE/auth" ;; esac; done
url=${*: -1}
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
case $url in
  */contents/staging/rpm/built/omx-a/1.2.0.commit) echo "$RECORD" > "$out" ;;
  */contents/*) echo '{}' > "$out"; printf 404; exit 0 ;;
  *) printf '%s' '{"truncated":false,"tree":[{"path":"staging/rpm/fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm"},{"path":"staging/rpm/built/omx-a/1.2.0.commit"},{"path":"deb/debian/trixie/amd64/omx-a_1.2.0_amd64.deb"}]}' > "$out" ;;
esac
printf 200
STUB
chmod +x "$t/pbin/curl"
bumprun() { # bumprun <kind> <version> [extra exempt globs] -> status; log in $t/bump.out
    local exempt
    rm -rf "$t/state"; mkdir -p "$t/state"
    [ -z "${3:-}" ] && exempt=$(python3 -I -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print((d.get("on") or d[True])["workflow_call"]["inputs"]["bump-exempt"]["default"])' \
        "$root/.github/workflows/build-$1.yml") || exempt=${3:-}
    python3 -I "$step" "$root" "$root/.github/workflows/build-$1.yml" preflight uses=devel-bump-check "$t/bump-$1.sh" \
        kind="$1" version="$2" name=omx-a packages=omx-a releases= exempt="$exempt" target=Open-Mixer/open-mixer.github.io token=gh-run-token
    (cd "$g" && RECORD=$base STATE=$t/state PATH=$t/pbin:$PATH bash "$t/bump-$1.sh") > "$t/bump.out" 2>&1
}
# R2: the default exempt list is .github/** alone; README.md and docs/ ship in packages (%doc README.md), so they
# change the package unless the repository adds them through bump-exempt
mkdir -p "$g/.github/workflows"; echo w > "$g/.github/workflows/ci.yml"; gitc add -A; gitc commit -q -m workflow
bumprun rpm 1.2.0 || { cat "$t/bump.out"; fail "build-rpm.yml: a pull request into devel changing .github/ alone since the recorded build was refused"; }
# R1: the deb 1.2.0 the channel root serves has no record of its build: red by name, never a silent pass
bumprun deb 1.2.0 && { cat "$t/bump.out"; fail "build-deb.yml: a served version with no record of its build passed"; }
grep -qF 'staging/deb/built/omx-a/1.2.0.commit does not record the commit that built it' "$t/bump.out" || { cat "$t/bump.out"; fail "build-deb.yml: the missing record is not named"; }
echo b > "$g/docs/x.md"; echo r2 > "$g/README.md"; gitc add -A; gitc commit -q -m docs
bumprun rpm 1.2.0 && { cat "$t/bump.out"; fail "build-rpm.yml: a pull request into devel changing README.md and docs/ at a published version passed (README.md ships as %doc)"; }
for p in README.md docs/x.md; do
    grep -qF "::error::$p changes the package since $base" "$t/bump.out" || { cat "$t/bump.out"; fail "the bump refusal does not name $p"; }
done
bumprun rpm 1.2.0 'docs/** README.md' || { cat "$t/bump.out"; fail "build-rpm.yml: the paths a repository adds to bump-exempt were not exempt"; }
echo c > "$g/src/a.c"; gitc add -A; gitc commit -q -m code
bumprun rpm 1.2.0 && { cat "$t/bump.out"; fail "build-rpm.yml: a pull request into devel changing src/ at a version staging holds passed"; }
grep -qF "::error::src/a.c changes the package since $base, and the head's version v1.2.0 is published already (staging/rpm/fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm)" "$t/bump.out" ||
    { cat "$t/bump.out"; fail "build-rpm.yml: the bump refusal does not name the changed path and the served file"; }
grep '::error::' "$t/bump.out" | grep -q 'ci.yml' && { cat "$t/bump.out"; fail "the bump refusal names an exempt path"; }
bumprun rpm 1.2.0 'docs/** README.md' && { cat "$t/bump.out"; fail "build-rpm.yml: src/ passed with docs added to bump-exempt"; }
grep '::error::' "$t/bump.out" | grep -q 'docs/x.md\|README.md\|ci.yml' && { cat "$t/bump.out"; fail "the bump refusal names a path the repository exempted"; }
grep -qx 'Authorization: Bearer gh-run-token' "$t/state/auth" || { cat "$t/state/auth"; fail "the bump check did not read the channel with the run's github.token"; }
bumprun deb 1.2.0 && { cat "$t/bump.out"; fail "build-deb.yml: a pull request into devel changing src/ at a version the channel root holds passed"; }
grep -q 'deb/debian/trixie/amd64/omx-a_1.2.0_amd64.deb' "$t/bump.out" || { cat "$t/bump.out"; fail "build-deb.yml: the bump refusal does not name the served deb"; }
bumprun rpm 1.3.0 || { cat "$t/bump.out"; fail "build-rpm.yml: a pull request into devel carrying a new version was refused"; }
echo "a pull request into devel changing a package at a published version is refused by name; .github/ alone, a repository's own exempt paths and a bump pass: ok"

# ---- 9. a real promotion is tied to the devel commit that built it (F6c). The staging publish of a merge to devel records
#      the full commit (built-commit, record-built.sh: staging/<kind>/built/<name>/<version>.commit); promote-staged's
#      find job reads it and refuses unless the promotion commit carries the same version and is that commit or descends
#      from it. The find job's own steps run in a git tree: devel commit A builds 1.2.0, B merges it into main, C is an
#      unrelated 1.2.0 on main, D bumps to 1.3.0 after B.
rb=$root/.github/actions/publish-rpms/record-built.sh
cat > "$t/pbin/rpm" <<'STUB'
#!/bin/bash
# rpm -qp --qf '%{SOURCEPACKAGE}|%{NAME}|%{VERSION}|%{SOURCERPM}\n' <file>: read from the file name
f=${*: -1}; b=${f##*/}
case $b in *.src.rpm) n=${b%-*-*}; v=${b#"$n"-}; printf '1|%s|%s|(none)\n' "$n" "${v%%-*}" ;;
  *) n=${b%-*-*}; v=${b#"$n"-}; printf '0|%s|%s|%s-%s.src.rpm\n' "$n" "${v%%-*}" "$n" "${v%.*.rpm}" ;; esac
STUB
cat > "$t/pbin/dpkg-deb" <<'STUB'
#!/bin/bash
# dpkg-deb -f <file> Source|Package|Version: read from <package>_<version>_<arch>.deb; Source is omx-a
b=${2##*/}
case $3 in Source) echo omx-a ;; Package) echo "${b%%_*}" ;; Version) v=${b#*_}; echo "${v%_*}" ;; esac
STUB
chmod +x "$t/pbin/rpm" "$t/pbin/dpkg-deb"
A=0123456789abcdef0123456789abcdef01234567
rt=$t/record; rm -rf "$rt"; mkdir -p "$rt"
PATH=$t/pbin:$PATH bash "$rb" "$rt/rpm" "$A" x/omx-a-1.2.0-1.fc45.src.rpm x/omx-a-devel-1.2.0-1.fc45.x86_64.rpm > "$rt/log" 2>&1 || { cat "$rt/log"; fail "record-built.sh refused a first rpm record"; }
[ "$(cat "$rt/rpm/built/omx-a/1.2.0.commit" 2>/dev/null)" = "$A" ] || fail "record-built.sh did not record omx-a 1.2.0 built by $A (rpm)"
PATH=$t/pbin:$PATH bash "$rb" "$rt/deb" "$A" x/trixie/libomx-a0_1.2.0-1_amd64.deb > "$rt/log" 2>&1 || { cat "$rt/log"; fail "record-built.sh refused a first deb record"; }
[ "$(cat "$rt/deb/built/omx-a/1.2.0.commit" 2>/dev/null)" = "$A" ] || fail "record-built.sh did not record the source omx-a 1.2.0, revision dropped (deb)"
PATH=$t/pbin:$PATH bash "$rb" "$rt/rpm" "${A/0123/9999}" x/omx-a-1.2.0-1.fc45.src.rpm > "$rt/log" 2>&1 && fail "record-built.sh replaced the record of another commit"
grep -q 'refused built/omx-a/1.2.0.commit' "$rt/log" || { cat "$rt/log"; fail "record-built.sh's refusal does not name the record"; }
PATH=$t/pbin:$PATH bash "$rb" "$rt/rpm" 0123abc x/omx-a-1.2.0-1.fc45.src.rpm > "$rt/log" 2>&1 && fail "record-built.sh took a short commit"
python3 -I - "$root" <<'PY2' || fail "the staging publish of a merge to devel does not record its commit"
import sys, yaml
root = sys.argv[1]
for kind in ("rpm", "deb"):
    a = yaml.safe_load(open(f"{root}/.github/actions/publish-{kind}s/action.yml"))["runs"]["steps"]
    assert any(s.get("env", {}).get("BUILT_COMMIT_IN") == "${{ inputs.built-commit }}" and 'echo "BUILT_COMMIT=$BUILT_COMMIT_IN" >> "$GITHUB_ENV"' in s.get("run", "") for s in a), kind
    tree = open(f"{root}/.github/actions/publish-{kind}s/publish-tree.sh").read()
    assert 'record-built.sh" "$tree" "$BUILT_COMMIT"' in tree, kind
    w = yaml.safe_load(open(f"{root}/.github/workflows/build-{kind}.yml"))["jobs"]["publish"]["steps"]
    st = [s for s in w if str(s.get("with", {}).get("staging")) == "true"][0]
    assert st["with"].get("built-commit") == "${{ (github.event_name == 'push' && github.ref == 'refs/heads/devel') && github.sha || '' }}", kind
PY2

# the caller's repository
r=$t/caller; rm -rf "$r"; mkdir -p "$r/packaging" "$r/debian"
gitr() { git -C "$r" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
setv() { printf 'Name: omx-a\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\n%%description\nt\n' "$1" > "$r/packaging/omx-a.spec"
         printf 'omx-a (%s-1) trixie; urgency=medium\n\n  * t\n\n -- T <t@example.org>  Tue, 25 Nov 2026 12:00:00 +0000\n' "$1" > "$r/debian/changelog"; }
setv 1.1.0; gitr init -q -b main; gitr add -A; gitr commit -q -m root
gitr checkout -q -b devel; setv 1.2.0; gitr commit -q -am devel-1.2.0; A=$(gitr rev-parse HEAD)
gitr checkout -q main; mkdir -p "$r/.github"; echo x > "$r/.github/ci.yml"; gitr add -A; gitr commit -q -m main-side; gitr merge -q --no-ff -m merge devel; B=$(gitr rev-parse HEAD)
gitr checkout -q -b other main~1; setv 1.2.0; gitr commit -q -am unrelated-1.2.0; C=$(gitr rev-parse HEAD)
gitr checkout -q main; gitr merge -q --no-ff -m merge-other other; CM=$(gitr rev-parse HEAD)
gitr checkout -q -b bump "$B"; setv 1.3.0; gitr commit -q -am bump; D=$(gitr rev-parse HEAD)
# R3: E descends from B at 1.2.0 and changes the package (src/a.c, README.md): it is not the build being promoted
gitr checkout -q -b more "$B"; mkdir -p "$r/src"; echo c > "$r/src/a.c"; echo r > "$r/README.md"; gitr add -A; gitr commit -q -m more; E=$(gitr rev-parse HEAD)
gitr checkout -q main
gitr update-ref refs/remotes/origin/main "$CM"
ch=$t/promo-channel; rm -rf "$ch"; mkdir -p "$ch/.git" "$ch/staging/rpm/built/omx-a" "$ch/staging/deb/built/omx-a"
echo "$A" > "$ch/staging/rpm/built/omx-a/1.2.0.commit"; echo "$A" > "$ch/staging/deb/built/omx-a/1.2.0.commit"
pw=$root/.github/workflows/promote-staged.yml
python3 -I "$step" "$root" "$pw" find id=built "$t/f-built.sh"
python3 -I "$step" "$root" "$pw" find id=tie "$t/f-tie.sh"
python3 -I "$step" "$root" "$pw" find id=commit "$t/f-commit.sh"
python3 -I - "$pw" <<'PY2' || fail "promote-staged's paths step is not package-paths from the build to the promotion, with the caller's bump-exempt"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["find"]["steps"]
p = [s for s in steps if s.get("id") == "paths"][0]
assert "/actions/package-paths@" in p["uses"]
assert p["with"] == {"base": "${{ steps.built.outputs.commit }}", "head": "${{ steps.built.outputs.full }}", "exempt": "${{ inputs.bump-exempt }}"}, p["with"]
tie = [s for s in steps if s.get("id") == "tie"][0]
assert tie["env"]["COUNT"] == "${{ steps.paths.outputs.count }}" and tie["env"]["PATHS"] == "${{ steps.paths.outputs.paths }}"
PY2
outv() { sed -n "s/^$1=//p" "$2" | tail -n1; }
find_real() { # find_real <promotion commit> [rpm] [deb] -> status of the built, version and tie steps; log in $t/f.out
    local o=$t/f-gh; : > "$o"; rm -rf "$t/promo-tree"
    (cd "$r" && export PATH=$t/pbin:$PATH GITHUB_OUTPUT=$o RUNNER_TEMP=$t NAME=omx-a VERSION=1.2.0 RUN_COMMIT=$1 RPM=${2:-true} DEB=${3:-true} \
        CHANNEL=Open-Mixer/open-mixer.github.io DIR=$ch
     bash "$t/f-built.sh" || exit $?
     built=$(outv commit "$o"); [ -n "$built" ] || exit 0; export RPMV='' DEBV=''
     for k in rpm deb; do
        [ "$( [ "$k" = rpm ] && echo "${2:-true}" || echo "${3:-true}")" = true ] || continue
        python3 -I "$step" "$root" "$pw" find "id=${k}ver" "$t/f-$k.sh" kind=$k dir="$(outv tree "$o")"
        GITHUB_OUTPUT=$t/f-$k-out bash "$t/f-$k.sh" > /dev/null || exit $?
        export "${k^^}V=$(outv version "$t/f-$k-out")"
     done
     full=$(outv full "$o")
     python3 -I "$step" "$root" "$pw" find id=paths "$t/f-paths.sh" base="$built" head="$full" exempt="${EXTRA_EXEMPT:-}"
     GITHUB_OUTPUT=$t/f-paths-out bash "$t/f-paths.sh" > /dev/null || exit $?
     COUNT=$(outv count "$t/f-paths-out") PATHS=$(sed -n '/^paths<<PACKAGE_PATHS_EOF$/,/^PACKAGE_PATHS_EOF$/p' "$t/f-paths-out" | sed '1d;$d') \
     BUILT=$built FULL=$full bash "$t/f-tie.sh") > "$t/f.out" 2>&1
}
command -v dpkg-parsechangelog >/dev/null || cp "$t/bin/dpkg-parsechangelog" "$t/pbin/"
mv "$t/pbin/rpm" "$t/pbin/rpm.stub"   # the find job reads the spec with the real rpmspec
find_real "$B" || { cat "$t/f.out"; fail "promote-staged refused the merge of the devel commit that built 1.2.0"; }
[ "$(outv real "$t/f-gh")" = true ] || { cat "$t/f.out" "$t/f-gh"; fail "the tie did not say the promotion is real"; }
find_real "$A" || { cat "$t/f.out"; fail "promote-staged refused the devel commit that built 1.2.0 itself"; }
find_real "$C" && { cat "$t/f.out"; fail "promote-staged took an unrelated commit of 1.2.0 for the real build of $A"; }
grep -q "does not descend from $A" "$t/f.out" || { cat "$t/f.out"; fail "the refusal of an unrelated commit does not name the devel commit"; }
find_real "$D" && { cat "$t/f.out"; fail "promote-staged took a descendant carrying 1.3.0 for the real 1.2.0"; }
grep -q 'carries 1.3.0' "$t/f.out" || { cat "$t/f.out"; fail "the refusal of a bumped descendant does not name its version"; }
find_real "$E" && { cat "$t/f.out"; fail "promote-staged took a descendant at 1.2.0 that changes the package for the build of $A"; }
for p in src/a.c README.md; do grep -q "::error::$p changes the package since $A" "$t/f.out" || { cat "$t/f.out"; fail "the refusal of a changed descendant does not name $p"; }; done
EXTRA_EXEMPT='src/** README.md' find_real "$E" || { cat "$t/f.out"; fail "the paths a repository exempts refused the promotion"; }
rm "$ch/staging/deb/built/omx-a/1.2.0.commit"
find_real "$B" && { cat "$t/f.out"; fail "promote-staged took a real build whose deb half records no commit"; }
grep -q 'staging/deb holds no record' "$t/f.out" || { cat "$t/f.out"; fail "the missing deb record is not refused by name"; }
find_real "$B" true false || { cat "$t/f.out"; fail "an rpm-only promotion was refused for the deb record"; }
echo "$A" > "$ch/staging/deb/built/omx-a/1.2.0.commit"
# the commit step promotes a real build only on the tie: collect.py's commit real with no tie is refused
(cd "$r" && GITHUB_OUTPUT=$t/c-gh RPM_COMMIT=real DEB_COMMIT=real VERSION=1.2.0 RUN_COMMIT=$C DEFAULT_BRANCH=main TIED='' bash "$t/f-commit.sh") > "$t/c.out" 2>&1 &&
    { cat "$t/c.out"; fail "the commit step promoted a real build that no devel commit was tied to"; }
(cd "$r" && GITHUB_OUTPUT=$t/c-gh RPM_COMMIT=real DEB_COMMIT=real VERSION=1.2.0 RUN_COMMIT=$B DEFAULT_BRANCH=main TIED=true bash "$t/f-commit.sh") > "$t/c.out" 2>&1 ||
    { cat "$t/c.out"; fail "the commit step refused a tied real build"; }
mv "$t/pbin/rpm.stub" "$t/pbin/rpm"
echo "a real promotion is tied to the devel commit that built it: the same version, that commit or a descendant: ok"

# ---- 10. the recovery of a half-published merge to devel (F4): each kind has its own preflight, reading only its own
#      half of the channel, so the rpm a merge published does not turn its failed deb half into a skip on a rerun (and
#      the other way round); docs/release-operations.md says to rerun the failed jobs, to fix forward with a bump when the
#      code is at fault, and that the half-published version is never promoted.
python3 -I - "$root" <<'PY2' || fail "a kind's preflight does not read its own half of the channel alone"
import sys, yaml
for kind in ("rpm", "deb"):
    steps = yaml.safe_load(open(f"{sys.argv[1]}/.github/workflows/build-{kind}.yml"))["jobs"]["preflight"]["steps"]
    pre = [s for s in steps if s.get("id") == "preflight"][0]
    assert pre["with"].get("kind") == kind, kind
PY2
printf '%s\n' rpm/fedora/45/x86_64/omx-a-1.2.0-1.fc45.x86_64.rpm staging/rpm/fedora/45/x86_64/omx-a-1.4.0-1.fc45.x86_64.rpm > "$t/half"
KIND=deb STAGING=true ON_SERVED=notice bash "$served" v1.4.0 omx-a < "$t/half" > "$t/half.out" 2>&1 ||
    { cat "$t/half.out"; fail "the deb half of a merge whose rpm half was published is skipped on its rerun"; }
rc=0; KIND=rpm STAGING=true ON_SERVED=notice bash "$served" v1.4.0 omx-a < "$t/half" > "$t/half.out" 2>&1 || rc=$?; [ "$rc" = 3 ] ||
    { cat "$t/half.out"; fail "the rpm half a merge published is not seen as published by its own kind"; }
doc=$root/docs/release-operations.md
sec=$(sed -n '/^### A merge to devel publishes the real package to staging/,/^### /p' "$doc")
for want in 'one kind published and the other failed' 'rerun the failed jobs' 'gh run rerun <run id> --failed' \
            'fix forward' 'bump' 'never promoted'; do
    grep -qF "$want" <<< "$sec" || fail "docs/release-operations.md does not say, in the devel section: $want"
done
echo "a half-published merge to devel: each kind's rerun reads its own half; the doc gives the rerun, the fix forward and the rule: ok"

# ---- 11. build-deb.yml's install check of a merge to devel matches the staged candidate with its Debian revision
#      handled (R4): the version read (tree-version) has none, the package has <version>-<revision>; a +git or ~git
#      build of the version, another version, and a revision that is no Debian revision are not it.
python3 -I "$step" "$root" "$root/.github/workflows/build-deb.yml" verify "name=Install the staged build of this commit from the staging channel" "$t/vdev.sh"
cat > "$t/pbin/apt-cache" <<'STUB'
#!/bin/bash
case $1 in
  policy) printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$2" "$CAND" ;;
esac
STUB
chmod +x "$t/pbin/apt-cache"
devcheck() { # devcheck <candidate> -> status
    rm -rf "$t/state"; mkdir -p "$t/state"
    STATE=$t/state PATH=$t/pbin:$PATH CAND=$1 DEVEL_VERSION=1.2.0 NAME=omx-a BINARIES=omx-a URL=x SUITE=trixie GITHUB_SHA=0123abc0123abc \
        bash "$t/vdev.sh" > "$t/vdev.out" 2>&1
}
for c in 1.2.0 1.2.0-1 1.2.0-2+deb13u1; do
    devcheck "$c" || { cat "$t/vdev.out"; fail "build-deb.yml: the install check of a merge to devel of 1.2.0 refused the candidate $c"; }
    grep -qx "install -y --no-install-recommends omx-a=$c" "$t/state/apt.log" || fail "build-deb.yml: $c was not installed"
done
for c in 1.2.0+git1700000000.0123abc 1.2.0~git1700000000.0123abc 1.2.0-1+git1 1.2.1 1.2.0.1 1.2.0-; do
    devcheck "$c" && { cat "$t/vdev.out"; fail "build-deb.yml: the install check of a merge to devel of 1.2.0 took the candidate $c"; }
done
echo "build-deb.yml's install check takes 1.2.0 and 1.2.0-<revision> for a merge to devel of 1.2.0, and no other build: ok"

# ---- 4. the trigger gate lets the release workflow run on a push to devel, and on no other branch
bash "$root/.github/actions/trigger-gate/check.sh" --self-test >/dev/null || fail "trigger-gate's self-test"
echo "trigger-gate: a push to devel passes, any other branch is refused: ok"
echo "devel-push-staging: all passed"
