# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Publish only by tagging (docs/release-operations.md), decided by EXACT MATCH, never by evaluating an expression.

A step PUBLISHES by what it does: `gh release`, `npm publish`, an rsync/rclone/s3/curl upload, any `git push`, a
`gh api` write, a third-party release action, or a call of a local composite action that contains one (the channel push
helper is one). Names are not read.

The rules, each a string comparison:
 1. A job with a publishing step carries a job-level `if` that is, whitespace-normalised and without its `${{ }}`,
    EXACTLY   github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')   . Anything else (an extra `||` or
    `&&`, `always()`, an input, a step-level `if` instead) is refused by job name.
 2. Not publishing, by proof: (a) a push whose `what` is a LITERAL (no `${{`) that, normalised (no `..`, no `//`),
    starts with staging/ : the stage builds and the purge of staging, which feed the next layer and are not the
    release channel consumers install from; (b) a step of a composite action whose own `if` is exactly one of the three
    canonical sign gates, when the CALLER gives that action a literal sign of false (or none, the default being false):
    it assembles a tree and pushes nothing. Any expression where a literal is needed is not a proof.
A workflow a person can start by hand takes no input named like a publish switch. .yml and .yaml, workflows and
composite actions, are all read. LIMIT: a script of the repository that itself does the push or the upload, and is not in
an action directory, is invisible (Open-Mixer/.github#132).  Usage: publish_only_by_tag.py <repo root> | --selftest
"""
import os, re, shutil, sys, tempfile
import yaml

TAG = "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
SIGN_REAL = "inputs.sign == 'true' && inputs.staging != 'true'"
SIGN_STAGING = "inputs.sign == 'true' && inputs.staging == 'true'"
SIGN_GATES = {"inputs.sign == 'true'", SIGN_REAL, SIGN_STAGING}
PUSH_HELPER = "channel-push"

RUN_PUBLISHES = [
    (re.compile(r"\bgh\s+release\s+(create|upload|edit|delete)\b"), "gh release"),
    (re.compile(r"\b(npm|pnpm)\s+(publish|dist-tag)\b|\byarn\s+npm\s+publish\b"), "npm publish"),
    (re.compile(r"\b(aws\s+s3\s+(cp|sync|mv)|s3cmd\s+(put|sync)|rclone\s+(copy|sync|move|copyto)|rsync|scp|gsutil\s+(cp|rsync)|mc\s+cp|twine\s+upload|cargo\s+publish|docker\s+push)\b"), "an upload"),
    (re.compile(r"\bgit\b[^\n]*\bpush\b|^\s*push\s+origin\b", re.M), "git push"),
    (re.compile(r"\bgh\s+api\b[^\n]*(git/refs|/releases|/dispatches|/contents/)"), "a gh api write"),
]
CURL_UPLOAD = re.compile(r"(?:^|\s)(?:-T\S*|--upload-file\S*)(?:\s|=|$)")
CURL_WRITE = re.compile(r"(?:-X\s*|--request[ =]\s*)(?:POST|PUT|PATCH)\b|(?:^|\s)(?:-d|-F|--data\S*|--form\S*)(?:\s|=|$)")
CURL_TARGET = re.compile(r"releases|uploads")
USES_PUBLISHES = re.compile(r"gh-release|pypi-publish|deploy-pages|gh-pages|pages-deploy|upload-release-asset|create-release|action-gh-release")


def norm_if(v):
    """a job or step `if` as text: no ${{ }}, one space between words"""
    t = re.sub(r"\s+", " ", str(v).strip())
    m = re.fullmatch(r"\$\{\{(.*)\}\}", t)
    return (m.group(1) if m else t).strip()


def literal(v):
    """a with: value that is a plain string (no expression), lower-cased when true/false; None for an expression"""
    t = str(v).strip().strip("'\"")
    if "${{" in t: return None
    return t.lower() if t.lower() in ("true", "false") else t


def staging_literal(v):
    """True only for a literal path that, normalised, is under staging/ (no .., no //, no expression)"""
    t = literal(v)
    return bool(t) and t.startswith("staging/") and ".." not in t.split("/") and "//" not in t and t == os.path.normpath(t) and t != "staging/"


def run_text(step):
    t = re.sub(r"\\\n\s*", " ", str(step.get("run", "")))
    return "\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#"))


