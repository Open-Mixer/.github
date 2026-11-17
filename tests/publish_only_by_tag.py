# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Publish only by tagging (docs/release-operations.md).

A step PUBLISHES when of what it does: `gh release create|upload`, `npm publish`, an rsync/rclone/s3 copy, any
`git push`, a `gh api` write to refs, releases, contents or dispatches, a third-party release/pages action, or a local
composite action that contains one of these (the channel push helper is one). Names are not read: a workflow named
anything publishes if its steps do.

Every publishing step must be GUARDED: the conjunction of its job `if`, its step `if`, and (for a composite action)
the action's own `if` with `inputs.X` replaced by what the caller passes, must be false whenever the tag condition is
false, for EVERY value of the other conditions. So `x || TAG`, `always() || TAG`, a TAG that is only in a job name or a
comment, and a `sign: true` are all refused. A build with `staged: true` writes staging/ of the channel repository
only (the stage flow, not a release), and the purge of staging is likewise staging-only: those two are named below.

A workflow a person can start by hand takes no input named like a publish switch. Workflows and composite actions,
.yml and .yaml, are all read. Usage: publish_only_by_tag.py <repo root> | --selftest
"""
import itertools, json, os, re, sys, tempfile
import yaml

TAG = "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
STAGING_ONLY_ACTIONS = {"purge-staging"}      # writes staging/ only
STAGED_ATOM = "inputs.staged"                  # a build with staged: true publishes to staging/ only

RUN_PUBLISHES = [
    (re.compile(r"\bgh\s+release\s+(create|upload|edit|delete)\b"), "gh release"),
    (re.compile(r"\b(npm|pnpm)\s+(publish|dist-tag)\b|\byarn\s+npm\s+publish\b"), "npm publish"),
    (re.compile(r"\b(aws\s+s3\s+(cp|sync|mv)|s3cmd\s+(put|sync)|rclone\s+(copy|sync|move|copyto)|rsync|scp|gsutil\s+(cp|rsync)|mc\s+cp|twine\s+upload|cargo\s+publish|docker\s+push)\b"), "an upload"),
    (re.compile(r"\bgit\b[^\n]*\bpush\b|^\s*push\s+origin\b", re.M), "git push"),
    (re.compile(r"\bgh\s+api\b[^\n]*(git/refs|/releases|/dispatches|/contents/)"), "a gh api write"),
]
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
        t = ast[1].lower()
        if t == "true": return True
        if t == "false": return False
        return val[ast[1]]
    if k == "not": return not ev(ast[1], val)
    if k == "and": return ev(ast[1], val) and ev(ast[2], val)
    return ev(ast[1], val) or ev(ast[2], val)


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


def subst(expr, inputs, env):
    """replace inputs.X by what the caller passed and env.X by the job's env, a few levels deep"""
    e = canon(expr)
    for _ in range(4):
        def one(kind, table):
            def f(m):
                name = m.group(1)
                if name not in table: return m.group(0)
                v = table[name]
                lit = literal(v)
                if lit is not None: return "true" if lit.lower() == "true" else "false"
                return "(" + canon(v) + ")"
            return f
        n = re.sub(r"\binputs\.([\w-]+)", one("inputs", inputs), e)
        n = re.sub(r"\benv\.([\w-]+)", one("env", env), n)
        n = n.replace("(" + TAG + ")", "TAGATOM").replace(TAG, "TAGATOM")
        if n == e: break
        e = n
    return e


def guarded(exprs, safe):
    """True when the conjunction of exprs is false whenever TAGATOM (and each safe atom) is false"""
    exprs = [e for e in exprs if e is not None and str(e).strip() not in ("", "True")]
    if not exprs: return False
    asts = [parse(tokens(e)) for e in exprs]
    ats = set()
    for a in asts: atoms(a, ats)
    free = sorted(x for x in ats if x not in ("TAGATOM",) and x.lower() not in ("true", "false") and x not in safe)
    if len(free) > 16: return False
    for combo in itertools.product([False, True], repeat=len(free)):
        val = dict(zip(free, combo)); val["TAGATOM"] = False
        for sa in safe: val[sa] = False
        if all(ev(a, val) for a in asts): return False
    return True


