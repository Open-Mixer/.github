#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A pull request into devel builds and tests against the staging channel as well as the real one (devel -> staging ->
# prod): a lower level merged into devel is published to staging (its release.yml, staged: true, from devel), never to
# the real channel, so the next level's pull request CI must see staging or it builds against the last release instead
# (the blocker: omx-clap-core's devel pull request, its own ci.yml read-back job and a release-unit dry run installed
# omx-contract 3.19.1/3.21.0 from the channel, not the wave's build). The switch lives in add-openmixer itself, so every
# caller gets it: build-rpm.yml, build-deb.yml and any repository's own ci.yml job that adds the channel.
#   1. add-openmixer's staging step, its condition and its env, evaluated for each kind of run: a pull request into
#      devel adds staging (OpenMixer's channel only), whatever staging says, with STAGING_FOR_DEVEL; STAGING_BOOTSTRAP is
#      the caller's input as it is (add-staging.sh refuses a devel pull request before it reads it).
#   2. build-rpm.yml and build-deb.yml run their add-openmixer step on a pull request into devel on OpenMixer's channel
#      even without channel-deps (never for FreeREAC's), and pass staging and staging-bootstrap as before.
#   3. add-staging.sh, run against a file:// channel with no staging tree, on any machine (staging is judged before
#      the real channel's file is looked for): STAGING_FOR_DEVEL=true refuses by name, even with STAGING_BOOTSTRAP=true;
#      STAGING_BOOTSTRAP=true alone still skips with its notice. SUITE is set, for a machine without dnf.
# Nothing else changes: a pull request into any other branch, a tag and a plain dispatch see the real channel only.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
python3 -I - "$root/.github/actions/add-openmixer/action.yml" "$root/.github/workflows/build-rpm.yml" "$root/.github/workflows/build-deb.yml" <<'PY'
import re, sys, yaml

def ev(expr, ctx):
    """Evaluate the small GitHub expression subset these lines use: names, 'strings', true/false, ==, !=, !, &&, ||, (),
    and startsWith(a, b)."""
    e = str(expr).strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2]
    toks = re.findall(r"startsWith|\(|\)|,|==|!=|&&|\|\||!|'[^']*'|[A-Za-z_][A-Za-z0-9_.-]*", e)
    out = []
    for t in toks:
        if t == "&&": out.append(" and ")
        elif t == "||": out.append(" or ")
        elif t == "!": out.append(" not ")
        elif t == "startsWith": out.append(" sw")
        elif t in ("==", "!=", "(", ")", ","): out.append(f" {t} ")
        elif t.startswith("'"): out.append(repr(t[1:-1]))
        elif t in ("true", "false"): out.append(repr(t == "true"))
        else:
            if t not in ctx: raise SystemExit(f"FAIL: the expression names {t}, which the test does not model: {expr}")
            out.append(repr(ctx[t]))
    return eval("".join(out), {"__builtins__": {}, "sw": lambda a, b: str(a).lower().startswith(str(b).lower())})

def truthy(v):
    return v not in (False, None, "", "false", 0)

fails = []
act_path, *wfs = sys.argv[1:]

# ---- 1. add-openmixer: the staging step
act = yaml.safe_load(open(act_path))
# the staging step; the devel step (LEVEL=devel/<wave>, add-openmixer devel-channel) is tests/devel-channel-publish.sh's
st = [s for s in act["runs"]["steps"] if "add-staging.sh" in s.get("run", "") and "LEVEL=" not in s.get("run", "")]
if len(st) != 1:
    fails.append(f"add-openmixer: {len(st)} steps run add-staging.sh")
