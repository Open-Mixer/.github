#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A pull request into devel builds against the staging channel as well as the real one (devel -> staging -> prod): a
# lower level merged into devel is published to staging (its release.yml, staged: true, from devel), never to the real
# channel, so the next level's pull request CI must see staging or it builds against the last release instead (the
# blocker: omx-clap-core's devel pull request and a release-unit dry run installed omx-contract 3.19.1/3.21.0 from the
# channel, not the wave's build). build-rpm.yml and build-deb.yml: the build job's add-openmixer step, its condition and
# its staging and staging-bootstrap inputs, evaluated for each kind of run. A staging channel absent or purged REFUSES
# a pull request into devel by name (add-staging.sh, strict, names the URL that answered 404): staging-bootstrap is
# never true for one, not even when the caller passes it, so it never builds against the real channel silently. Nothing
# else changes: a pull request into any other branch, a tag and a plain dispatch see the real channel only, as before.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
python3 -I - "$here/../.github/workflows/build-rpm.yml" "$here/../.github/workflows/build-deb.yml" <<'PY'
import re, sys, yaml

def ev(expr, ctx):
    """Evaluate the small GitHub expression subset these lines use: names, 'strings', true/false, ==, !, &&, ||, ()."""
    e = expr.strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2]
    toks = re.findall(r"\(|\)|==|!=|&&|\|\||!|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*", e)
    out = []
    for t in toks:
        if t == "&&": out.append(" and ")
        elif t == "||": out.append(" or ")
        elif t == "!": out.append(" not ")
        elif t in ("==", "!=", "(", ")"): out.append(f" {t} ")
        elif t.startswith("'"): out.append(repr(t[1:-1]))
        elif t in ("true", "false"): out.append(repr(t == "true"))
        else:
            if t not in ctx: raise SystemExit(f"FAIL: the expression names {t}, which the test does not model: {expr}")
            out.append(repr(ctx[t]))
    # GitHub's && and || return an operand, and == compares strings: model a boolean as its string where compared
    return eval("".join(out), {"__builtins__": {}})

def truthy(v):
    return v not in (False, None, "", "false", 0)

fails = []
for wf in sys.argv[1:]:
    d = yaml.safe_load(open(wf))
    build = d["jobs"]["build"]
    env_expr = build.get("env", {}).get("STAGING_FOR_DEVEL")
    if env_expr is None:
        fails.append(f"{wf}: the build job has no STAGING_FOR_DEVEL")
        continue
    steps = [s for s in build["steps"] if str(s.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/add-openmixer@")]
    if len(steps) != 1:
        fails.append(f"{wf}: {len(steps)} add-openmixer steps in the build job")
        continue
    step = steps[0]
    names = [str(s.get("uses", s.get("name", ""))) for s in build["steps"]]
    ia = names.index(step["uses"])
    ib = [i for i, n in enumerate(names) if n.startswith("Open-Mixer/.github/.github/actions/contract-bootstrap@")]
    if ib and ib[0] < ia:
        fails.append(f"{wf}: contract-bootstrap runs before add-openmixer, so a bootstrap never sees staging")
    base_inputs = {"inputs.channel-deps": False, "inputs.staged": False, "inputs.staging": False, "inputs.staging-bootstrap": False,
                   "inputs.base-url": "", "inputs.release-package": "openmixer-release"}
    cases = [
        # name, event, base_ref, inputs, want add, want staging, want staging-bootstrap
        # staging-bootstrap False: an absent or purged staging channel refuses the run by name, never a silent fallback
        ("a pull request into devel", "pull_request", "devel", {}, True, True, False),
        ("a pull request into devel with channel-deps", "pull_request", "devel", {"inputs.channel-deps": True}, True, True, False),
        ("a pull request into devel whose caller passes staging-bootstrap", "pull_request", "devel",
         {"inputs.staging-bootstrap": True}, True, True, False),
        ("a pull request into main with channel-deps", "pull_request", "main", {"inputs.channel-deps": True}, True, False, False),
        ("a pull request into main", "pull_request", "main", {}, False, None, None),
        ("a push of a tag", "push", "", {"inputs.channel-deps": True}, True, False, False),
        ("a staged dispatch", "workflow_dispatch", "", {"inputs.staged": True}, True, True, False),
        ("a staged first layer", "workflow_dispatch", "", {"inputs.staged": True, "inputs.staging-bootstrap": True}, True, True, True),
    ]
    for name, event, base, inp, want_add, want_staging, want_boot in cases:
        ctx = dict(base_inputs, **inp)
        ctx.update({"github.event_name": event, "github.base_ref": base})
        envv = ev(env_expr, ctx)
        ctx["env.STAGING_FOR_DEVEL"] = "true" if truthy(envv) else "false"
        add = truthy(ev(step["if"], ctx))
        if add != want_add:
            fails.append(f"{wf}: {name}: add-openmixer runs={add}, want {want_add}")
            continue
        if not add:
            continue
        staging = truthy(ev(step["with"]["staging"], ctx))
        boot = truthy(ev(step["with"]["staging-bootstrap"], ctx))
        if staging != want_staging: fails.append(f"{wf}: {name}: staging={staging}, want {want_staging}")
        if boot != want_boot: fails.append(f"{wf}: {name}: staging-bootstrap={boot}, want {want_boot}")
if fails:
    print("\n".join(f"FAIL: {f}" for f in fails), file=sys.stderr)
    sys.exit(1)
print("devel pull request staging: ok")
PY
