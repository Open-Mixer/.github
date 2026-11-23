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
# A push to the TRIGGERING pull request's own head branch is not a publish (no tag, release, package or channel; ruling of the
# coordinator, Open-Mixer/.github#177, the language-pack fill): every publishing thing in the job is such a push AND the
# job-level `if` is exactly PR_JOB, so the job never runs on a push, a tag, a dispatch or a fork's pull request.
PR_JOB = "github.event_name == 'pull_request' && !github.event.pull_request.head.repo.fork"
# The dispatch form (callers' ci.yml is workflow_dispatch only): the same push, from a dispatched run on the head branch of one
# OPEN same-repository pull request, which a step before the push must have proved (PR_CHECK: it reads the open pull
# requests of that head, `pulls?head=` with `state=open`, and fails by name when there is not exactly one).
PR_OR_DISPATCH = PR_JOB + " || github.event_name == 'workflow_dispatch'"
PR_CHECK = ("pulls?head=", "state=open")
PR_REF_RUN = re.compile(r"HEAD:(?:refs/heads/)?(?:\$\{\{\s*github\.ref_name\s*\}\}|\$GITHUB_REF_NAME|\$\{GITHUB_REF_NAME\})(?=[\s\"']|$)")
PR_HEAD_RUN = re.compile(r"HEAD:(?:refs/heads/)?(?:\$\{\{\s*github\.head_ref\s*\}\}|\$GITHUB_HEAD_REF|\$\{GITHUB_HEAD_REF\})(?=[\s\"']|$)")
PR_HEAD_PY = re.compile(r"\"HEAD:refs/heads/%s\"\s*%\s*ref\b")
PR_HEAD_PY_REF = re.compile(r"^\s*ref\s*=\s*(?:env|os\.environ)\[\"GITHUB_HEAD_REF\"\]\s*$", re.M)
PUSH_LINE = re.compile(r"\bgit\b[^\n]*\bpush\b")
PUSH_WIDENED = re.compile(r"--tags|--force|--mirror|--delete|--follow-tags|--all\b|\s-[fd]\b|refs/tags/|:refs/(?!heads/)|(?:^|[\s\"'])\+\S*:")

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


def pr_head_only(text, py=False):
    """'pr' when `text` pushes only to the triggering pull request's own head branch (and the script reads it from
    GITHUB_HEAD_REF), 'dispatch' when some push is to the dispatched run's ref name, None otherwise"""
    lines = [l for l in text.splitlines() if PUSH_LINE.search(l)]
    if not lines or any(PUSH_WIDENED.search(l) for l in lines): return None
    if py:
        return "pr" if PR_HEAD_PY_REF.search(text) and all(PR_HEAD_PY.search(l) for l in lines) else None
    if not all(PR_HEAD_RUN.search(l) or PR_REF_RUN.search(l) for l in lines): return None
    return "dispatch" if any(PR_REF_RUN.search(l) for l in lines) else "pr"