else:
    st = st[0]
    env = st.get("env", {})
    for k in ("STAGING_FOR_DEVEL", "STAGING_BOOTSTRAP"):
        if k not in env: fails.append(f"add-openmixer: the staging step has no {k}")
    if str(env.get("STAGING_BOOTSTRAP")) != "${{ inputs.staging-bootstrap }}":
        fails.append(f"add-openmixer: STAGING_BOOTSTRAP is {env.get('STAGING_BOOTSTRAP')}, not the input as it is (a first staged run must still skip)")
    cases = [
        # name, event, base_ref, staging, staging-bootstrap, release-package, want runs, want for-devel, want bootstrap
        ("a pull request into devel", "pull_request", "devel", "false", "false", "openmixer-release", True, True, False),
        ("a pull_request_target into devel", "pull_request_target", "devel", "false", "false", "openmixer-release", True, True, False),
        ("a pull request into devel asking staging-bootstrap", "pull_request", "devel", "true", "true", "openmixer-release", True, True, True),
        ("a pull request into devel on FreeREAC's channel", "pull_request", "devel", "false", "false", "freereac-release", False, None, None),
        ("a pull request into main", "pull_request", "main", "false", "false", "openmixer-release", False, None, None),
        ("a push to devel", "push", "", "false", "false", "openmixer-release", False, None, None),
        ("a staged dispatch", "workflow_dispatch", "", "true", "false", "openmixer-release", True, False, False),
        ("a staged first layer", "workflow_dispatch", "", "true", "true", "openmixer-release", True, False, True),
    ]
    for name, event, base, staging, boot, pkg, want_run, want_dev, want_boot in cases:
        ctx = {"github.event_name": event, "github.base_ref": base, "inputs.staging": staging,
               "inputs.staging-bootstrap": boot, "inputs.release-package": pkg, "inputs.devel-channel": ""}
        run = truthy(ev(st["if"], ctx))
        if run != want_run:
            fails.append(f"add-openmixer: {name}: the staging step runs={run}, want {want_run}"); continue
        if not run: continue
        dev = truthy(ev(env.get("STAGING_FOR_DEVEL", "false"), ctx))
        b = truthy(ev(env.get("STAGING_BOOTSTRAP", "false"), ctx))
        if dev != want_dev: fails.append(f"add-openmixer: {name}: STAGING_FOR_DEVEL={dev}, want {want_dev}")
        if b != want_boot: fails.append(f"add-openmixer: {name}: STAGING_BOOTSTRAP={b}, want {want_boot}")

