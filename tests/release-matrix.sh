#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The quick and the full release matrix, offline (docs/release-operations.md, "The quick set and the full matrix").
# Proves:
#   - the quick set is written once, in .github/actions/release-matrix/quick.txt, and is fc44 x86_64 and fc45 x86_64
#     for rpm and trixie arm64 for deb;
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
           "vars": O(OMX_RELEASE_MATRIX=var or ""), "steps": steps or O(), "needs": needs or O(), "matrix": matrix or O()}
    return eval(e, {"__builtins__": {}}, env)

def text(v):
    return {True: "true", False: "false", None: ""}.get(v, v) if isinstance(v, (bool, type(None))) else str(v)

# ---- the quick set, written once
quick = [l.split() for l in open(f"{act}/quick.txt") if l.strip() and not l.startswith("#")]
assert quick == [["rpm", "44", "x86_64"], ["rpm", "45", "x86_64"], ["deb", "trixie", "arm64"]], f"quick.txt is {quick}"
action = yaml.safe_load(open(f"{act}/action.yml"))
step = action["runs"]["steps"]
assert len(step) == 1 and step[0]["run"].strip() == '"$GITHUB_ACTION_PATH/matrix.sh"', "release-matrix is more than one call of matrix.sh"
sh = open(f"{act}/matrix.sh").read()
assert "quick.txt" in sh and not re.search(r"\b(trixie|bookworm|x86_64|aarch64|arm64|amd64)\b", re.sub(r"(?m)^\s*#.*$", "", sh)), \
    "matrix.sh names a cell of its own: the quick set is quick.txt alone"
print("ok   the quick set is fc44 x86_64, fc45 x86_64 (rpm) and trixie arm64 (deb), written in quick.txt alone")

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
                 "source-ref": "${{inputs.source-ref}}", "releases": "${{inputs.%s}}" % rel_in, "arches": "${{inputs.arch-matrix}}"}, f"{path}: release-matrix is given {w}"
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
QUICK = {"rpm": ["fc44, x86_64", "fc45, x86_64"], "deb": ["trixie, arm64"]}
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

# the three quick cells and the eight of a release, counted across the two workflows
q = sum(len(run(k, {"staged": True}, "workflow_dispatch", "branch", None)[0].jobs) for k in WF)
f = sum(len(run(k, {"publish": True}, "push", "tag", None)[0].jobs) for k in WF)
assert (q, f) == (3, 8), f"a staged run builds {q} cells and a release {f}, want 3 and 8"
print("ok   a staged run is 3 build jobs and 3 install checks, a release 8 and 8")

# a caller built for x86_64 alone: the quick rpm cells, and its own full deb matrix because trixie arm64 is not in it
got, _ = run("rpm", dict(X86["rpm"], staged=True), "workflow_dispatch", "branch", None)
assert (got.set, got.jobs, got.first) == ("quick", QUICK["rpm"], "x86_64"), got
got, log = run("deb", dict(X86["deb"], staged=True), "workflow_dispatch", "branch", None)
assert (got.set, got.jobs) == ("full", ["bookworm, amd64", "trixie, amd64"]) and "no deb cell" in log, f"{got} {log}"
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
print("ok   a caller's narrower matrix is kept: x86_64 alone builds its full deb matrix, one Fedora release stays one")

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
PY
