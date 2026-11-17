# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Publish only by tagging (docs/release-operations.md).

A step PUBLISHES by what it does: `gh release create|upload`, `npm publish`, an rsync/rclone/s3 copy, any
`git push`, a `gh api` write to refs, releases, contents or dispatches, a `curl` upload (-T, --upload-file) or a curl write to a
releases or uploads API, a third-party release/pages action, or a local
composite action that contains one of these (the channel push helper is one). Names are not read: a workflow named
anything publishes if its steps do.

Every publishing step must be GUARDED: the conjunction of its job `if`, its step `if`, and (for a composite action)
the action's own `if` with `inputs.X` replaced by what the caller passes, must be false whenever the tag condition is
false, for EVERY value of the other conditions. So `x || TAG`, `always() || TAG`, a TAG that is only in a job name or a
comment, and a `sign: true` are all refused. The only exemption is by what the push WRITES, never by an input name: a
push whose written path (the `what` of the channel push helper, followed through the actions that call it) is under
staging/ in every case it can run outside a tag push. That is the stage builds (they feed the next layer; they are not
the release channel consumers install from) and the purge of staging. An action that is handed `staging: ...` and
writes elsewhere is refused. LIMIT: a script of the repository (not of an action directory) that itself does the
`git push` or the upload is invisible to this gate.
A workflow a person can start by hand takes no input named like a publish switch. Workflows and composite actions,
.yml and .yaml, are all read. Usage: publish_only_by_tag.py <repo root> | --selftest
"""
import itertools, json, os, re, sys, tempfile
import yaml

TAG = "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
PUSH_HELPER = "channel-push"                   # the one helper that pushes to the channel; its `what` input names the path
STAGING = "staging/"                           # what a stage build, and the purge of staging, write: nothing else is exempt

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


def run_publishes(t):
    """what a run script does that publishes, or None. t has its continuation lines joined and comments dropped"""
    for rx, what in RUN_PUBLISHES:
        for m in rx.finditer(t):
            line_end = t.find("\n", m.end())
            if what == "npm publish" and "--dry-run" in t[m.start():line_end if line_end >= 0 else None]: continue
            return what
    for line in t.splitlines():
        if re.search(r"\bcurl\b", line):
            if CURL_UPLOAD.search(line): return "a curl upload"
            if CURL_WRITE.search(line) and CURL_TARGET.search(line): return "a curl write to a releases or uploads API"
    return None


USES_PUBLISHES = re.compile(r"gh-release|pypi-publish|deploy-pages|gh-pages|pages-deploy|upload-release-asset|create-release|action-gh-release")


# ---- a boolean expression, read just far enough to ask "is it false whenever TAG is false"
def tokens(s):
    i, out, n = 0, [], len(s)
    while i < n:
        c = s[i]
        if c.isspace(): i += 1
        elif s.startswith("&&", i): out.append("&&"); i += 2
        elif s.startswith("||", i): out.append("||"); i += 2
        elif c == "!" and not s.startswith("!=", i): out.append("!"); i += 1
        elif c == "(": out.append("("); i += 1
        elif c == ")": out.append(")"); i += 1
        else:
            j, depth, q = i, 0, None
            while j < n:
                d = s[j]
                if q:
                    if d == q: q = None
                elif d in "'\"": q = d
                elif d == "(": depth += 1
                elif d == ")":
                    if depth == 0: break
                    depth -= 1
                elif depth == 0 and (s.startswith("&&", j) or s.startswith("||", j)): break
                j += 1
            out.append(s[i:j].strip()); i = j
    return out


def parse(toks):
    pos = [0]
    def peek(): return toks[pos[0]] if pos[0] < len(toks) else None
    def take(): pos[0] += 1; return toks[pos[0] - 1]
    def p_or():
        a = p_and()
        while peek() == "||": take(); a = ("or", a, p_and())
        return a
    def p_and():
        a = p_not()
        while peek() == "&&": take(); a = ("and", a, p_not())
        return a
    def p_not():
        if peek() == "!": take(); return ("not", p_not())
        if peek() == "(":
            take(); a = p_or()
            if peek() == ")": take()
            return a
        return ("atom", take())
    a = p_or()
    return a


def atoms(ast, acc):
    if ast[0] == "atom": acc.add(ast[1])
    else:
        for x in ast[1:]: atoms(x, acc)
    return acc


def ev(ast, val):
    k = ast[0]
    if k == "atom":
        t = ast[1]
        if len(t) >= 2 and t[0] == "'" and t[-1] == "'": return t[1:-1]
        if t.lower() == "true": return True
        if t.lower() == "false": return False
        return val[t]
    if k == "not": return not ev(ast[1], val)
    if k == "and":
        a = ev(ast[1], val)
        return ev(ast[2], val) if a else a
    a = ev(ast[1], val)
    return a if a else ev(ast[2], val)


def strip_expr(v):
    v = str(v).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", v, re.S)
    return m.group(1).strip() if m else v


def canon(expr):
    """the expression with the tag condition (bare or parenthesised) as one atom, and `X == 'true'` as X"""
    e = strip_expr(expr)
    e = e.replace("(" + TAG + ")", "TAGATOM").replace(TAG, "TAGATOM")
    e = re.sub(r"\b((?:inputs|env)\.[\w-]+)\s*==\s*'true'", r"\1", e)
    e = re.sub(r"\b((?:inputs|env)\.[\w-]+)\s*!=\s*'true'", r"!\1", e)
    return e


def literal(v):
    """a with: value that is a plain string, not an expression"""
    v = str(v).strip()
    if "${{" in v: return None
    return v


def subst(expr, inputs, env, strings=False):
    """replace inputs.X by what the caller passed and env.X by the job's env, a few levels deep"""
    e = canon(expr)
    for _ in range(4):
        def one(kind, table):
            def f(m):
                name = m.group(1)
                if name not in table: return m.group(0)
                v = table[name]
                lit = literal(v)
                if lit is not None:
                    if strings: return "'" + lit + "'"
                    return "true" if lit.lower() == "true" else "false"
                return "(" + canon(v) + ")"
            return f
        n = re.sub(r"\binputs\.([\w-]+)", one("inputs", inputs), e)
        n = re.sub(r"\benv\.([\w-]+)", one("env", env), n)
        n = n.replace("(" + TAG + ")", "TAGATOM").replace(TAG, "TAGATOM")
        if n == e: break
        e = n
    return e