def run_publishes(t):
    for rx, what in RUN_PUBLISHES:
        for m in rx.finditer(t):
            end = t.find("\n", m.end())
            if what == "npm publish" and "--dry-run" in t[m.start():end if end >= 0 else None]: continue
            return what
    for line in t.splitlines():
        if re.search(r"\bcurl\b", line):
            if CURL_UPLOAD.search(line): return "a curl upload"
            if CURL_WRITE.search(line) and CURL_TARGET.search(line): return "a curl write to a releases or uploads API"
    return None


class Repo:
    def __init__(self, root):
        self.root = root
        self.actions = {}
        d = os.path.join(root, ".github", "actions")
        for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            for fn in ("action.yml", "action.yaml"):
                p = os.path.join(d, name, fn)
                if os.path.exists(p): self.actions[name] = yaml.safe_load(open(p)); break
        self.memo = {}

    def local(self, uses):
        m = re.match(r"(?:\./|[\w.-]+/[\w.-]+/)\.github/actions/([\w-]+)(?:@.*)?$", uses)
        return m.group(1) if m and m.group(1) in self.actions else None

    def default(self, name, key):
        inp = (self.actions[name].get("inputs") or {}).get(key)
        return inp.get("default") if isinstance(inp, dict) else None

    def findings(self, name, stack=()):
        """[{'what', 'dest', 'gated'}] for EVERY publishing step of a composite action: gated when its own step `if` is
        one of the canonical sign gates"""
        if name in self.memo: return self.memo[name]
        if name in stack: return []
        steps = ((self.actions[name].get("runs") or {}).get("steps")) or []
        out = []
        for st in steps:
            for f in self.step_findings(st, stack + (name,)):
                f = dict(f); f["gated"] = norm_if(st["if"]) if "if" in st and norm_if(st["if"]) in SIGN_GATES else None
                out.append(f)
        d = os.path.join(self.root, ".github", "actions", name)
        for fn in sorted(os.listdir(d)):
            if not fn.endswith((".sh", ".py")) or fn.startswith(("selftest", "test")): continue
            txt = re.sub(r"\\\n\s*", " ", open(os.path.join(d, fn), errors="replace").read())
            txt = "\n".join(l for l in txt.splitlines() if not l.lstrip().startswith("#"))
            what = None
            for rx, w in RUN_PUBLISHES:
                # a script publishes when a LINE starts with the command (a quoted example or a fixture does not)
                if re.search(r"^\s*(?:\w+=\S+\s+)*(?:" + rx.pattern.replace("^\\s*", "").replace("\\b", "", 1) + ")", txt, re.M): what = w; break
            if what is None and any(re.match(r"\s*curl\b", l) and run_publishes(l) for l in txt.splitlines()): what = "a curl upload"
            if not what: continue
            for st in [x for x in steps if fn in str(x.get("run", ""))] or [{}]:
                out.append({"what": what + " in " + fn, "dest": None, "gated": norm_if(st["if"]) if "if" in st and norm_if(st["if"]) in SIGN_GATES else None})
        self.memo[name] = out
        return out

    def step_findings(self, st, stack=()):
        """what one step publishes: [{'what', 'dest', 'gated', 'sign'}]; 'sign' is the literal sign given to a called action"""
        found = []
        uses = str(st.get("uses", ""))
        if uses:
            name = self.local(uses)
            if name:
                w = st.get("with") or {}
                sign = literal(w["sign"]) if "sign" in w else literal(self.default(name, "sign") or "false")
                staging = literal(w["staging"]) if "staging" in w else literal(self.default(name, "staging") or "false")
                inner = self.findings(name, stack)
                for f in inner:
                    dest = w.get("what") if name == PUSH_HELPER else f["dest"]
                    found.append({"what": f"{f['what']} (through {name})", "dest": dest, "gated": f["gated"], "sign": sign, "staging": staging})
                if name == PUSH_HELPER and not inner:
                    found.append({"what": "the push helper", "dest": w.get("what"), "gated": None, "sign": sign, "staging": None})
            elif USES_PUBLISHES.search(uses):
                found.append({"what": f"the action {uses}", "dest": None, "gated": None, "sign": None, "staging": None})
        if "run" in st:
            what = run_publishes(run_text(st))
            if what: found.append({"what": what, "dest": None, "gated": None, "sign": None, "staging": None})
        return found


