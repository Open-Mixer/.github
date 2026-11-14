#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The quick and the full release matrix, offline (docs/release-operations.md, "The quick set and the full matrix").
# Proves:
#   - the quick set is written once, in .github/actions/release-matrix/quick.txt, and is fc44 x86_64 and fc45 x86_64
#     for rpm and trixie amd64 and trixie arm64 for deb;
#   - build-rpm.yml and build-deb.yml, rendered: the first job asks release-matrix once, with the caller's matrix,
#     the matrix input, the organisation variable, staged and source-ref; the build and the install check both take
#     their cells from its answer and nothing else, so an install check never runs for a cell that was not built;
#   - which jobs each run renders, by name, with matrix.sh run as the runner runs it: a caller that passes nothing
#     builds the full matrix on a tag and the quick set on a tag while OMX_RELEASE_MATRIX is quick; a staged run and a
#     workflow_dispatch build the quick set, and the full matrix when the variable or the input says full; a pull
#     request builds the full matrix whatever the variable says; a caller built for x86_64 alone has no quick deb
#     cell and builds its own full deb matrix;
#   - a matrix or a variable that is neither quick nor full fails the first job;
#   - release-c-lib.yml hands its matrix input on to both, and publish-fedora.yml always asks for the full matrix.
#   - cells.sh, run on a tree: one line per package and version with the cells its files lie in, the set of the run
#     that published it, kept by a later run that publishes something else, replaced when the version goes out again
#     for the full matrix, and gone with the files; both tree scripts call it and both publish actions hand it the
#     set the first job named, a promotion always full;
#   - quick-deps.sh, run on a list of installed packages: a quick-only version among them is refused by name, a full
#     one and an older one pass, a channel with no cells.tsv passes and says so, an unreadable one fails; the build
#     jobs run it on a release of the full matrix only.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

python3 -I - "$here" "$t" <<'PY'
import json, os, re, subprocess, sys, yaml
here, tmp = sys.argv[1], sys.argv[2]
act = f"{here}/.github/actions/release-matrix"

class O(dict):
    __getattr__ = dict.get