def reachable(exprs, safe):
    """True when the conjunction can be true ON A TAG PUSH: a guard that also excludes the event of a tag (a job `if`
    that wants workflow_dispatch) is a publisher that can never publish"""
    exprs = [e for e in exprs if e is not None and str(e).strip() not in ("", "True")]
    if not exprs: return True
    asts = [parse(tokens(e)) for e in exprs]
    ats = set()
    for a in asts: atoms(a, ats)
    other_event = lambda x: re.fullmatch(r"github\.event_name\s*==\s*'(?!push')\w+'", x) is not None
    free = sorted(x for x in ats if x != "TAGATOM" and x.lower() not in ("true", "false") and not other_event(x))
    if len(free) > 16: return True
    for combo in itertools.product([False, True], repeat=len(free)):
        val = dict(zip(free, combo)); val["TAGATOM"] = True
        for x in ats:
            if other_event(x): val[x] = False
        if all(ev(a, val) for a in asts): return True
    return False


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

    def action_publishers(self, name, stack=()):
        """[(what, [guard exprs over inputs.*], safe-atoms)] for the publishing steps inside a composite action"""
        if name in self.memo: return self.memo[name]
        if name in stack: return []
        act = self.actions[name]
        defaults = {k: (v or {}).get("default") for k, v in (act.get("inputs") or {}).items()}
        out = []
        steps = ((act.get("runs") or {}).get("steps")) or []
        for st in steps:
            out += self.step_publishers(st, [], {}, {k: v for k, v in defaults.items() if v is not None}, stack + (name,), frozenset())
        # a script of the action directory that publishes, called from a step, makes the whole action a publisher
        d = os.path.join(self.root, ".github", "actions", name)
        for fn in sorted(os.listdir(d)):
            if fn.endswith((".sh", ".py")) and not fn.startswith(("selftest", "test")) and not out:
                txt = re.sub(r"\\\n\s*", " ", open(os.path.join(d, fn), errors="replace").read())
                txt = "\n".join(l for l in txt.splitlines() if not l.lstrip().startswith("#"))
                for rx, what in RUN_PUBLISHES:
                    # a script publishes when a LINE starts with the command (a quoted example or a fixture does not)
                    if re.search(r"^\s*(?:\w+=\S+\s+)*(?:" + rx.pattern.replace("^\\s*", "").replace("\\b", "", 1) + ")", txt, re.M):
                        out.append((what + " in " + fn, [], frozenset())); break
        self.memo[name] = out
        return out

    def step_publishers(self, st, base_guards, env, defaults, stack, safe):
        """publishing findings of one step: [(what, [guard exprs], safe)] with the step's own `if` included"""
        found = []
        guards = base_guards + ([st["if"]] if "if" in st else [])
        uses = str(st.get("uses", ""))
        if uses:
            name = self.local(uses)
            if name in STAGING_ONLY_ACTIONS: return []
            if name:
                with_ = dict(defaults); with_.update(st.get("with") or {})
                sf = set(safe)
                stg = (st.get("with") or {}).get("staging")
                if stg is not None and STAGED_ATOM in str(stg): sf.add(STAGED_ATOM)
                for what, inner, isf in self.action_publishers(name, stack):
                    sub = [subst(g, with_, {}) for g in inner]
                    found.append((f"{what} (through {name})", guards + sub, frozenset(sf | set(isf))))
            elif USES_PUBLISHES.search(uses):
                found.append((f"the action {uses}", guards, safe))
        if "run" in st:
            t = run_text(st)
            for rx, what in RUN_PUBLISHES:
                hit = [m for m in rx.finditer(t) if not (what == "npm publish" and "--dry-run" in t[m.start():t.find("\n", m.end()) if t.find("\n", m.end()) >= 0 else None])]
                if hit: found.append((what, guards, safe)); break
        return found


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
            for what, gs, safe in repo.step_publishers(st, base, env, {}, (), frozenset()):
                exprs = [subst(g, {}, env) for g in gs]
                label = st.get("name") or st.get("uses") or f"step {n + 1}"
                if not guarded(exprs, safe):
                    bad.append(f"{rel}: job '{job}' step '{label}' publishes ({what}) without the tag condition ({TAG})")
                elif not reachable(exprs, safe):
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
        "a staged build into staging/ only": {
            "actions/pub/action.yml": "name: pub\ninputs:\n  sign:\n    default: 'false'\n  staging:\n    default: 'false'\nruns:\n  using: composite\n  steps:\n    - if: inputs.sign == 'true'\n      shell: bash\n      run: git push origin HEAD\n",
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