def publishing(f):
    """NOT publishing when it provably writes staging/ only, or is sign-gated and the caller's sign is the literal false"""
    if f["dest"] is not None and staging_literal(f["dest"]): return False
    if f["gated"]:
        if f.get("sign") == "false": return False
        if f["gated"] == SIGN_REAL and f.get("staging") == "true": return False
        if f["gated"] == SIGN_STAGING and f.get("staging") == "false": return False
    return True


def check_workflow(repo, path, doc, bad):
    rel = os.path.relpath(path, repo.root)
    on = doc.get(True, doc.get("on")) or {}
    if isinstance(on, dict) and "workflow_dispatch" in on:
        for i in ((on["workflow_dispatch"] or {}).get("inputs") or {}):
            if "publish" in i.lower():
                bad.append(f"{rel}: workflow_dispatch input '{i}' can switch publishing on by hand")
    for job, body in (doc.get("jobs") or {}).items():
        if "steps" not in body: continue
        pub = []
        for n, st in enumerate(body["steps"]):
            for f in repo.step_findings(st):
                if publishing(f): pub.append((st.get("name") or st.get("uses") or f"step {n + 1}", f["what"]))
        if pub and ("if" not in body or norm_if(body["if"]) != TAG):
            label, what = pub[0]
            bad.append(f"{rel}: job '{job}' publishes (step '{label}': {what}) but its job-level `if` is not exactly: {TAG}")


def scan(root):
    repo = Repo(root)
    bad = []
    wd = os.path.join(root, ".github", "workflows")
    for fn in sorted(os.listdir(wd)) if os.path.isdir(wd) else []:
        if fn.endswith((".yml", ".yaml")):
            p = os.path.join(wd, fn)
            check_workflow(repo, p, yaml.safe_load(open(p)), bad)
    return bad