def dest_ast(dest):
    """where a push writes: ('expr', text) is an expression, ('lit', text) a string, possibly with ${{ }} after a prefix"""
    kind, text = dest
    if kind == "expr": return parse(tokens(text))
    return ("atom", "'" + text.split("${{")[0] + "'")


OTHER_EVENT = re.compile(r"github\.event_name\s*==\s*'(?!push')\w+'")


def judge(exprs, dest):
    """'ok' when, whenever the conjunction of exprs holds, it is a tag push or the push writes under staging/ only,
    and some such case exists; 'unguarded' when it can hold otherwise; 'never' when it can hold on no tag push"""
    exprs = [e for e in exprs if e is not None and str(e).strip() not in ("", "True")]
    asts = [parse(tokens(e)) for e in exprs]
    dast = dest_ast(dest) if dest else None
    ats = set()
    for a in asts + ([dast] if dast else []): atoms(a, ats)
    free = sorted(x for x in ats if x != "TAGATOM" and x.lower() not in ("true", "false") and not x.startswith("'"))
    if len(free) > 16: return "unguarded"
    reach = False
    for combo in itertools.product([False, True], repeat=len(free)):
        val = dict(zip(free, combo)); val["TAGATOM"] = False
        if all(ev(a, val) for a in asts):
            d = ev(dast, val) if dast else None
            if not (isinstance(d, str) and d.startswith(STAGING)): return "unguarded"
            reach = True
        val["TAGATOM"] = True
        for x in free:
            if OTHER_EVENT.fullmatch(x): val[x] = False
        if all(ev(a, val) for a in asts): reach = True
    return "ok" if reach else "never"