def ev(expr, inputs, event="push", ref_type="branch", var=None, steps=None, needs=None, matrix=None):
    e = str(expr).strip()
    if "${{" not in e:
        return expr
    if e.count("${{") > 1 or (e.count("${{") == 1 and not (e.startswith("${{") and e.endswith("}}"))):
        return re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(ev("${{" + m.group(1) + "}}", inputs, event, ref_type, var, steps, needs, matrix)), e)
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2].strip()
    e = re.sub(r"\binputs\.([a-z0-9-]+)", lambda m: f'inputs["{m.group(1)}"]', e)
    e = re.sub(r"\.outputs\.([a-z0-9-]+)", lambda m: f'.outputs["{m.group(1)}"]', e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    env = {"inputs": inputs, "fromJSON": json.loads, "true": True, "false": False,
           "join": lambda a, s=",": s.join(a),
           "github": O(ref_type=ref_type, event_name=event, ref_name="v1.2.0" if ref_type == "tag" else "main"),
           "vars": O(OMX_RELEASE_MATRIX=var or ""), "steps": steps or O(), "needs": needs or O(), "matrix": matrix or O(),
           "secrets": O()}
    return eval(e, {"__builtins__": {}}, env)

def text(v):
    return {True: "true", False: "false", None: ""}.get(v, v) if isinstance(v, (bool, type(None))) else str(v)

# ---- the quick set, written once
quick = [l.split() for l in open(f"{act}/quick.txt") if l.strip() and not l.startswith("#")]
assert quick == [["rpm", "44", "x86_64"], ["rpm", "45", "x86_64"], ["deb", "trixie", "amd64"], ["deb", "trixie", "arm64"]], \
    f"quick.txt is {quick}"
action = yaml.safe_load(open(f"{act}/action.yml"))
step = action["runs"]["steps"]
assert len(step) == 1 and step[0]["run"].strip() == '"$GITHUB_ACTION_PATH/matrix.sh"', "release-matrix is more than one call of matrix.sh"
sh = open(f"{act}/matrix.sh").read()
assert "quick.txt" in sh and not re.search(r"\b(trixie|bookworm|x86_64|aarch64|arm64|amd64)\b", re.sub(r"(?m)^\s*#.*$", "", sh)), \
    "matrix.sh names a cell of its own: the quick set is quick.txt alone"
print("ok   the quick set is fc44 x86_64, fc45 x86_64 (rpm), trixie amd64 and trixie arm64 (deb), written in quick.txt alone")

WF = {"rpm": (f"{here}/.github/workflows/build-rpm.yml", "fedora-versions", "fedora"),
      "deb": (f"{here}/.github/workflows/build-deb.yml", "suite-matrix", "suite")}
docs = {}
for kind, (path, rel_in, key) in WF.items():
    d = yaml.safe_load(open(path)); raw = open(path).read()
    docs[kind] = d
    on = d.get(True) or d.get("on")
    decl = on["workflow_call"]["inputs"]
    assert decl["matrix"]["type"] == "string" and decl["matrix"]["default"] == "", f"{path}: matrix is not a string input, empty by default"
    pre = d["jobs"]["preflight"]
    ms = [s for s in pre["steps"] if "/actions/release-matrix@" in s.get("uses", "")]
    assert len(ms) == 1 and ms[0].get("id") == "matrix" and "if" not in ms[0], f"{path}: the first job does not ask release-matrix once, always"
    assert ms[0]["uses"] == "Open-Mixer/.github/.github/actions/release-matrix@openmixer-v1", ms[0]["uses"]
    w = {k: str(v).replace(" ", "") for k, v in ms[0]["with"].items()}
    assert w == {"kind": kind, "matrix": "${{inputs.matrix}}", "wave": "${{vars.OMX_RELEASE_MATRIX}}", "staged": "${{inputs.staged}}",
                 "source-ref": "${{inputs.source-ref}}", "releases": "${{inputs.%s}}" % rel_in, "arches": "${{inputs.arch-matrix}}",
                 # a catch-up (tests/catch-up-plan.sh): the packages, and the channel whose cells.tsv it subtracts
                 "catch-up": "${{inputs.catch-up}}", "names": "${{inputs.binary-names||inputs.package-name}}",
                 "channel": "${{inputs.target-repo}}", "token": "${{secrets.PAGES_TOKEN}}"}, f"{path}: release-matrix is given {w}"
    for o in ("set", "cells", "first-arch"):
        assert pre["outputs"][o].replace(" ", "") == "${{steps.matrix.outputs.%s}}" % o, f"{path}: the first job does not hand on {o}"
    for job in ("build", "verify"):
        j = d["jobs"][job]
        assert j["strategy"]["matrix"] == {"include": "${{ fromJSON(needs.preflight.outputs.cells) }}"}, \
            f"{path}: the {job} matrix is {j['strategy']['matrix']}, not the cells of the first job"
        needs = j["needs"] if isinstance(j["needs"], list) else [j["needs"]]
        assert "preflight" in needs, f"{path}: {job} reads the cells of a job it does not need"
    # nothing else builds a matrix of its own from the caller's lists
    for name, j in d["jobs"].items():
        m = (j.get("strategy") or {}).get("matrix")
        assert m is None or name in ("build", "verify"), f"{path}: job {name} has a matrix of its own"
    assert "fromJSON(inputs.arch-matrix)" not in raw, f"{path}: something still reads the caller's architectures past the first job"
    served = [s for s in pre["steps"] if "/actions/release-preflight@" in s.get("uses", "")][0]
    assert served["with"]["releases"].replace(" ", "") == "${{steps.matrix.outputs.releases}}", f"{path}: the already-served check reads releases this run does not publish into"
    if kind == "rpm":
        assert raw.count("needs.preflight.outputs.first-arch") == 2, f"{path}: the source and noarch packages do not ship from the first architecture the set builds"
print("ok   build-rpm.yml and build-deb.yml: one release-matrix call, the build and the install check take its cells")

def run(kind, inputs, event, ref_type, var):
    """the cells of a run: the matrix step's `with`, evaluated, given to matrix.sh as the action gives it"""
    path, rel_in, key = WF[kind]
    d = docs[kind]
    on = d.get(True) or d.get("on")
    full = {k: v.get("default") for k, v in on["workflow_call"]["inputs"].items()}
    full.update(inputs)
    ms = [s for s in d["jobs"]["preflight"]["steps"] if "/actions/release-matrix@" in s.get("uses", "")][0]
    w = {k: text(ev(v, full, event, ref_type, var)) for k, v in ms["with"].items()}
    env = {"PATH": os.environ["PATH"], "GITHUB_OUTPUT": f"{tmp}/out"}
    for name, expr in action["runs"]["steps"][0]["env"].items():
        expr = re.sub(r"\binputs\.([a-z0-9-]+)", lambda m: f'inputs["{m.group(1)}"]', expr)
        env[name] = text(ev(expr, {k: w.get(k, action["inputs"][k].get("default", "")) for k in action["inputs"]}, event, ref_type, var))
    open(env["GITHUB_OUTPUT"], "w").close()
    p = subprocess.run([f"{act}/matrix.sh"], env=env, capture_output=True, text=True)
    if p.returncode:
        return None, p.stdout + p.stderr
    out = O(l.rstrip("\n").split("=", 1) for l in open(env["GITHUB_OUTPUT"]))
    steps = O(matrix=O(outputs=out))
    pre = d["jobs"]["preflight"]
    needs = O(preflight=O(outputs=O({k: ev(v, full, event, ref_type, var, steps=steps) for k, v in pre["outputs"].items()})))
    names = {}
    for job in ("build", "verify"):
        j = d["jobs"][job]
        cells = ev(j["strategy"]["matrix"]["include"], full, event, ref_type, var, needs=needs)
        names[job] = [ev(j["name"], full, event, ref_type, var, matrix=O(c)) for c in cells]
        for c in cells:
            image = ev(j["container"]["image"], full, event, ref_type, var, matrix=O(c))
            assert image == ("fedora:" if kind == "rpm" else "debian:") + c[key], f"{path}: {job} of {c} runs in {image}"
    assert [n.split("(", 1)[1] for n in names["build"]] == [n.split("(", 1)[1] for n in names["verify"]], \
        f"{path}: the install checks {names['verify']} are not the built cells {names['build']}"
    return O(set=out["set"], jobs=[n.split("(", 1)[1].rstrip(")") for n in names["build"]], first=needs.preflight.outputs["first-arch"],
             releases=out["releases"]), p.stdout

FULL = {"rpm": ["fc44, x86_64", "fc44, aarch64", "fc45, x86_64", "fc45, aarch64"],
        "deb": ["bookworm, amd64", "bookworm, arm64", "trixie, amd64", "trixie, arm64"]}
QUICK = {"rpm": ["fc44, x86_64", "fc45, x86_64"], "deb": ["trixie, amd64", "trixie, arm64"]}
X86 = {"rpm": {"arch-matrix": '["x86_64"]'}, "deb": {"arch-matrix": '["amd64"]'}}
# (what, inputs, event, ref type, OMX_RELEASE_MATRIX, the set, the jobs)
cases = [
    ("a tag push of a caller that passes nothing", {"publish": True}, "push", "tag", None, "full", FULL),
    ("a tag push while the wave is open (OMX_RELEASE_MATRIX=quick)", {"publish": True}, "push", "tag", "quick", "quick", QUICK),
    ("the wave's final release (OMX_RELEASE_MATRIX=full)", {"publish": True}, "push", "tag", "full", "full", FULL),
    ("a tag push with matrix: full while the wave is open", {"publish": True, "matrix": "full"}, "push", "tag", "quick", "full", FULL),
    ("a tag push with matrix: quick", {"publish": True, "matrix": "quick"}, "push", "tag", None, "quick", QUICK),
    ("a release of another tag (source-ref) by dispatch", {"publish": True, "source-ref": "v1.2.0"}, "workflow_dispatch", "branch", None, "full", FULL),
    ("a staged run", {"staged": True}, "workflow_dispatch", "branch", None, "quick", QUICK),
    ("a staged run while the wave is open", {"staged": True}, "workflow_dispatch", "branch", "quick", "quick", QUICK),
    ("a staged run with OMX_RELEASE_MATRIX=full", {"staged": True}, "workflow_dispatch", "branch", "full", "full", FULL),
    ("a staged run with matrix: full", {"staged": True, "matrix": "full"}, "workflow_dispatch", "branch", None, "full", FULL),
    ("a workflow_dispatch dry run", {}, "workflow_dispatch", "branch", None, "quick", QUICK),
    ("a workflow_dispatch dry run with matrix: full", {"matrix": "full"}, "workflow_dispatch", "branch", None, "full", FULL),
    ("a pull request", {}, "pull_request", "branch", None, "full", FULL),
    ("a pull request while the wave is open", {}, "pull_request", "branch", "quick", "full", FULL),
    ("a push to a branch while the wave is open", {}, "push", "branch", "quick", "full", FULL),
]
n = 0
for what, inputs, event, rt, var, want_set, want in cases:
    for kind in ("rpm", "deb"):
        got, log = run(kind, inputs, event, rt, var)
        assert got is not None, f"{kind}: {what}: the first job failed: {log}"
        assert (got.set, got.jobs) == (want_set, want[kind]), f"{kind}: {what} builds {got.set} {got.jobs}, want {want_set} {want[kind]}"
        assert f"{kind} matrix: {want_set} (" in log and f"{len(want[kind])} cell(s)" in log, f"{kind}: {what}: the run does not say what it builds: {log}"
        n += 1
print(f"ok   {n} runs rendered: a tag is full unless the wave is open, a staged run and a dispatch are quick unless told full, a pull request is full")

# the four quick cells and the eight of a release, counted across the two workflows
q = sum(len(run(k, {"staged": True}, "workflow_dispatch", "branch", None)[0].jobs) for k in WF)
f = sum(len(run(k, {"publish": True}, "push", "tag", None)[0].jobs) for k in WF)
assert (q, f) == (4, 8), f"a staged run builds {q} cells and a release {f}, want 4 and 8"
print("ok   a staged run is 4 build jobs and 4 install checks, a release 8 and 8")

# a caller built for x86_64 alone: the quick rpm cells, and of the quick deb cells the one it builds, trixie amd64
got, _ = run("rpm", dict(X86["rpm"], staged=True), "workflow_dispatch", "branch", None)
assert (got.set, got.jobs, got.first) == ("quick", QUICK["rpm"], "x86_64"), got
got, log = run("deb", dict(X86["deb"], staged=True), "workflow_dispatch", "branch", None)
assert (got.set, got.jobs) == ("quick", ["trixie, amd64"]), f"{got} {log}"
# a lane's dry-run dispatch with arm off while the wave is open (omx-plugins ci.yml -> release.yml, arm: false): trixie amd64,
# never the full deb matrix. Before trixie amd64 joined the quick set this fell back to full and built bookworm amd64
# (omx-plugins run 43412676885, 2026-11-13)
got, log = run("deb", dict(X86["deb"]), "workflow_dispatch", "branch", "quick")
assert (got.set, got.jobs) == ("quick", ["trixie, amd64"]), f"a lane's amd64-only dispatch builds {got.set} {got.jobs}: {log}"
# one Fedora release asked for (publish-fedora): the quick set never adds a release the caller did not name
got, _ = run("rpm", {"fedora-versions": '["45"]', "staged": True}, "workflow_dispatch", "branch", None)
assert (got.jobs, got.releases) == (["fc45, x86_64"], "45"), got
# the source and noarch packages ship from the first of the caller's architectures the set builds
got, _ = run("rpm", {"arch-matrix": '["aarch64", "x86_64"]', "staged": True}, "workflow_dispatch", "branch", None)
assert got.first == "x86_64", f"quick builds x86_64 alone, and the source package ships from {got.first}"
got, _ = run("rpm", {"arch-matrix": '["aarch64", "x86_64"]', "publish": True}, "push", "tag", None)
assert got.first == "aarch64", f"a full run ships the source package from {got.first}, not the caller's first architecture"
got, _ = run("deb", {"staged": True}, "workflow_dispatch", "branch", None)
assert got.releases == "trixie", f"the quick deb run publishes into {got.releases!r}"
print("ok   a caller's narrower matrix is kept: x86_64 alone builds the quick cells it has (trixie amd64 for deb), one Fedora release stays one")

for what, inputs, var, word in (("matrix: fast", {"matrix": "fast"}, None, "matrix is 'fast'"), ("OMX_RELEASE_MATRIX=some", {}, "some", "OMX_RELEASE_MATRIX is 'some'")):
    for kind in WF:
        got, log = run(kind, inputs, "push", "tag", var)
        assert got is None and word in log, f"{kind}: {what} is not refused by name: {got} {log}"
print("ok   a matrix or a variable that is neither quick nor full fails the first job, by name")

# ---- the callers in this repository
lib = yaml.safe_load(open(f"{here}/.github/workflows/release-c-lib.yml"))
on = lib.get(True) or lib.get("on")
assert on["workflow_call"]["inputs"]["matrix"] == {"description": on["workflow_call"]["inputs"]["matrix"]["description"], "type": "string", "default": ""}, \
    "release-c-lib.yml: matrix is not an optional string input"
for job in ("rpm", "deb"):
    assert lib["jobs"][job]["with"]["matrix"].replace(" ", "") == "${{inputs.matrix}}", f"release-c-lib.yml: {job} does not hand on matrix"
fed = yaml.safe_load(open(f"{here}/.github/workflows/publish-fedora.yml"))
assert fed["jobs"]["rpm"]["with"]["matrix"] == "full", "publish-fedora.yml fills a Fedora release: it must ask for the full matrix"
print("ok   release-c-lib.yml hands matrix on; publish-fedora.yml asks for the full matrix")

# ---- the set reaches the channel index, and a full release reads it
for kind, (path, rel_in, key) in WF.items():
    d = docs[kind]
    on = d.get(True) or d.get("on")
    base = {k: v.get("default") for k, v in on["workflow_call"]["inputs"].items()}
    pub = d["jobs"]["publish"]
    assert "preflight" in pub["needs"], f"{path}: publish reads the set of a job it does not need"
    st = [s for s in pub["steps"] if f"/actions/publish-{kind}s@" in s.get("uses", "")][0]
    # the set of the run, except on a catch-up, which keeps the set the version was published for (tests/catch-up-plan.sh)
    assert st["with"]["matrix-set"].replace(" ", "") == "${{!inputs.catch-up&&needs.preflight.outputs.set||''}}", f"{path}: the publish is not told the set"
    for cu, want in ((False, "quick"), (True, "")):
        got = ev(st["with"]["matrix-set"], dict(base, **{"catch-up": cu}), needs=O(preflight=O(outputs=O(set="quick"))))
        assert got == want, f"{path}: with catch-up {cu} the publish records the set {got!r}, not {want!r}"
    a = yaml.safe_load(open(f"{here}/.github/actions/publish-{kind}s/action.yml"))
    assert a["inputs"]["matrix-set"]["default"] == "", f"publish-{kind}s: matrix-set must default to nothing recorded"
    first = a["runs"]["steps"][1]
    assert first["env"]["MATRIX_SET"] == "${{ inputs.matrix-set }}" and 'echo "MATRIX_SET=$MATRIX_SET" >> "$GITHUB_ENV"' in first["run"], \
        f"publish-{kind}s: the set is not in the job's environment before the tree is assembled (the lost-race rebuild reads it there)"
    tree = open(f"{here}/.github/actions/publish-{kind}s/publish-tree.sh").read()
    assert re.search(r'(?m)^".*/\.\./release-matrix/cells\.sh" %s "\$tree" "\$src"$' % kind, tree), f"publish-{kind}s/publish-tree.sh does not write cells.tsv"
    qd = [s for s in d["jobs"]["build"]["steps"] if "/actions/quick-deps@" in s.get("uses", "")]
    bld = [k for k, s in enumerate(d["jobs"]["build"]["steps"]) if f"/actions/build-{kind}@" in s.get("uses", "")][0]
    assert len(qd) == 1 and d["jobs"]["build"]["steps"].index(qd[0]) == bld + 1 and qd[0]["with"]["kind"] == kind, \
        f"{path}: quick-deps does not run once, right after the build installed its dependencies"
    def runs(inputs, rt, set_):
        full = dict(base, **inputs)
        tag = ev(d["jobs"]["build"]["env"]["RELEASE_TAG"], full, "push", rt)
        e = qd[0]["if"].replace("env.RELEASE_TAG", repr(tag))
        return bool(ev("${{ " + e + " }}", full, "push", rt, needs=O(preflight=O(outputs=O(set=set_)))))
    assert runs({"publish": True}, "tag", "full"), f"{path}: a full release does not check its dependencies"
    assert runs({"publish": True, "source-ref": "v1.2.0"}, "branch", "full"), f"{path}: a full release of another tag does not check its dependencies"
    assert not runs({"publish": True}, "tag", "quick"), f"{path}: an interim tag is held to full dependencies"
    assert not runs({"staged": True}, "branch", "full"), f"{path}: a staged run is held to full dependencies"
    assert not runs({}, "branch", "full"), f"{path}: a dry run is held to full dependencies"
    assert not runs({"publish": True, "channel-deps": False}, "tag", "full"), f"{path}: a build that takes nothing from the channel asks the channel"
pro = yaml.safe_load(open(f"{here}/.github/workflows/promote-staged.yml"))
sets = [s["with"].get("matrix-set") for j in pro["jobs"].values() for s in j.get("steps", []) if re.search(r"/actions/publish-(rpm|deb)s@", s.get("uses", ""))]
assert sets == ["full", "full"], f"promote-staged.yml records {sets}: a promotion holds every cell of the matrix"
print("ok   the publish is told the set and writes cells.tsv; a full release checks its dependencies, nothing else does; a promotion is full")
PY

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }
act=$here/.github/actions/release-matrix
row() { awk -F'\t' -v n="$2" -v v="$3" '$1 == n && $2 == v {print $3 "|" $4}' "$1/cells.tsv"; }