# ---- the plants: every way of publishing the gate must see, and the shapes it must let through
def plant(files, real=None):
    d = tempfile.mkdtemp()
    if real:
        shutil.copytree(os.path.join(real, ".github", "actions"), os.path.join(d, ".github", "actions"))
    for rel, text in files.items():
        p = os.path.join(d, ".github", rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    return d


def wf(job_if="", step_if="", run="gh release upload v1 x.rpm", on="push:\n    tags: ['v*']\n  workflow_dispatch: {}", job_name="J"):
    return (f"name: w\non:\n  {on}\njobs:\n  j:\n    name: {job_name}\n    runs-on: ubuntu-latest\n"
            + (f"    if: {job_if}\n" if job_if else "")
            + "    steps:\n      - name: s\n" + (f"        if: {step_if}\n" if step_if else "")
            + "        run: |\n          " + run + "\n")


def call(uses, with_="", job_if=""):
    return ("name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n" + (f"    if: {job_if}\n" if job_if else "")
            + f"    steps:\n      - uses: {uses}\n" + (f"        with:\n{with_}" if with_ else ""))


PUB_ACTION = ("name: pub\ninputs:\n  sign:\n    default: 'false'\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n"
              "    - id: s\n      if: inputs.sign == 'true' && inputs.staging == 'true'\n      uses: ./.github/actions/channel-push\n      with:\n        what: staging/rpm\n"
              "    - id: r\n      if: inputs.sign == 'true' && inputs.staging != 'true'\n      uses: ./.github/actions/channel-push\n      with:\n        what: %s\n")
HELPER = "name: channel-push\ninputs:\n  what:\n    required: true\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: git push origin HEAD\n"
CP = "./.github/actions/channel-push"


def selftest(real):
    T = TAG
    helper = {"actions/channel-push/action.yml": HELPER}
    pub = dict(helper, **{"actions/pub/action.yml": PUB_ACTION % "rpm"})
    P = "./.github/actions/pub"
    reds = {
        "gh release upload, no condition": {"workflows/a.yml": wf()},
        "npm publish, no condition": {"workflows/a.yml": wf(run="npm publish --provenance")},
        "aws s3 sync, no condition": {"workflows/a.yml": wf(run="aws s3 sync out s3://b")},
        "rsync, no condition": {"workflows/a.yml": wf(run="rsync -a out host:/srv")},
        "rclone, no condition": {"workflows/a.yml": wf(run="rclone sync out remote:b")},
        "git push, no condition": {"workflows/a.yml": wf(run="git push origin HEAD:main")},
        "git push on a continued line": {"workflows/a.yml": wf(run="git -c a=b \\\n            push origin main")},
        "gh api writing a release": {"workflows/a.yml": wf(run="gh api repos/o/r/releases -f tag_name=v1")},
        "curl -T upload": {"workflows/a.yml": wf(run="curl -sS -T x.rpm https://host/up/")},
        "curl --upload-file": {"workflows/a.yml": wf(run="curl --upload-file x.rpm https://host/up/")},
        "curl POST to an uploads API": {"workflows/a.yml": wf(run="curl -X POST --data-binary @x https://uploads.github.com/repos/o/r/releases/1/assets")},
        "curl PUT to a releases API on a continued line": {"workflows/a.yml": wf(run="curl -sS \\\n            -X PUT -d @b https://api.github.com/repos/o/r/releases/1")},
        "job if: always() || TAG": {"workflows/a.yml": wf(job_if="${{ always() || (" + T + ") }}")},
        "job if: x || TAG": {"workflows/a.yml": wf(job_if="${{ inputs.go || (" + T + ") }}")},
        "job if: TAG && more": {"workflows/a.yml": wf(job_if="${{ (" + T + ") && inputs.x }}")},
        "TAG only on the step, not the job": {"workflows/a.yml": wf(step_if="${{ " + T + " }}")},
        "TAG only in the job name": {"workflows/a.yml": wf(job_name='"' + T + '"')},
        "job if: workflow_dispatch": {"workflows/a.yml": wf(job_if="github.event_name == 'workflow_dispatch'")},
        "a .yaml workflow": {"workflows/a.yaml": wf()},
        "a dispatch input named publish": {"workflows/a.yml": wf(run="echo hi", on="workflow_dispatch:\n    inputs:\n      publish:\n        type: boolean")},
        "a composite action that pushes, called bare": {
            "actions/p2/action.yml": "name: p2\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: git push origin HEAD\n",
            "workflows/a.yml": call("./.github/actions/p2")},
        "a composite action with a script that pushes": {
            "actions/p3/action.yml": "name: p3\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: ${{ github.action_path }}/go.sh\n",
            "actions/p3/go.sh": "#!/bin/bash\ngit push origin HEAD\n", "workflows/a.yml": call("./.github/actions/p3")},
        "a second unguarded publish in the same action": {
            "actions/p4/action.yml": "name: p4\ninputs:\n  sign:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: gh release create v1\n    - shell: bash\n      run: gh release upload v1 x\n",
            "workflows/a.yml": call("./.github/actions/p4", "          sign: 'false'\n")},
        "dispatch: sign true, staging the string false": dict(pub, **{"workflows/a.yml": call(P, "          sign: 'true'\n          staging: 'false'\n")}),
        "dispatch: sign and staging both expressions": dict(pub, **{"workflows/a.yml": call(P, "          sign: ${{ inputs.staged }}\n          staging: ${{ inputs.staged }}\n")}),
        "dispatch: staging literal true, but the action pushes the real tree whatever staging says": dict(helper, **{
            "actions/pub2/action.yml": "name: pub2\ninputs:\n  sign:\n    default: 'false'\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      uses: ./.github/actions/channel-push\n      with:\n        what: rpm\n",
            "workflows/a.yml": call("./.github/actions/pub2", "          sign: ${{ env.DO }}\n          staging: 'true'\n")}),
        "dispatch: staging literal true, sign an expression, the real step ungated": dict(helper, **{
            "actions/pub3/action.yml": "name: pub3\ninputs:\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - uses: ./.github/actions/channel-push\n      with:\n        what: rpm\n",
            "workflows/a.yml": call("./.github/actions/pub3", "          staging: 'true'\n")}),
        "a push whose what is staging/../rpm": dict(helper, **{"workflows/a.yml": call(CP, "          what: staging/../rpm\n")}),
        "a push whose what is staging//rpm": dict(helper, **{"workflows/a.yml": call(CP, "          what: staging//rpm\n")}),
        "a push whose what is an expression starting with staging/": dict(helper, **{"workflows/a.yml": call(CP, "          what: staging/${{ inputs.k }}\n")}),
        "a push whose what is the real tree": dict(helper, **{"workflows/a.yml": call(CP, "          what: rpm\n")}),
    }
    greens = {
        "job if: exactly TAG": {"workflows/a.yml": wf(job_if="${{ " + T + " }}")},
        "job if: exactly TAG, respaced and unwrapped": {"workflows/a.yml": wf(job_if="github.event_name  ==  'push'   &&   startsWith(github.ref, 'refs/tags/')")},
        "a dispatch run that only builds": {"workflows/a.yml": wf(run="make")},
        "a sign-gated action given a literal sign false": dict(pub, **{"workflows/a.yml": call(P, "          sign: 'false'\n")}),
        "a sign-gated action given no sign (default false)": dict(pub, **{"workflows/a.yml": call(P)}),
        "the stage call: staging literal true, sign true, from a dispatch job": dict(pub, **{"workflows/a.yml": call(P, "          sign: 'true'\n          staging: 'true'\n")}),
        "a sign-gated action given sign true in a tag job": dict(pub, **{"workflows/a.yml": call(P, "          sign: 'true'\n", job_if="${{ " + T + " }}")}),
        "a push of a literal staging path": dict(helper, **{"workflows/a.yml": call(CP, "          what: staging/rpm\n")}),
        "a dry-run npm publish": {"workflows/a.yml": wf(run="npm publish --dry-run")},
    }
    realplants = {"reds": {
        "the real publish-rpms from a dispatch job, sign true": call("./.github/actions/publish-rpms", "          sign: 'true'\n          rpm-dir: x\n"),
        "the real publish-rpms from a dispatch job, sign an expression": call("./.github/actions/publish-rpms", "          sign: ${{ inputs.go }}\n          rpm-dir: x\n"),
        "the real publish-debs from a dispatch job, sign true": call("./.github/actions/publish-debs", "          sign: 'true'\n          deb-dir: x\n"),
        "the real purge-staging is fine but the real channel-push on the real tree is not": call(CP, "          what: deb\n"),
    }, "greens": {
        "the real publish-rpms with a literal sign false": call("./.github/actions/publish-rpms", "          sign: 'false'\n          rpm-dir: x\n"),
        "the real publish-debs with no sign": call("./.github/actions/publish-debs", "          deb-dir: x\n"),
        "the real publish-rpms with sign true in a tag job": call("./.github/actions/publish-rpms", "          sign: 'true'\n          rpm-dir: x\n", job_if="${{ " + T + " }}"),
        "the real purge-staging from a dispatch job": call("./.github/actions/purge-staging", "          kind: rpm\n          sign: 'true'\n"),
    }} if real else {"reds": {}, "greens": {}}
    ok = True
    for name, files in reds.items():
        if scan(plant(files)): print(f"ok   plant is red: {name}")
        else: print(f"FAIL plant passed: {name}"); ok = False
    for name, files in greens.items():
        bad = scan(plant(files))
        if not bad: print(f"ok   control is green: {name}")
        else: print(f"FAIL control is red: {name}: {bad}"); ok = False
    for name, text in realplants["reds"].items():
        if scan(plant({"workflows/a.yml": text}, real)): print(f"ok   plant is red: {name}")
        else: print(f"FAIL plant passed: {name}"); ok = False
    for name, text in realplants["greens"].items():
        bad = scan(plant({"workflows/a.yml": text}, real))
        if not bad: print(f"ok   control is green: {name}")
        else: print(f"FAIL control is red: {name}: {bad}"); ok = False
    return ok


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        sys.exit(0 if selftest(sys.argv[2] if len(sys.argv) > 2 else None) else 1)
    bad = scan(sys.argv[1])
    for b in bad: print("FAIL " + b)
    if bad: sys.exit(1)
    print("ok   every publishing job has the exact tag condition; no dispatch input publishes")
