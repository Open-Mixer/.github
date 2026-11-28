#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""arch-coverage.py [--shared <dir>] <repo dir or workflow file> ...

Does every publishing build a caller workflow runs cover the full matrix (.github/actions/release-matrix/full.txt)?
Owner ruling 2026-11-26: every package in every cell, rpm fc45 x86_64 and aarch64, deb trixie amd64 and arm64.
amd64 went missing one layer at a time (pdq's release arches, plugin-hostd's push arch-matrix, omx-plugins'
arch-matrix ["arm64"], a staged dispatch given no matrix that built the quick set): each was a caller narrowing the
cells by a line nobody re-read. This reads each job of the caller's .github/workflows/*.yml that uses
Open-Mixer/.github's build-rpm.yml or build-deb.yml and renders, for the runs that publish,

  push-devel  a merge to devel (the real package, staged, then promoted unchanged)
  tag         a v<version> tag push
  staged      a workflow_dispatch with staged: true and every other input at the caller's default

what the shared workflow would build: the caller's `with:` evaluated in the run's context, handed to the shared
workflow's release-matrix step (the one in --shared, default this repository, so the shared defaults are judged
too), and that step's own matrix.sh run on it, as the runner runs it. A run whose cells lack a cell of full.txt for
a release it builds is ARCH-NARROW, naming the file, the job, the run and the missing cells. A caller job whose `if:`
is false for a run is not judged for it. OMX_RELEASE_MATRIX is taken as unset: the organisation's switch is not a
caller's narrowing.