# ---- cells.sh on an rpm tree and a deb tree
r=$t/rpm; mkdir -p "$r"/fedora/{44,45}/{x86_64,aarch64,noarch,SRPMS} "$t/q" "$t/f"
for f in 44/x86_64/omx-lib-devel-3.14.0-1.fc44.x86_64 45/x86_64/omx-lib-devel-3.14.0-1.fc45.x86_64 44/SRPMS/omx-lib-3.14.0-1.fc44.src \
    44/x86_64/omx-lib-devel-3.13.0-1.fc44.x86_64 44/aarch64/omx-lib-devel-3.13.0-1.fc44.aarch64 45/x86_64/omx-lib-devel-3.13.0-1.fc45.x86_64 \
    45/aarch64/omx-lib-devel-3.13.0-1.fc45.aarch64 44/noarch/omx-lang-ca-1.0.0-1.fc44.noarch; do : > "$r/fedora/$f.rpm"; done
: > "$t/q/omx-lib-devel-3.14.0-1.fc44.x86_64.rpm"; : > "$t/q/omx-lib-3.14.0-1.fc44.src.rpm"
MATRIX_SET=quick "$act/cells.sh" rpm "$r" "$t/q" >/dev/null
[ "$(head -1 "$r/cells.tsv")" = "$(printf '# package\tversion\tset\tcells')" ] || fail "cells.tsv has no header: $(head -1 "$r/cells.tsv")"
[ "$(row "$r" omx-lib-devel 3.14.0)" = "quick|fc44/x86_64 fc45/x86_64" ] || fail "the quick version reads $(row "$r" omx-lib-devel 3.14.0)"
[ "$(row "$r" omx-lib-devel 3.13.0)" = "-|fc44/aarch64 fc44/x86_64 fc45/aarch64 fc45/x86_64" ] || fail "a version published before sets were recorded reads $(row "$r" omx-lib-devel 3.13.0)"
[ "$(row "$r" omx-lang-ca 1.0.0)" = "-|fc44/noarch" ] || fail "a noarch package reads $(row "$r" omx-lang-ca 1.0.0)"
! grep -q $'^omx-lib\t' "$r/cells.tsv" || fail "a source package has a line"
[ "$(wc -l < "$r/cells.tsv")" = 4 ] || fail "cells.tsv has $(wc -l < "$r/cells.tsv") lines, want the header and 3"
# another package goes out: the quick mark of the first stays
: > "$r/fedora/44/x86_64/omx-other-0.2.0-1.fc44.x86_64.rpm"; : > "$t/f/omx-other-0.2.0-1.fc44.x86_64.rpm"
MATRIX_SET=full "$act/cells.sh" rpm "$r" "$t/f" >/dev/null
[ "$(row "$r" omx-lib-devel 3.14.0)" = "quick|fc44/x86_64 fc45/x86_64" ] || fail "another package's publish changed the quick mark: $(row "$r" omx-lib-devel 3.14.0)"
[ "$(row "$r" omx-other 0.2.0)" = "full|fc44/x86_64" ] || fail "the full publish reads $(row "$r" omx-other 0.2.0)"
# a run that names no set (the purge, a tree script run by hand) claims nothing and loses nothing
"$act/cells.sh" rpm "$r" "$t/f" >/dev/null
[ "$(row "$r" omx-lib-devel 3.14.0)|$(row "$r" omx-other 0.2.0)" = "quick|fc44/x86_64 fc45/x86_64|full|fc44/x86_64" ] || fail "a run with no set rewrote the sets"
# the version goes out again for the full matrix: its cells grow and the mark is replaced
: > "$r/fedora/44/aarch64/omx-lib-devel-3.14.0-1.fc44.aarch64.rpm"; : > "$r/fedora/45/aarch64/omx-lib-devel-3.14.0-1.fc45.aarch64.rpm"
MATRIX_SET=full "$act/cells.sh" rpm "$r" "$t/q" >/dev/null
[ "$(row "$r" omx-lib-devel 3.14.0)" = "full|fc44/aarch64 fc44/x86_64 fc45/aarch64 fc45/x86_64" ] || fail "the full release of a quick version reads $(row "$r" omx-lib-devel 3.14.0)"
# the files go (a purge): so do the lines
find "$r" -name '*.rpm' -delete
"$act/cells.sh" rpm "$r" >/dev/null
[ "$(cat "$r/cells.tsv")" = "$(printf '# package\tversion\tset\tcells')" ] || fail "an emptied tree still lists $(sed 1d "$r/cells.tsv")"
if MATRIX_SET=some "$act/cells.sh" rpm "$r" >/dev/null 2>&1; then fail "MATRIX_SET=some was taken"; fi
ok "cells.sh rpm: cells from the tree, the set from the run, kept by other runs, replaced by a full release, gone with the files"