def only_git_push(text):
    """every kind of publishing the text does is a git push (the whole text is read, not the first match)"""
    for rx, what in RUN_PUBLISHES:
        if what != "git push" and rx.search(text): return False
    return not any(re.match(r"\s*curl\b", l) and run_publishes(l) for l in text.splitlines())


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
            prhead = (what == "git push" and only_git_push(txt) and pr_head_only(txt, py=fn.endswith(".py"))) or None
            for st in [x for x in steps if fn in str(x.get("run", ""))] or [{}]:
                out.append({"what": what + " in " + fn, "dest": None, "prhead": prhead, "gated": norm_if(st["if"]) if "if" in st and norm_if(st["if"]) in SIGN_GATES else None})
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
                    found.append({"what": f"{f['what']} (through {name})", "dest": dest, "gated": f["gated"], "sign": sign, "staging": staging, "prhead": f.get("prhead")})
                if name == PUSH_HELPER and not inner:
                    found.append({"what": "the push helper", "dest": w.get("what"), "gated": None, "sign": sign, "staging": None})
            elif USES_PUBLISHES.search(uses):
                found.append({"what": f"the action {uses}", "dest": None, "gated": None, "sign": None, "staging": None})
        if "run" in st:
            what = run_publishes(run_text(st))
            if what:
                rt = run_text(st)
                found.append({"what": what, "dest": None, "gated": None, "sign": None, "staging": None,
                              "prhead": (what == "git push" and only_git_push(rt) and pr_head_only(rt)) or None})
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
        jif = norm_if(body["if"]) if "if" in body else None
        check = next((i for i, x in enumerate(body["steps"]) if all(m in run_text(x) for m in PR_CHECK)), None)
        for n, st in enumerate(body["steps"]):
            for f in repo.step_findings(st):
                kind = f.get("prhead")
                if kind and "if" not in st:
                    if jif == PR_JOB and kind == "pr": continue
                    if jif == PR_OR_DISPATCH and check is not None and check < n: continue
                # the dispatch form may SKIP on a kept ref: a step `if` that is exactly the check step's own kept != 'true'
                # only narrows where the push runs (never widens it); any other step `if` stays refused
                if kind and "if" in st and jif == PR_OR_DISPATCH and check is not None and check < n:
                    cid = body["steps"][check].get("id")
                    if cid and norm_if(st["if"]) == f"steps.{cid}.outputs.kept != 'true'": continue
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
    PRON = "pull_request: {}"
    PRJ = "${{ " + PR_JOB + " }}"
    head = "git push origin HEAD:${{ github.head_ref }}"
    pyact = ('name: pyfill\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: python3 ${{ github.action_path }}/f.py\n')
    pyok = 'import os\nenv = os.environ\nref = env["GITHUB_HEAD_REF"]\ngit("push", "-q", "origin", "HEAD:refs/heads/%s" % ref)\n'
    pybad = pyok + 'git("push", "-q", "origin", "HEAD:refs/heads/main")\n'
    pyrel = pyok + 'os.system("gh release create v1")\n'
    reds.update({
        "pr-head push, job with no if": {"workflows/a.yml": wf(run=head, on=PRON)},
        "pr-head push, job if only pull_request (a fork is not excluded)": {"workflows/a.yml": wf(run=head, on=PRON, job_if="github.event_name == 'pull_request'")},
        "pr-head push, job if also true on push": {"workflows/a.yml": wf(run=head, on=PRON, job_if="${{ " + PR_JOB + " || github.event_name == 'push' }}")},
        "pr-head push, a job that runs on push": {"workflows/a.yml": wf(run=head, on="push: {}", job_if="github.event_name == 'push'")},
        "pr-head push, a step if instead of the job if": {"workflows/a.yml": wf(run=head, on=PRON, step_if=PRJ)},
        "push to main in the pr job": {"workflows/a.yml": wf(run="git push origin HEAD:main", on=PRON, job_if=PRJ)},
        "push to a fixed branch name in the pr job": {"workflows/a.yml": wf(run="git push origin HEAD:refs/heads/fill", on=PRON, job_if=PRJ)},
        "push of HEAD to its own name in the pr job": {"workflows/a.yml": wf(run="git push origin HEAD", on=PRON, job_if=PRJ)},
        "push of a tag in the pr job": {"workflows/a.yml": wf(run="git push origin v1.2.3", on=PRON, job_if=PRJ)},
        "push of a tag ref in the pr job": {"workflows/a.yml": wf(run="git push origin HEAD:refs/tags/v1", on=PRON, job_if=PRJ)},
        "pr-head push with --tags": {"workflows/a.yml": wf(run=head + " --tags", on=PRON, job_if=PRJ)},
        "pr-head push with --force": {"workflows/a.yml": wf(run=head + " --force", on=PRON, job_if=PRJ)},
        "pr-head push followed by a push to main": {"workflows/a.yml": wf(run=head + "\n          git push origin HEAD:main", on=PRON, job_if=PRJ)},
        "pr-head push beside a release creation, same step": {"workflows/a.yml": wf(run=head + "\n          gh release create v1", on=PRON, job_if=PRJ)},
        "pr-head push beside a package publish, same job": {"workflows/a.yml": wf(run=head + "\n          npm publish", on=PRON, job_if=PRJ)},
        "an action script pushing to the pr head and to main": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pybad, "workflows/a.yml": call("./.github/actions/pyfill", job_if=PRJ)},
        "an action script pushing to the pr head and releasing": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pyrel, "workflows/a.yml": call("./.github/actions/pyfill", job_if=PRJ)},
        "the pr-head action script in a job with no if": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pyok, "workflows/a.yml": call("./.github/actions/pyfill")},
        "the pr-head action script whose ref is not read from GITHUB_HEAD_REF": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pyok.replace('env["GITHUB_HEAD_REF"]', '"main"'), "workflows/a.yml": call("./.github/actions/pyfill", job_if=PRJ)},
        "a pr-head push job that also calls the channel push on the real tree": dict(helper, **{"workflows/a.yml": ("name: w\non:\n  pull_request: {}\njobs:\n  j:\n    runs-on: x\n    if: " + PR_JOB + "\n    steps:\n      - run: " + head + "\n      - uses: " + CP + "\n        with:\n          what: rpm\n")}),
    })
    DISP = "${{ " + PR_OR_DISPATCH + " }}"
    chk = ("      - name: c\n        run: |\n          curl \"$GITHUB_API_URL/repos/$R/pulls?head=$O:$GITHUB_REF_NAME&state=open\"\n")
    def dwf(push, check=True, job_if=DISP, on="workflow_dispatch: {}\n  pull_request: {}", pre="", step_if="", cid=""):
        return ("name: w\non:\n  " + on + "\njobs:\n  j:\n    runs-on: x\n    if: " + job_if + "\n    steps:\n" + pre
                + ((chk.replace("      - name: c\n", "      - name: c\n        id: " + cid + "\n") if cid else chk) if check else "") + "      - name: p\n" + (f"        if: {step_if}\n" if step_if else "") + "        run: |\n          " + push + "\n")
    dref = "git push origin HEAD:${{ github.ref_name }}"
    reds.update({
        "a force push by refspec to the pr head": {"workflows/a.yml": wf(run="git push origin +HEAD:${{ github.head_ref }}", on=PRON, job_if=PRJ)},
        "a force push by refspec to the dispatch ref": {"workflows/a.yml": dwf("git push origin +HEAD:$GITHUB_REF_NAME")},
        "a force push by quoted refspec": {"workflows/a.yml": wf(run='git push origin "+HEAD:$GITHUB_HEAD_REF"', on=PRON, job_if=PRJ)},
        "dispatch fill without the open-pr check": {"workflows/a.yml": dwf(dref, check=False)},
        "dispatch push to main": {"workflows/a.yml": dwf("git push origin HEAD:main")},
        "dispatch push to a release branch": {"workflows/a.yml": dwf("git push origin HEAD:refs/heads/release/1.2")},
        "dispatch push of a tag": {"workflows/a.yml": dwf("git push origin HEAD:refs/tags/v1")},
        "dispatch push of a tag by name": {"workflows/a.yml": dwf("git push origin v1")},
        "dispatch push, the check step after the push": {"workflows/a.yml": dwf(dref, check=False).replace("        run: |\n          " + dref + "\n", "        run: |\n          " + dref + "\n") + chk},
        "dispatch push in a job that also runs on push": {"workflows/a.yml": dwf(dref, job_if="${{ " + PR_OR_DISPATCH + " || github.event_name == 'push' }}", on="push: {}\n  workflow_dispatch: {}")},
        "dispatch push in a job whose if is only workflow_dispatch": {"workflows/a.yml": dwf(dref, job_if="github.event_name == 'workflow_dispatch'")},
        "the ref_name push in a pull-request-only job": {"workflows/a.yml": wf(run=dref, on=PRON, job_if=PRJ)},
        "dispatch push beside a release creation": {"workflows/a.yml": dwf(dref + "\n          gh release create v1")},
        "dispatch check with a step if on the push": {"workflows/a.yml": dwf(dref, step_if="always()")},
        "a kept-skip step if naming a step that is not the check": {"workflows/a.yml": dwf(dref, cid="pr", step_if="steps.other.outputs.kept != 'true'")},
        "a kept-skip step if with the check carrying no id": {"workflows/a.yml": dwf(dref, step_if="steps.pr.outputs.kept != 'true'")},
        "the inverted kept step if (push only ON a kept ref)": {"workflows/a.yml": dwf(dref, cid="pr", step_if="steps.pr.outputs.kept == 'true'")},
        "a kept-skip step if widened with or always": {"workflows/a.yml": dwf(dref, cid="pr", step_if="steps.pr.outputs.kept != 'true' || always()")},
        "a kept-skip step if in the pull-request-only job": {"workflows/a.yml": wf(run=head, on=PRON, job_if=PRJ, step_if="steps.pr.outputs.kept != 'true'")},
    })
    greens.update({
        "a dispatched fill pushing to its ref name after the open-pr check": {"workflows/a.yml": dwf(dref)},
        "a dispatched fill skipped on a kept ref (step if is the check's kept != 'true')": {"workflows/a.yml": dwf(dref, cid="pr", step_if="steps.pr.outputs.kept != 'true'")},
        "the same with the env var": {"workflows/a.yml": dwf('git push origin "HEAD:refs/heads/$GITHUB_REF_NAME"')},
        "an action script pushing to the pr head, dispatch job with the check": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pyok,
            "workflows/a.yml": ("name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    if: " + DISP + "\n    steps:\n" + chk + "      - uses: ./.github/actions/pyfill\n")},
    })
    greens.update({
        "a push to the pull request's own head branch, same-repo pr job": {"workflows/a.yml": wf(run=head, on=PRON, job_if=PRJ)},
        "the same, refs/heads/ and the env var": {"workflows/a.yml": wf(run='git push origin "HEAD:refs/heads/$GITHUB_HEAD_REF"', on=PRON, job_if=PRJ)},
        "an action script pushing only to the pr head, same-repo pr job": {"actions/pyfill/action.yml": pyact, "actions/pyfill/f.py": pyok, "workflows/a.yml": call("./.github/actions/pyfill", job_if=PRJ)},
    })
    realplants = {"reds": {
        "the real publish-rpms from a dispatch job, sign true": call("./.github/actions/publish-rpms", "          sign: 'true'\n          rpm-dir: x\n"),
        "the real publish-rpms from a dispatch job, sign an expression": call("./.github/actions/publish-rpms", "          sign: ${{ inputs.go }}\n          rpm-dir: x\n"),
        "the real publish-debs from a dispatch job, sign true": call("./.github/actions/publish-debs", "          sign: 'true'\n          deb-dir: x\n"),
        "the real purge-staging is fine but the real channel-push on the real tree is not": call(CP, "          what: deb\n"),
        "the real langpacks fill in a dispatch job with no open-pr check": call("./.github/actions/langpacks", "          name: x\n          owner: x\n", job_if="${{ " + PR_OR_DISPATCH + " }}"),
        "the real langpacks fill in a job with no if": call("./.github/actions/langpacks", "          name: x\n          owner: x\n"),
        "the real langpacks fill in a job that is true on push": call("./.github/actions/langpacks", "          name: x\n          owner: x\n", job_if="${{ " + PR_JOB + " || github.event_name == 'push' }}"),
    }, "greens": {
        "the real langpacks fill in a same-repo pull request job": call("./.github/actions/langpacks", "          name: x\n          owner: x\n", job_if="${{ " + PR_JOB + " }}"),
        "the real langpacks fill in a dispatch job after the open-pr check": ("name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    if: " + "${{ " + PR_OR_DISPATCH + " }}" + "\n    steps:\n" + chk + "      - uses: ./.github/actions/langpacks\n        with:\n          name: x\n          owner: x\n"),
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