# ---- what a step does
def run_text(step):
    t = str(step.get("run", ""))
    t = re.sub(r"\\\n\s*", " ", t)
    return "\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#"))


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

    def defaults(self, name):
        inp = self.actions[name].get("inputs") or {}
        return {k: v["default"] for k, v in inp.items() if isinstance(v, dict) and v.get("default") is not None}

    def action_publishers(self, name, stack=()):
        """[(what, [guard exprs over this action's inputs], dest)] for EVERY publishing step inside a composite action,
        dest being where a push writes (('expr'|'lit', text) over the action's inputs) or None when it is not known"""
        if name in self.memo: return self.memo[name]
        if name in stack: return []
        act = self.actions[name]
        out = []
        steps = ((act.get("runs") or {}).get("steps")) or []
        for st in steps:
            out += self.step_publishers(st, [], {}, stack + (name,))
        # a script of the action directory that publishes, run by a step: that step's own `if` guards it
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
            users = [st for st in steps if fn in str(st.get("run", ""))]
            for st in users or [{}]:
                out.append((what + " in " + fn, ([st["if"]] if "if" in st else []), None))
        self.memo[name] = out
        return out

    def step_publishers(self, st, base_guards, env, stack):
        """publishing findings of one step: [(what, [guard exprs], dest)] with the step's own `if` included"""
        found = []
        guards = base_guards + ([st["if"]] if "if" in st else [])
        uses = str(st.get("uses", ""))
        if uses:
            name = self.local(uses)
            if name:
                with_ = self.defaults(name); with_.update(st.get("with") or {})
                for what, inner, dest in self.action_publishers(name, stack):
                    sub = [subst(g, with_, {}) for g in inner]
                    if name == PUSH_HELPER and "what" in with_: dest = self.dest_of(with_["what"])
                    elif dest is not None: dest = self.lift_dest(dest, with_)
                    found.append((f"{what} (through {name})", guards + sub, dest))
            elif USES_PUBLISHES.search(uses):
                found.append((f"the action {uses}", guards, None))
        if "run" in st:
            what = run_publishes(run_text(st))
            if what: found.append((what, guards, None))
        return found

    @staticmethod
    def dest_of(v):
        """the written path a with: value names"""
        v = str(v).strip()
        return ("expr", canon(v)) if re.fullmatch(r"\$\{\{.*\}\}", v, re.S) else ("lit", v)

    @staticmethod
    def lift_dest(dest, with_):
        kind, text = dest
        return ("expr", subst(text, with_, {}, strings=True)) if kind == "expr" else dest


def check_workflow(repo, path, doc, bad):
    rel = os.path.relpath(path, repo.root)
    on = doc.get(True, doc.get("on")) or {}
    if isinstance(on, dict) and "workflow_dispatch" in on:
        for i in ((on["workflow_dispatch"] or {}).get("inputs") or {}):
            if "publish" in i.lower():
                bad.append(f"{rel}: workflow_dispatch input '{i}' can switch publishing on by hand")
    wf_env = doc.get("env") or {}
    for job, body in (doc.get("jobs") or {}).items():
        if "steps" not in body: continue
        env = dict(wf_env); env.update(body.get("env") or {})
        base = [body["if"]] if "if" in body else []
        for n, st in enumerate(body["steps"]):
            for what, gs, dest in repo.step_publishers(st, base, env, ()):
                exprs = [subst(g, {}, env) for g in gs]
                if dest and dest[0] == "expr": dest = ("expr", subst(dest[1], {}, env, strings=True))
                label = st.get("name") or st.get("uses") or f"step {n + 1}"
                r = judge(exprs, dest)
                if r == "unguarded":
                    bad.append(f"{rel}: job '{job}' step '{label}' publishes ({what}) without the tag condition ({TAG}), and does not write under {STAGING} only")
                elif r == "never":
                    bad.append(f"{rel}: job '{job}' step '{label}' ({what}) can never publish: its conditions exclude a tag push")