d=$t/deb; mkdir -p "$d"/debian/{bookworm,trixie}/{amd64,arm64,all} "$t/dq/trixie"
for f in trixie/arm64/libomx-lib-dev_3.14.0+git20261113101500.abc1234_arm64 trixie/arm64/libomx-lib-dev_3.13.0-1_arm64 trixie/amd64/libomx-lib-dev_3.13.0-1_amd64 \
    bookworm/arm64/libomx-lib-dev_3.13.0-1_arm64 bookworm/amd64/libomx-lib-dev_3.13.0-1_amd64 trixie/all/omx-lang-ca_1.0.0_all; do : > "$d/debian/$f.deb"; done
: > "$t/dq/trixie/libomx-lib-dev_3.14.0+git20261113101500.abc1234_arm64.deb"
MATRIX_SET=quick "$act/cells.sh" deb "$d" "$t/dq" >/dev/null
[ "$(row "$d" libomx-lib-dev 3.14.0)" = "quick|trixie/arm64" ] || fail "the quick deb reads $(row "$d" libomx-lib-dev 3.14.0)"
[ "$(row "$d" libomx-lib-dev 3.13.0)" = "-|bookworm/amd64 bookworm/arm64 trixie/amd64 trixie/arm64" ] || fail "the full deb reads $(row "$d" libomx-lib-dev 3.13.0)"
[ "$(row "$d" omx-lang-ca 1.0.0)" = "-|trixie/all" ] || fail "an all package reads $(row "$d" omx-lang-ca 1.0.0)"
ok "cells.sh deb: the upstream version without revision or +git suffix, all as a cell"