A job that builds its own packages (no shared workflow) in a fedora: or debian: container of a workflow a tag
runs, with a literal strategy.matrix.arch list, is judged by that list (mod-host's release.yml).

A caller whose cell inputs (arch-matrix, fedora-versions, suite-matrix, matrix, staged, publish) read another job's output
(needs.<job>.outputs.<x>) derives its cells: it is DERIVED, named and not judged here; a .github/release-matrix.json beside it (plugin-qualify's declaration) is judged instead, its
rpm.arches and deb.arches against full.txt, and so is a packaging/release-arches (plugin-db-qualification's,
`<deb|rpm> <arch>...` a line).

Exit 0 every publishing run covers the full matrix, 1 an ARCH-NARROW line, 2 a file could not be read or rendered
(never a pass).
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USES = re.compile(r"^Open-Mixer/\.github/\.github/workflows/build-(rpm|deb)\.yml@")
KEYS = {"rpm": ("fedora-versions", "fedora"), "deb": ("suite-matrix", "suite")}
# the inputs of build-rpm.yml / build-deb.yml that choose the cells a run builds, or whether it publishes at all
CELL_INPUTS = {"arch-matrix", "fedora-versions", "suite-matrix", "matrix", "staged", "publish", "source-ref", "catch-up"}
RUNS = {  # name -> (event, ref type, branch, staged dispatch)
    "push-devel": ("push", "branch", "devel", False),
    "tag": ("push", "tag", "main", False),
    "staged": ("workflow_dispatch", "branch", "devel", True),
}


class NotMeasured(Exception):
    pass


class O(dict):
    """a context object: a name it lacks reads null, as GitHub reads an unset input or variable"""
    __getattr__ = dict.get

    def __missing__(self, key):
        return None


def full_cells(shared):
    cells = {"rpm": set(), "deb": set()}
    with open(f"{shared}/.github/actions/release-matrix/full.txt") as f:
        for line in f:
            w = line.split("#", 1)[0].split()
            if not w:
                continue
            if len(w) != 3 or w[0] not in cells:
                raise NotMeasured(f"full.txt: not '<kind> <release> <arch>': {line.strip()}")
            cells[w[0]].add((w[1], w[2]))
    if not cells["rpm"] or not cells["deb"]:
        raise NotMeasured("full.txt names no rpm or no deb cell")
    return cells


class Derived(Exception):
    pass


def ev(expr, ctx):
    """a GitHub expression, evaluated over ctx (inputs, github, vars, needs); a needs.* read raises Derived"""
    e = str(expr).strip() if expr is not None else ""
    if "${{" not in e:
        return expr
    if not (e.startswith("${{") and e.endswith("}}") and e.count("${{") == 1):
        return re.sub(r"\$\{\{(.*?)\}\}", lambda m: text(ev("${{" + m.group(1) + "}}", ctx)), e)
    e = e[3:-2].strip()
    if re.search(r"\bneeds\.", e):
        raise Derived(e)
    e = re.sub(r"\b(inputs|vars|secrets)\.([A-Za-z0-9_-]+)", lambda m: f'{m.group(1)}["{m.group(2)}"]', e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    env = {"inputs": O(ctx["inputs"]), "vars": O(), "secrets": O(), "github": O(ctx["github"]),
           "true": True, "false": False, "null": None,
           "startsWith": lambda a, b: str(a or "").startswith(str(b)), "fromJSON": json.loads,
           "format": lambda f, *a: re.sub(r"\{(\d+)\}", lambda m: str(a[int(m.group(1))]), f)}
    try:
        return eval(e, {"__builtins__": {}}, env)  # noqa: S307 - our own workflow files, no builtins
    except Exception as x:  # an expression this renderer cannot read is not a pass
        raise NotMeasured(f"cannot render ${{{{ {e} }}}}: {x}")


def text(v):
    return {True: "true", False: "false", None: ""}.get(v, v) if isinstance(v, (bool, type(None))) else str(v)


def github(run):
    event, ref_type, branch, _ = RUNS[run]
    return {"event_name": event, "ref_type": ref_type, "ref_name": "v1.0.0" if ref_type == "tag" else branch,
            "ref": "refs/tags/v1.0.0" if ref_type == "tag" else f"refs/heads/{branch}", "repository": "o/r"}


def on_of(doc):
    return doc.get(True) or doc.get("on") or {}


def dispatch_defaults(doc):
    on = on_of(doc)
    wd = on.get("workflow_dispatch") if isinstance(on, dict) else None
    out = {}
    for k, v in ((wd or {}).get("inputs") or {}).items():
        out[k] = (v or {}).get("default", "" if (v or {}).get("type") != "boolean" else False)
    return out


def triggers(doc):
    on = on_of(doc)
    if isinstance(on, str):
        on = {on: None}
    if isinstance(on, list):
        on = {k: None for k in on}
    have = set()
    push = on.get("push") if "push" in on else None
    if "push" in on:
        p = push or {}
        if not p or "tags" in p:
            have.add("tag")
        if not p or "devel" in (p.get("branches") or []):
            have.add("push-devel")
    if "workflow_dispatch" in on:
        have.add("staged")
    return have


def render(shared, kind, with_eval, run):
    """the cells the shared workflow builds for this caller `with:` (evaluated) on this run"""
    sw = yaml.safe_load(open(f"{shared}/.github/workflows/build-{kind}.yml"))
    decl = on_of(sw)["workflow_call"]["inputs"]
    inputs = {k: (v or {}).get("default") for k, v in decl.items()}
    unknown = sorted(set(with_eval) - set(decl))
    if unknown:
        raise NotMeasured(f"build-{kind}.yml has no input {', '.join(unknown)}")
    inputs.update(with_eval)
    step = [s for s in sw["jobs"]["preflight"]["steps"] if "/actions/release-matrix@" in str(s.get("uses", ""))]
    if len(step) != 1:
        raise NotMeasured(f"build-{kind}.yml: no single release-matrix step in its preflight")
    ctx = {"inputs": inputs, "github": github(run)}
    w = {k: text(ev(v, ctx)) for k, v in step[0]["with"].items()}
    event, ref_type, branch, _ = RUNS[run]
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "KIND": kind, "MATRIX": w.get("matrix", ""),
           "WAVE": "", "STAGED": w.get("staged", "false"), "SOURCE_REF": w.get("source-ref", ""),
           "RELEASES": w["releases"], "ARCHES": w["arches"], "EVENT": event, "REF_TYPE": ref_type,
           "REF_NAME": github(run)["ref_name"], "CATCH_UP": "false"}
    with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
        env["GITHUB_OUTPUT"] = out.name
        p = subprocess.run([f"{shared}/.github/actions/release-matrix/matrix.sh"], env=env, capture_output=True, text=True)
        if p.returncode:
            return None, (p.stdout + p.stderr).strip().splitlines()[-1:]
        got = dict(line.rstrip("\n").split("=", 1) for line in open(out.name) if "=" in line)
    key = KEYS[kind][1]
    return {(c[key], c["arch"]) for c in json.loads(got["cells"])}, got.get("set", "")


def judge_decl(path, full, say):
    """plugin-qualify's .github/release-matrix.json: rpm.arches and deb.arches against full.txt"""
    d = json.load(open(path))
    red = 0
    for kind, rel_key in (("rpm", "fedora"), ("deb", "suites")):
        part = d.get(kind) or {}
        for rel in part.get(rel_key) or []:
            want = {a for r, a in full[kind] if r == str(rel)}
            missing = sorted(want - set(part.get("arches") or []))
            if missing:
                red = 1
                say(f"ARCH-NARROW {path}: {kind} {rel} declares {part.get('arches')}, lacks {' '.join(missing)} "
                    f"(full.txt; owner ruling 2026-11-26)")
    return red


def judge_own_build(path, name, job, runs, full, say):
    """a job that builds packages itself (mod-host's release.yml): a literal strategy.matrix.arch list in a fedora: or
    debian: container of a workflow a tag runs is its cells; it must hold every architecture full.txt names"""
    if "tag" not in runs:
        return 0, 0
    image = str(job.get("container") or "")
    if isinstance(job.get("container"), dict):
        image = str(job["container"].get("image", ""))
    kind = "rpm" if "fedora:" in image else "deb" if "debian:" in image else None
    arches = ((job.get("strategy") or {}).get("matrix") or {}).get("arch")
    if kind is None or not isinstance(arches, list):
        return 0, 0
    want = {a for _, a in full[kind]}
    missing = sorted(want - {str(a) for a in arches})
    if missing:  # OWN-MARK
        say(f"ARCH-NARROW {path}: job {name} (tag): builds its own {kind} for {' '.join(map(str, arches))}, lacks "
            f"{' '.join(missing)} (full.txt; owner ruling 2026-11-26)")
        return 1, 1
    return 0, 1


def judge_release_arches(path, full, say):
    """plugin-db-qualification's packaging/release-arches: `<deb|rpm> <arch>...` per line, against full.txt"""
    red = 0
    for line in open(path):
        w = line.split("#", 1)[0].split()
        if not w or w[0] not in full:
            continue
        missing = sorted({a for _, a in full[w[0]]} - set(w[1:]))
        if missing:
            red = 1
            say(f"ARCH-NARROW {path}: {w[0]} releases {' '.join(w[1:]) or 'nothing'}, lacks {' '.join(missing)} "
                f"(full.txt; owner ruling 2026-11-26)")
    return red


def judge_file(path, shared, full, say):
    try:
        doc = yaml.safe_load(open(path))
    except (OSError, yaml.YAMLError) as e:
        raise NotMeasured(f"{path}: {e}")
    if not isinstance(doc, dict):
        return 0, 0
    runs = triggers(doc)
    defaults = dispatch_defaults(doc)
    red = judged = 0
    for name, job in (doc.get("jobs") or {}).items():
        m = USES.match(str((job or {}).get("uses", "")))
        if not m:
            r, j = judge_own_build(path, name, job or {}, runs, full, say)
            red |= r
            judged += j
            continue
        kind = m.group(1)
        for run in sorted(runs):
            inputs = dict(defaults, staged=True) if RUNS[run][3] else {}
            ctx = {"inputs": inputs, "github": github(run)}
            try:
                if "if" in job and not ev("${{ %s }}" % str(job["if"]).replace("${{", "").replace("}}", ""), ctx):
                    continue
            except Derived:
                pass  # a job gated on another job's result runs when that one succeeds: judged as running
            with_eval, derived = {}, []
            for k, v in (job.get("with") or {}).items():
                try:
                    with_eval[k] = ev(v, ctx)
                except Derived as d:
                    if k in CELL_INPUTS:
                        derived.append(f"{k}: {d}")
                    else:
                        with_eval[k] = None  # an input that chooses no cell: its value does not matter here
            if derived:
                say(f"DERIVED {path}: job {name} ({run}): its cells come from another job ({'; '.join(derived)}); not judged here")
                continue
            if RUNS[run][3] and not with_eval.get("staged"):
                continue  # this caller's dispatch never stages through this job
            if not RUNS[run][3] and run == "tag" and not with_eval.get("publish") and "publish" in (job.get("with") or {}):
                continue  # a tag that does not publish through this job (the tag path promotes elsewhere)
            cells, info = render(shared, kind, with_eval, run)
            judged += 1
            if cells is None:
                say(f"ARCH-NARROW {path}: job {name} ({run}): the shared build-{kind}.yml refuses it: {' '.join(info)}")
                red = 1
                continue
            for rel in sorted({r for r, _ in cells}):
                want = {a for r, a in full[kind] if r == rel}
                have = {a for r, a in cells if r == rel}
                missing = sorted(want - have)
                if want and missing:  # COVERAGE-MARK
                    red = 1
                    say(f"ARCH-NARROW {path}: job {name} ({run}): {kind} {rel} builds {' '.join(sorted(have))} "
                        f"({info}), lacks {' '.join(missing)} (full.txt; owner ruling 2026-11-26)")
    return red, judged


def main(argv):
    shared = HERE
    if len(argv) > 2 and argv[1] == "--shared":
        shared, argv = argv[2], [argv[0]] + argv[3:]
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    lines = []
    try:
        full = full_cells(shared)
        red = judged = 0
        for target in argv[1:]:
            files = [target] if os.path.isfile(target) else sorted(glob.glob(f"{target}/.github/workflows/*.y*ml"))
            if not files:
                raise NotMeasured(f"{target}: no workflow file")
            decl = f"{target}/.github/release-matrix.json"
            if os.path.isdir(target) and os.path.isfile(decl):
                red |= judge_decl(decl, full, lines.append)
            arches_file = f"{target}/packaging/release-arches"
            if os.path.isdir(target) and os.path.isfile(arches_file):
                red |= judge_release_arches(arches_file, full, lines.append)
            for f in files:
                r, j = judge_file(f, shared, full, lines.append)
                red |= r
                judged += j
    except NotMeasured as e:
        print("\n".join(lines))
        print(f"arch-coverage: {e}")
        print("UNCHECKED: this is not a pass")
        return 2
    print("\n".join(lines))
    print(f"arch-coverage: {judged} publishing run(s) rendered against full.txt: "
          f"{'ARCH-NARROW above' if red else 'every one covers the full matrix'}")
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