def scan(root):
    repo = Repo(root)
    bad = []
    wd = os.path.join(root, ".github", "workflows")
    for fn in sorted(os.listdir(wd)) if os.path.isdir(wd) else []:
        if fn.endswith((".yml", ".yaml")):
            p = os.path.join(wd, fn)
            check_workflow(repo, p, yaml.safe_load(open(p)), bad)
    return bad


# ---- the plants: a tree that publishes in every way this gate must see, and the ones it must let through
def plant(files):
    d = tempfile.mkdtemp()
    for rel, text in files.items():
        p = os.path.join(d, ".github", rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    return d


def wf(job_if="", step_if="", run="gh release upload v1 x.rpm", on="push:\n    tags: ['v*']\n  workflow_dispatch: {}", job_name="J", env=""):
    return (f"name: w\non:\n  {on}\njobs:\n  j:\n    name: {job_name}\n    runs-on: ubuntu-latest\n"
            + (f"    if: {job_if}\n" if job_if else "") + (f"    env:\n      {env}\n" if env else "")
            + "    steps:\n      - name: s\n" + (f"        if: {step_if}\n" if step_if else "")
            + "        run: |\n          " + run + "\n")


def selftest():
    T = TAG
    reds = {
        "gh release upload, no condition": {"workflows/a.yml": wf()},
        "npm publish, no condition": {"workflows/a.yml": wf(run="npm publish --provenance")},
        "aws s3 sync, no condition": {"workflows/a.yml": wf(run="aws s3 sync out s3://b")},
        "rsync, no condition": {"workflows/a.yml": wf(run="rsync -a out host:/srv")},
        "rclone, no condition": {"workflows/a.yml": wf(run="rclone sync out remote:b")},
        "git push, no condition": {"workflows/a.yml": wf(run="git push origin HEAD:main")},
        "git push on a continued line": {"workflows/a.yml": wf(run="git -c a=b \\\n            push origin main")},
        "gh api writing a release": {"workflows/a.yml": wf(run='gh api repos/o/r/releases -f tag_name=v1')},
        "job if: always() || TAG": {"workflows/a.yml": wf(job_if="${{ always() || (" + T + ") }}")},
        "step if: x || TAG": {"workflows/a.yml": wf(step_if="${{ inputs.go || (" + T + ") }}")},
        "TAG only in the job name": {"workflows/a.yml": wf(job_name='"' + T + '"')},
        "job if: workflow_dispatch": {"workflows/a.yml": wf(job_if="github.event_name == 'workflow_dispatch'")},
        "a .yaml workflow": {"workflows/a.yaml": wf()},
        "a publish job whose own if wants workflow_dispatch, so it can never publish": {"workflows/a.yml": wf(job_if="${{ github.event_name == 'workflow_dispatch' }}", step_if="${{ " + T + " }}")},
        "a stage build whose push writes outside staging/": {
            "actions/channel-push/action.yml": "name: channel-push\ninputs:\n  what:\n    required: true\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: git push origin HEAD\n",
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      uses: ./.github/actions/channel-push\n      with:\n        what: rpm\n",
            "workflows/a.yml": "name: w\non:\n  workflow_call:\n    inputs:\n      staged:\n        type: boolean\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: ${{ inputs.staged }}\n          staging: ${{ inputs.staged }}\n"},
        "curl -T upload": {"workflows/a.yml": wf(run="curl -sS -T x.rpm https://host/up/")},
        "curl --upload-file": {"workflows/a.yml": wf(run="curl --upload-file x.rpm https://host/up/")},
        "curl POST to a releases uploads API": {"workflows/a.yml": wf(run="curl -X POST -H 'Auth: t' --data-binary @x https://uploads.github.com/repos/o/r/releases/1/assets")},
        "curl PUT to a releases API on a continued line": {"workflows/a.yml": wf(run="curl -sS \\\n            -X PUT -d @b https://api.github.com/repos/o/r/releases/1")},
        "a second unguarded publish in the same action": {
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: gh release create v1\n    - shell: bash\n      run: gh release upload v1 x\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: ${{ " + T + " }}\n"},
        "a guarded publish step and an unguarded script in the same action": {
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: gh release create v1\n    - shell: bash\n      run: ${{ github.action_path }}/go.sh\n",
            "actions/pub/go.sh": "#!/bin/bash\ngit push origin HEAD\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: ${{ " + T + " }}\n"},
        "a dispatch input named publish": {"workflows/a.yml": wf(run="echo hi", on="workflow_dispatch:\n    inputs:\n      publish:\n        type: boolean")},
        "env DO_PUBLISH without the tag": {"workflows/a.yml": wf(step_if="env.DO_PUBLISH == 'true'", env="DO_PUBLISH: ${{ github.ref == 'refs/heads/main' }}")},
        "a composite action that pushes, called bare": {
            "actions/pub/action.yml": "name: pub\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: git push origin HEAD\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n"},
        "a composite action passed sign: true": {
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: gh release create v1\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: true\n"},
        "a script of an action that pushes": {
            "actions/pub/action.yml": "name: pub\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: ${{ github.action_path }}/go.sh\n",
            "actions/pub/go.sh": "#!/bin/bash\ngit push origin HEAD\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n"},
    }
    greens = {
        "job if: TAG": {"workflows/a.yml": wf(job_if="${{ " + T + " }}")},
        "step if: TAG && more": {"workflows/a.yml": wf(step_if="${{ inputs.x && (" + T + ") }}")},
        "env DO_PUBLISH with the tag": {"workflows/a.yml": wf(step_if="env.DO_PUBLISH == 'true'", env="DO_PUBLISH: ${{ inputs.publish && (" + T + ") }}")},
        "a dispatch run that only builds": {"workflows/a.yml": wf(run="make")},
        "a composite action guarded through its input": {
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: gh release create v1\n",
            "workflows/a.yml": "name: w\non:\n  workflow_dispatch: {}\njobs:\n  j:\n    runs-on: x\n    env:\n      DO: ${{ " + T + " }}\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: ${{ env.DO }}\n"},
        "a staged build writing under staging/ only": {
            "actions/channel-push/action.yml": "name: channel-push\ninputs:\n  what:\n    required: true\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: git push origin HEAD\n",
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      uses: ./.github/actions/channel-push\n      with:\n        what: ${{ inputs.staging == \'true\' && \'staging/rpm\' || \'rpm\' }}\n",
            "workflows/a.yml": "name: w\non:\n  workflow_call:\n    inputs:\n      staged:\n        type: boolean\njobs:\n  j:\n    runs-on: x\n    steps:\n      - uses: ./.github/actions/pub\n        with:\n          sign: ${{ inputs.staged }}\n          staging: ${{ inputs.staged }}\n"},
    }
    ok = True
    for name, files in reds.items():
        bad = scan(plant(files))
        if bad: print(f"ok   plant is red: {name}")
        else: print(f"FAIL plant passed: {name}"); ok = False
    for name, files in greens.items():
        bad = scan(plant(files))
        if not bad: print(f"ok   control is green: {name}")
        else: print(f"FAIL control is red: {name}: {bad}"); ok = False
    return ok


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(0 if selftest() else 1)
    bad = scan(sys.argv[1])
    for b in bad: print("FAIL " + b)
    if bad: sys.exit(1)
    print("ok   every publishing step runs only on a tag push; no dispatch input publishes")