# ---- quick-deps.sh
printf '# package\tversion\tset\tcells\nomx-lib-devel\t3.13.0\tfull\tfc44/x86_64 fc44/aarch64\nomx-lib-devel\t3.14.0\tquick\tfc44/x86_64 fc45/x86_64\nomx-old\t1.0.0\t-\tfc44/x86_64\n' > "$t/cells.tsv"
printf 'glibc 2.42\nomx-lib-devel 3.14.0\nomx-old 1.0.0\n' > "$t/inst-quick"
printf 'glibc 2.42\nomx-lib-devel 3.13.0\nomx-old 1.0.0\n' > "$t/inst-full"
if out=$("$act/quick-deps.sh" rpm "$t/cells.tsv" "$t/inst-quick" 2>&1); then fail "a release built on a quick-only version passed: $out"; fi
echo "$out" | grep -q '::error::.*omx-lib-devel 3.14.0.*quick set alone (fc44/x86_64 fc45/x86_64)' || fail "the quick-only dependency is not named with its cells: $out"
out=$("$act/quick-deps.sh" rpm "$t/cells.tsv" "$t/inst-full" 2>&1) || fail "a release built on full versions is refused: $out"
echo "$out" | grep -q '1 quick version(s) recorded' || fail "the pass does not say what it looked at: $out"
echo 'not a cells file' > "$t/bad.tsv"
if "$act/quick-deps.sh" rpm "$t/bad.tsv" "$t/inst-full" >/dev/null 2>&1; then fail "a file that is not a cells.tsv was read as one"; fi
if "$act/quick-deps.sh" rpm "$t/none.tsv" "$t/inst-full" >/dev/null 2>&1; then fail "a missing cells.tsv is a pass"; fi
: > "$t/empty"
if "$act/quick-deps.sh" rpm "$t/cells.tsv" "$t/empty" >/dev/null 2>&1; then fail "an empty list of installed packages is a pass"; fi
# over HTTP, as the build job reads it: 200 is read, 404 passes and says so, anything else fails
mkdir -p "$t/www/rpm" "$t/bin"; cp "$t/cells.tsv" "$t/www/rpm/cells.tsv"
cat > "$t/bin/curl" <<'SH'
#!/bin/bash
# a channel on disk: the last argument is the URL, -o names the file, the status goes to standard output
url=${!#}; out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
case $url in
*/down/*) echo 503 ;;
*) f=$WWW/${url#https://channel.test/}; if [ -f "$f" ]; then cp "$f" "$out"; echo 200; else echo 404; fi ;;
esac
SH
chmod +x "$t/bin/curl"
web() { WWW=$t/www PATH=$t/bin:$PATH "$act/quick-deps.sh" "$@" 2>&1; }
if out=$(web rpm https://channel.test/rpm/cells.tsv "$t/inst-quick"); then fail "over HTTP a quick-only dependency passed: $out"; fi
echo "$out" | grep -q 'omx-lib-devel 3.14.0' || fail "over HTTP the dependency is not named: $out"
out=$(web deb https://channel.test/deb/cells.tsv "$t/inst-quick") || fail "a channel with no cells.tsv yet is refused: $out"
echo "$out" | grep -q 'not served yet' || fail "the 404 is not said: $out"
if out=$(web rpm https://channel.test/down/rpm/cells.tsv "$t/inst-full"); then fail "a channel that answers 503 is a pass: $out"; fi
ok "quick-deps.sh: a quick-only version is refused by name and cells; full, older, and a channel with no record pass; an unreadable record fails"
# a quick run names the cells it skipped, a full run has none to name (Open-Mixer/.github#59)
note() { KIND=$1 RELEASES=$2 ARCHES=$3 MATRIX=$4 WAVE='' STAGED='' SOURCE_REF='' CATCH_UP='' EVENT=workflow_dispatch REF_TYPE='' \
    GITHUB_OUTPUT=$t/note.out "$act/matrix.sh" 2>&1 | grep '^::notice::[a-z]* matrix'; }
out=$(note deb '["bookworm", "trixie"]' '["amd64", "arm64"]' quick)
echo "$out" | grep -q '(skipped while quick: bookworm amd64, bookworm arm64)$' || fail "a quick deb run does not name what it skipped: $out"
out=$(note rpm '["44", "45"]' '["x86_64", "aarch64"]' quick)
echo "$out" | grep -q '(skipped while quick: fc44 aarch64, fc45 aarch64)$' || fail "a quick rpm run does not name what it skipped: $out"
out=$(note deb '["bookworm", "trixie"]' '["amd64", "arm64"]' full)
echo "$out" | grep -q 'skipped' && fail "a full run names a skipped cell: $out"
out=$(note deb '["bookworm"]' '["amd64"]' quick)
echo "$out" | grep -q 'skipped' && fail "a run that fell back to the full matrix names a skipped cell: $out"
ok "matrix.sh: a quick run names the cells it skipped; full, and the fallback to full, name none"
echo "release-matrix: all passed"