# ---- 2. build-rpm.yml / build-deb.yml: the build job's add-openmixer step
for wf in wfs:
    build = yaml.safe_load(open(wf))["jobs"]["build"]
    if "STAGING_FOR_DEVEL" in build.get("env", {}):
        fails.append(f"{wf}: the build job keeps a STAGING_FOR_DEVEL of its own: add-openmixer holds the switch")
    steps = [s for s in build["steps"] if str(s.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/add-openmixer@")]
    if len(steps) != 1:
        fails.append(f"{wf}: {len(steps)} add-openmixer steps in the build job"); continue
    step = steps[0]
    names = [str(s.get("uses", s.get("name", ""))) for s in build["steps"]]
    ia = names.index(step["uses"])
    ib = [i for i, n in enumerate(names) if n.startswith("Open-Mixer/.github/.github/actions/contract-bootstrap@")]
    if ib and ib[0] < ia:
        fails.append(f"{wf}: contract-bootstrap runs before add-openmixer, so a bootstrap never sees staging")
    base_inputs = {"inputs.channel-deps": False, "inputs.staged": False, "inputs.staging": False, "inputs.staging-bootstrap": False,
                   "inputs.release-package": "openmixer-release"}
    frc = {"inputs.release-package": "freereac-release"}
    cases = [
        ("a pull request into devel", "pull_request", "devel", {}, True),
        ("a pull request into devel on FreeREAC's channel", "pull_request", "devel", frc, False),
        ("a pull request into devel on FreeREAC's channel with channel-deps", "pull_request", "devel", dict(frc, **{"inputs.channel-deps": True}), True),
        ("a pull request into devel with channel-deps", "pull_request", "devel", {"inputs.channel-deps": True}, True),
        ("a pull request into main with channel-deps", "pull_request", "main", {"inputs.channel-deps": True}, True),
        ("a pull request into main", "pull_request", "main", {}, False),
        ("a push of a tag", "push", "", {"inputs.channel-deps": True}, True),
        ("a staged dispatch", "workflow_dispatch", "", {"inputs.staged": True}, True),
        ("a push to devel (a merge, staged: .github#289)", "push", "", {"github.ref": "refs/heads/devel"}, True),
    ]
    for name, event, base, inp, want_add in cases:
        ctx = dict(base_inputs, **inp)
        ctx.update({"github.event_name": event, "github.base_ref": base})
        ctx.setdefault("github.ref", "refs/tags/v1.0.0" if event == "push" else "refs/heads/devel" if event == "workflow_dispatch" else "refs/pull/1/merge")
        add = truthy(ev(step["if"], ctx))
        if add != want_add: fails.append(f"{wf}: {name}: add-openmixer runs={add}, want {want_add}")
    if str(step["with"].get("staging-bootstrap")) != "${{ inputs.staging-bootstrap }}":
        fails.append(f"{wf}: staging-bootstrap is {step['with'].get('staging-bootstrap')}, not the caller's input as it is")
    # a pull request into devel builds its own repository only: a lower layer is the staging channel's published
    # package, never rebuilt from source, so contract-bootstrap (a sibling built at a named commit) does not run for it
    boots = [s for s in build["steps"] if str(s.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/contract-bootstrap@")]
    if len(boots) != 1:
        fails.append(f"{wf}: {len(boots)} contract-bootstrap steps in the build job")
    else:
        entry = "o/r@" + "0" * 40 + ":p-contract"
        for name, event, base, bootstrap, want in [
            ("a pull request into devel naming a bootstrap", "pull_request", "devel", entry, False),
            ("a pull_request_target into devel naming a bootstrap", "pull_request_target", "devel", entry, False),
            ("a pull request into main naming a bootstrap", "pull_request", "main", entry, True),
            ("a dispatch naming a bootstrap", "workflow_dispatch", "", entry, True),
            ("a pull request into devel naming none", "pull_request", "devel", "", False),
        ]:
            ctx = {"github.event_name": event, "github.base_ref": base, "inputs.bootstrap": bootstrap}
            run = truthy(ev(boots[0]["if"], ctx))
            if run != want:
                fails.append(f"{wf}: {name}: contract-bootstrap runs={run}, want {want} (a devel pull request never rebuilds a lower layer from source)")
if fails:
    print("\n".join(f"FAIL: {f}" for f in fails), file=sys.stderr)
    sys.exit(1)
print("devel pull request staging, the switch in add-openmixer: ok")
PY

# ---- 3. add-staging.sh against a channel with no staging tree (file://, a missing file is a 404)
work=$(mktemp -d "${TMPDIR:-/tmp}/devel-pr-staging.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/channel/rpm" "$work/channel/deb"
script=$root/.github/actions/add-openmixer/add-staging.sh
if STAGING_FOR_DEVEL=true STAGING_BOOTSTRAP=true SUITE=trixie BASE_URL="file://$work/channel" bash "$script" > "$work/dev.log" 2>&1; then
    cat "$work/dev.log"; echo "FAIL: a pull request into devel passed with no staging channel (it must refuse by name)" >&2; exit 1
fi
grep -q 'a pull request into devel builds against the staging channel' "$work/dev.log" ||
    { cat "$work/dev.log"; echo "FAIL: the refusal of a pull request into devel does not say why" >&2; exit 1; }
echo "devel pull request, no staging channel: refused by name, staging-bootstrap or not: ok"
STAGING_BOOTSTRAP=true SUITE=trixie BASE_URL="file://$work/channel" bash "$script" > "$work/boot.log" 2>&1 ||
    { cat "$work/boot.log"; echo "FAIL: staging-bootstrap no longer skips a staging channel never published" >&2; exit 1; }
echo "staging-bootstrap alone still skips a staging channel never published: ok"
