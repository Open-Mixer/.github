#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The staging channel of a release wave, offline (docs/release-operations.md, "The staging channel"). Proves:
#   - the prerelease staging is gone: no stage-release or unstage job, and nothing reads staged-deps or installs from a
#     staged-v prerelease. For this wave only, staged-deps stays an accepted, ignored input (a caller that passes it
#     renders the same jobs as one that does not) and install-staged a no-op action that takes the old inputs, says
#     it is retired and installs nothing; both go in the wave's release pass;
#   - build-rpm.yml and build-deb.yml, rendered: a staged run builds the cells the first job names (the quick set
#     unless told full: tests/release-matrix.sh), never narrowed by staged anywhere else, with the
#     staging channel added, and publishes through publish-rpms / publish-debs with staging on, into the live publish group; a tag release and a
#     dry run publish into rpm/ and deb/ with the staging channel never added; staging alone adds the channel to the
#     build and publishes nothing; the install check of a staged run adds the staging channel, a release's does not;
#   - the precheck, run as written: staged and staging never on a tag, never with source-ref, never with publish, and a
#     staged run builds the calling repository only;
#   - the publish actions write staging/<kind> with staging on and <kind> otherwise, in the first assembly, the
#     lost-race rebuild and the commit, and channel-pull strips only the tree being published;
#   - the repository files: ids that start with openmixer (channel-installability disables those), priority 10 against
#     the real file's default, the same key, the staging path; the apt source on the staging path with the same
#     keyring, the pin naming the label the staging publish writes, above 500;
#   - the purge workflow: dispatch and call with the same inputs, one job per kind, each committing staging/<kind>
#     only, and a guard that refuses a checkout changed outside it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }

# ---- the prerelease staging is gone, with every caller
[ ! -e "$here/.github/actions/stage-release" ] || fail ".github/actions/stage-release is still here"
# staged-deps only where it is declared, install-staged only in its own no-op directory and the removal note
hits=$(grep -rnE 'install-staged|stage-release|staged-deps|unstage:' "$here/.github" "$here/docs" "$here/README.md" |
    grep -vE '^[^:]*/\.github/workflows/build-(rpm|deb)\.yml:[0-9]+:      (staged-deps:|# staged-deps .*removed in the wave)' |
    grep -vE '^[^:]*/\.github/actions/install-staged/' |
    grep -vE '^[^:]*/docs/release-operations\.md:[0-9]+:.*removed in the wave' || true)
[ -z "$hits" ] || fail "the prerelease staging is still named or read: $hits"
ok "no stage-release or unstage job is left, and nothing reads staged-deps or calls install-staged"

# ---- install-staged, retired: the old inputs, one line, nothing installed
python3 -I - "$here/.github/actions/install-staged/action.yml" "$t/noop.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d.get("inputs") or {}
# the inputs of the action at eee6ec8, so a caller's with: block still validates
assert set(i) == {"packages", "tree", "token"}, f"install-staged takes {sorted(i)}, not packages, tree, token"
assert i["packages"].get("required") is True and i["tree"].get("default") == "." and i["token"].get("default") == "${{ github.token }}", \
    "install-staged's inputs changed shape"
steps = d["runs"]["steps"]
assert d["runs"]["using"] == "composite" and len(steps) == 1 and "uses" not in steps[0], "install-staged is more than one step"
open(sys.argv[2], "w").write(steps[0]["run"])
PY
mkdir -p "$t/noop/bin"
for c in dnf apt-get apt dpkg rpm curl gh python3 sudo; do printf '#!/bin/sh\necho "%s $*" >> "$NOOP_LOG"\n' "$c" > "$t/noop/bin/$c"; done
chmod +x "$t/noop/bin"/*
out=$(cd "$t/noop" && env -i PATH="$t/noop/bin:/usr/bin:/bin" NOOP_LOG="$t/noop/log" PACKAGES='plugin-hostd@0.20.3:plugin-hostd-devel' \
    STAGED_TREE=. GH_TOKEN=x GITHUB_ACTION_PATH="$here/.github/actions/install-staged" bash -e "$t/noop.sh" 2>&1) || fail "install-staged failed: $out"
[ ! -s "$t/noop/log" ] || fail "install-staged ran $(cat "$t/noop/log")"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && echo "$out" | grep -qi 'retired' && echo "$out" | grep -q 'staging' ||
    fail "install-staged does not say in one line that it is retired and staging replaces it: $out"
ok "install-staged takes packages, tree and token, prints one line and installs nothing"

# ---- the reusable workflows, rendered
python3 -I - "$here/.github/workflows/build-rpm.yml" "$here/.github/workflows/build-deb.yml" <<'PY'
import json, re, sys, yaml

class O(dict):
    __getattr__ = dict.get

def ev(expr, inputs, needs=None, matrix=None, ref_type="branch"):
    e = str(expr).strip()
    if e.count("${{") > 1 or (e.count("${{") == 1 and not (e.startswith("${{") and e.endswith("}}"))):
        # a string with expressions inside it: each is evaluated and written in
        return re.sub(r"\$\{\{(.*?)\}\}", lambda m: str(ev("${{" + m.group(1) + "}}", inputs, needs, matrix, ref_type)), e)
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2].strip()
    e = re.sub(r"\binputs\.([a-z0-9-]+)", lambda m: f'inputs["{m.group(1)}"]', e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    env = {"inputs": inputs, "fromJSON": json.loads, "cancelled": lambda: False, "always": lambda: True,
           "true": True, "false": False, "join": lambda a, s=",": s.join(a),
           "format": lambda f, *a: re.sub(r"\{(\d+)\}", lambda m: str(a[int(m.group(1))]), f),
           "contains": lambda a, b: b in a,
           "github": O(ref_type=ref_type, ref_name="v1.2.0" if ref_type == "tag" else "main", sha="5f455d37cfb5" + "0" * 28, run_id="4242",
                       event_name="workflow_dispatch", ref="refs/heads/x", repository="o/r",
                       event=O(pull_request=O(head=O(repo=O(full_name="o/r"))))),
           "needs": needs or O(), "matrix": matrix or O(), "vars": O(), "secrets": O(), "runner": O(temp="/tmp"),
           "env": O(), "startsWith": lambda a, b: str(a).startswith(b)}
    return eval(e, {"__builtins__": {}}, env)

def truthy(v):
    return v is True or v == "true"

def check(path, kind):
    d = yaml.safe_load(open(path))
    on = d.get(True) or d.get("on")
    decl = on["workflow_call"]["inputs"]
    base = {k: v.get("default") for k, v in decl.items()}
    # staged-deps, for this wave: an accepted string that nothing reads
    assert decl.get("staged-deps", {}).get("type") == "string" and base["staged-deps"] == "", f"{path}: staged-deps is not an accepted string input"
    assert "inputs.staged-deps" not in open(path).read(), f"{path}: something reads staged-deps"
    def render(x, inp, rt):
        if isinstance(x, dict): return {k: render(v, inp, rt) for k, v in x.items()}
        if isinstance(x, list): return [render(v, inp, rt) for v in x]
        if isinstance(x, str) and "${{" in x:
            try: return ("=", ev(x, inp, needs=O(build=O(result="success"), publish=O(result="success")), ref_type=rt))
            except Exception as e: return ("!", type(e).__name__)
        return x
    for rt, extra in (("branch", {}), ("branch", {"staged": True}), ("branch", {"staging": True}), ("tag", {"publish": True})):
        a = dict(base, **extra); b = dict(a, **{"staged-deps": "x"})
        assert render(d["jobs"], a, rt) == render(d["jobs"], b, rt), f"{path}: staged-deps 'x' changes the jobs ({extra or 'dry run'})"
    for name in ("staged", "staging"):
        assert decl.get(name, {}).get("type") == "boolean" and base[name] is False, f"{path}: {name} is not a boolean defaulting off"
    jobs = d["jobs"]
    assert "staged" not in jobs and "unstage" not in jobs, f"{path}: the staged-v jobs are still here"
    arches = '["x86_64", "aarch64"]' if kind == "rpm" else '["amd64", "arm64"]'
    caller = dict(base, **{"arch-matrix": arches})
    staged = dict(caller, staged=True)
    staging = dict(caller, staging=True)
    tag = dict(caller, publish=True)
    dry = dict(caller)
    ok_build = O(build=O(result="success"))

    # the build: the cells the first job names (the quick set or the full matrix: tests/release-matrix.sh renders
    # both), with the staging channel added before the build when staged or staging
    build = jobs["build"]
    m = build["strategy"]["matrix"]
    assert m == {"include": "${{ fromJSON(needs.preflight.outputs.cells) }}"}, f"{path}: the build matrix is {m}, not the cells of the first job"
    # what ships once per release (source and noarch packages) ships from the same architecture, staged or not
    text = open(path).read()
    assert "inputs.staged &&" not in "".join(l for l in text.splitlines(True) if "matrix" in l.lower() or "FIRST_ARCH" in l), \
        f"{path}: a staged run still narrows the matrix somewhere"
    steps = build["steps"]
    uses = [s.get("uses", "") for s in steps]
    add = [k for k, u in enumerate(uses) if "/actions/add-openmixer@" in u]
    bld = [k for k, u in enumerate(uses) if f"/actions/build-{kind}@" in u]
    assert len(add) == 1 and bld and add[0] < bld[0], f"{path}: add-openmixer must run once, before the build"
    s = steps[add[0]]
    for name, inp, want_add, want_stg in (("staged", staged, True, True), ("staging", staging, True, True),
                                          ("a release", tag, True, False), ("a dry run", dry, True, False),
                                          ("staged without channel-deps", dict(staged, **{"channel-deps": False}), True, True)):
        assert bool(ev(s.get("if", "true"), inp)) == want_add, f"{path}: add-openmixer in the build of {name}"
        assert truthy(ev(s["with"].get("staging", "false"), inp)) == want_stg, \
            f"{path}: the build of {name} {'does not add' if want_stg else 'adds'} the staging channel"

    # the publish: a staged run signs and publishes into staging/<kind>, in the live group
    pub = jobs["publish"]
    assert ev(pub.get("if", "true"), staged, needs=ok_build), f"{path}: publish skipped on a staged run"
    for name, inp, rt, want_do, want_stg in (("staged", staged, "branch", True, True), ("a release", tag, "tag", True, False),
                                             ("a dry run", dry, "branch", False, False), ("staging", staging, "branch", False, False)):
        assert truthy(ev(pub["env"]["DO_PUBLISH"], inp, ref_type=rt)) == want_do, f"{path}: DO_PUBLISH for {name}"
        st = [x for x in pub["steps"] if f"/actions/publish-{kind}s@" in x.get("uses", "")][0]
        assert truthy(ev(st["with"]["staging"], inp, ref_type=rt)) == want_stg, f"{path}: publish-{kind}s staging for {name}"
        group = ev(pub["concurrency"]["group"], inp, ref_type=rt)
        assert group.endswith("-live") == (want_do or inp is tag), f"{path}: {name} publishes in group {group}"
    st = [x for x in pub["steps"] if f"/actions/publish-{kind}s@" in x.get("uses", "")][0]
    assert "5f455d37cfb5" in ev(st["with"]["tag"], staged), f"{path}: the staged commit message does not name the commit"
    rels = ev(st["with"]["releases" if kind == "rpm" else "suites"], staged)
    assert rels == " ".join(json.loads(base["fedora-versions" if kind == "rpm" else "suite-matrix"])), \
        f"{path}: the staging skeleton is {rels!r}, not every release of the matrix"
    if kind == "deb":
        assert ev(st["with"]["changelogs-url"], staged).endswith("/staging/deb/changelogs"), f"{path}: staged changelogs URL"
        assert ev(st["with"]["changelogs-url"], tag, ref_type="tag").endswith("/deb/changelogs") and \
            "staging" not in ev(st["with"]["changelogs-url"], tag, ref_type="tag"), f"{path}: release changelogs URL"
        sep = steps[bld[0]]["with"].get("separator")
        assert ev(sep, staged) == "+git" and ev(sep, dry) == "~git", f"{path}: the staged DEB snapshot separator"

    # the install check: from staging after a staged publish, from the real channel alone after a release
    v = jobs["verify"]
    ok_pub = O(publish=O(result="success"))
    assert ev(v["if"], staged, needs=ok_pub), f"{path}: no install check after a staged publish"
    assert ev(v["if"], tag, needs=ok_pub, ref_type="tag"), f"{path}: no install check after a release"
    assert not ev(v["if"], dry, needs=ok_pub), f"{path}: an install check on a dry run"
    assert not ev(v["if"], dict(staged, **{"verify-install": False}), needs=ok_pub), f"{path}: verify-install false ignored"
    # the install check runs for the built cells, no others
    assert v["strategy"]["matrix"] == m, f"{path}: the install check has a matrix of its own: {v['strategy']['matrix']}"
    a = [x for x in v["steps"] if "/actions/add-openmixer@" in x.get("uses", "")]
    assert len(a) == 1, f"{path}: the install check adds the channel once"
    assert truthy(ev(a[0]["with"].get("staging", "false"), staged)), f"{path}: the staged install check does not add staging"
    assert not truthy(ev(a[0]["with"].get("staging", "false"), tag, ref_type="tag")), f"{path}: a release's install check adds staging"
    inst = [x for x in v["steps"] if x.get("name", "").startswith("Install")]
    real = [x for x in inst if "staging" not in x["name"]]
    stg = [x for x in inst if "staging" in x["name"]]
    assert len(real) == 1 and len(stg) == 1, f"{path}: one install step for a release, one for a staged run"
    assert not ev(real[0]["if"], staged) and ev(real[0]["if"], tag), f"{path}: the release install step runs on a staged run"
    assert ev(stg[0]["if"], staged) and not ev(stg[0]["if"], tag), f"{path}: the staged install step runs on a release"
    assert "GITHUB_SHA" in stg[0]["run"], f"{path}: the staged install check does not hold the build to this commit"

    # the preflight checks a staged run's secrets and target, without asking for a tag
    pf = [x for x in jobs["preflight"]["steps"] if "/actions/release-preflight@" in x.get("uses", "")][0]
    assert truthy(ev(pf["with"]["publish"], staged)) and not truthy(ev(pf["with"]["require-tag"], staged)), \
        f"{path}: the preflight does not check what a staged run publishes with"
    assert truthy(ev(pf["with"]["require-tag"], tag, ref_type="tag")), f"{path}: a release no longer needs its tag"
    print(f"ok   {path.split('/')[-1]}: staged builds against staging and publishes there; a release and a dry run never see it")

check(sys.argv[1], "rpm")
check(sys.argv[2], "deb")
PY

# ---- a step of a workflow or an action, run as the runner would: its script with its env names set here
step() { # <file> <job|-> <name pattern> <out>: writes the step's run to <out>, prints its `if` and its env as JSON
    python3 -I - "$@" <<'PY'
import json, re, sys, yaml
path, job, pat, out = sys.argv[1:5]
d = yaml.safe_load(open(path))
steps = d["runs"]["steps"] if job == "-" else d["jobs"][job]["steps"]
hit = [s for s in steps if re.search(pat, s.get("name", "") + " " + s.get("run", ""))]
assert len(hit) == 1, f"{path} {job}: {len(hit)} steps match {pat!r}"
open(out, "w").write(hit[0]["run"])
print(json.dumps({"if": hit[0].get("if", ""), "env": hit[0].get("env", {})}))
PY
}

# ---- the precheck, run as written
for wf in "$here/.github/workflows/build-rpm.yml" "$here/.github/workflows/build-deb.yml"; do
    meta=$(step "$wf" preflight 'staging never builds a release' "$t/pre.sh")
    python3 -I - "$meta" "$wf" <<'PY'
import json, re, sys
m, wf = json.loads(sys.argv[1]), sys.argv[2]
assert re.search(r"inputs\.staged\b", m["if"]) and "inputs.staging" in m["if"], f"{wf}: the precheck does not run for staged and for staging: {m['if']}"
want = {"STAGED": "inputs.staged", "STAGING": "inputs.staging", "PUBLISH": "inputs.publish",
        "SOURCE_REPOSITORY": "inputs.source-repository", "SOURCE_REF": "inputs.source-ref", "REF_TYPE": "github.ref_type"}
for k, v in want.items():
    assert m["env"].get(k, "").replace(" ", "") == "${{" + v + "}}", f"{wf}: precheck env {k} is {m['env'].get(k)!r}"
PY
    pre() { env -i PATH="$PATH" STAGED=false STAGING=false PUBLISH=false SOURCE_REPOSITORY= SOURCE_REF= REF_TYPE=branch "$@" bash -e "$t/pre.sh" 2>&1; }
    w=${wf##*/}
    pre STAGED=true >/dev/null || fail "$w: a plain staged run is refused"
    pre STAGING=true >/dev/null || fail "$w: a dry run with staging is refused"
    pre STAGING=true SOURCE_REPOSITORY=o/r >/dev/null || fail "$w: a staging dry run of another repository is refused"
    for who in STAGED STAGING; do
        err=$(pre $who=true REF_TYPE=tag) && fail "$w: $who on a tag passed"
        echo "$err" | grep -q 'never a tag' || fail "$w: $who on a tag not explained: $err"
        err=$(pre $who=true SOURCE_REF=v0.20.3) && fail "$w: $who with source-ref passed"
        echo "$err" | grep -q 'source-ref' || fail "$w: source-ref not named: $err"
        err=$(pre $who=true PUBLISH=true) && fail "$w: $who with publish passed"
        echo "$err" | grep -q 'publish' || fail "$w: publish not named: $err"
    done
    err=$(pre STAGED=true SOURCE_REPOSITORY=o/r) && fail "$w: staged with source-repository passed"
    echo "$err" | grep -q 'calling repository' || fail "$w: source-repository not named: $err"
done
ok "precheck: staged and staging never on a tag, with source-ref or with publish; staged builds its own repository"

# ---- the publish actions: one tree variable, from the staging input, used everywhere the tree is named
python3 -I - "$here/.github/actions" <<'PY'
import re, sys, yaml
root = sys.argv[1]
for kind in ("rpm", "deb"):
    p = f"{root}/publish-{kind}s/action.yml"
    d = yaml.safe_load(open(p)); text = open(p).read()
    var = "RPM_TREE" if kind == "rpm" else "DEB_TREE"
    assert d["inputs"]["staging"]["default"] == "false", f"{p}: staging must default off"
    steps = d["runs"]["steps"]
    first = steps[1]
    assert f"{var}=staging/{kind}" in first["run"] and f"{var}={kind}" in first["run"] and first["env"]["STAGING"] == "${{ inputs.staging }}", \
        f"{p}: the tree is not set from the staging input before anything else"
    # every name of the channel tree goes through the variable: no literal build/channel/<kind> left
    assert not re.search(rf"build/(channel|repo)/{kind}\b(?!/)", text.replace(f"build/channel/{kind}/RPM-GPG-KEY", "").replace(f"build/channel/{kind}/openmixer.asc", "")
                         .replace("REQUIRES_TREE=build/channel/deb", "")), f"{p}: a literal build/channel/{kind} is left"
    push = [s for s in steps if "/actions/channel-push@" in s.get("uses", "")][0]
    w = push["with"]
    for flag, want in (("true", f"staging/{kind}"), ("false", kind)):
        got = w["what"].replace("${{", "").replace("}}", "").strip()
        got = eval(got.replace("inputs.staging", repr(flag)).replace("&&", " and ").replace("||", " or "), {})
        assert got == want, f"{p}: channel-push adds {got} with staging {flag}, want {want}"
    assert f'"build/channel/${var}"' in w["rebuild"], f"{p}: the lost-race rebuild does not assemble the same tree"
    pull = [s for s in steps if "/actions/channel-pull@" in s.get("uses", "")][0]
    if kind == "rpm":
        assert pull["with"]["strip"] == "${{ inputs.staging == 'true' && 'staging/rpm' || 'rpm' }}", f"{p}: channel-pull strips another tree"
    # the key check reads the real channel's served keys whatever the tree: staging is signed with the same key
    chk = [s for s in steps if s.get("name", "").startswith("Check the signing key")][0]
    assert f"build/channel/{kind}/" in chk["run"], f"{p}: the key check does not read the real channel's keys"
print("ok   publish actions: staging/<kind> or <kind> from one input, in the assembly, the rebuild and the commit")
PY

# ---- the repository files a consumer installs
python3 -I - "$here" <<'PY'
import configparser, re, sys
here = sys.argv[1]
real = configparser.RawConfigParser(); real.read(f"{here}/packaging/openmixer-release/openmixer.repo")
stg = configparser.RawConfigParser(); stg.read(f"{here}/packaging/staging/openmixer-staging.repo")
assert stg.sections() == ["openmixer-staging", "openmixer-staging-noarch"], stg.sections()
for s in stg.sections():
    # channel-installability disables every system repository whose id starts with openmixer
    assert s.startswith("openmixer"), s
    c = stg[s]
    assert int(c.get("priority", "99")) < min(int(real[r].get("priority", "99")) for r in real.sections()), f"{s}: not above the real channel"
    assert c["baseurl"].startswith("https://www.openmixer.org/staging/rpm/fedora/$releasever/"), c["baseurl"]
    assert c["gpgcheck"] == "1" and c["repo_gpgcheck"] == "1", f"{s}: unsigned"
    assert c["gpgkey"] == real["openmixer"]["gpgkey"], f"{s}: another key file than the real channel's"
src = open(f"{here}/packaging/staging/openmixer-staging.sources.in").read()
real_src = open(f"{here}/packaging/openmixer-release/debian/openmixer.sources.in").read()
assert "URIs: https://www.openmixer.org/staging/deb/debian/@SUITE@/" in src, src
key = re.search(r"Signed-By: (\S+)", real_src).group(1)
assert f"Signed-By: {key}" in src, "the staging source trusts another keyring"
pref = open(f"{here}/packaging/staging/openmixer-staging.pref").read()
label = re.search(r"^Pin: release l=(\S+)$", pref, re.M).group(1)
prio = int(re.search(r"^Pin-Priority: (\d+)$", pref, re.M).group(1))
assert 500 < prio < 1000, f"pin priority {prio}: above the real channel (500), below a downgrade (1000)"
pub = open(f"{here}/.github/actions/publish-debs/action.yml").read()
purge = open(f"{here}/.github/actions/purge-staging/purge-staging.sh").read()
assert f"LABEL={label}" in pub and f"LABEL={label}" in purge, f"the staging index is not labelled {label}, the label the pin names"
print(f"ok   repository files: openmixer-staging* at priority 10 on staging/rpm; staging/deb pinned {prio} by label {label}")
PY

# ---- the purge workflow and its action
python3 -I - "$here/.github/workflows/purge-staging.yml" "$here/.github/actions/purge-staging/action.yml" <<'PY'
import sys, yaml
wf, act = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(wf)); on = d.get(True) or d.get("on")
assert "workflow_dispatch" in on and "workflow_call" in on, f"{wf}: not both dispatchable and callable"
assert on["workflow_dispatch"]["inputs"] == on["workflow_call"]["inputs"], f"{wf}: dispatch and call take different inputs"
kinds = []
for name, job in d["jobs"].items():
    s = [x for x in job["steps"] if "/actions/purge-staging@" in x.get("uses", "")]
    assert len(s) == 1, f"{wf}: job {name} does not run purge-staging once"
    kinds.append(s[0]["with"]["kind"])
    assert job["container"]["image"].startswith("fedora:" if kinds[-1] == "rpm" else "debian:"), f"{wf}: {name} in the wrong container"
    assert "-live" in job["concurrency"]["group"] or "'live'" in job["concurrency"]["group"], f"{wf}: {name} outside the publish group"
assert sorted(kinds) == ["deb", "rpm"], kinds
a = yaml.safe_load(open(act))
steps = a["runs"]["steps"]
push = [x for x in steps if "/actions/channel-push@" in x.get("uses", "")][0]
assert push["with"]["what"] == "staging/${{ inputs.kind }}", f"{act}: the purge commits {push['with']['what']}"
assert "purge-staging.sh" in push["with"]["rebuild"], f"{act}: a lost race does not purge again"
pull = [x for x in steps if "/actions/channel-pull@" in x.get("uses", "")][0]
assert pull["with"]["strip"] == "${{ inputs.kind == 'rpm' && 'staging/rpm' || 'none' }}", f"{act}: the pull strips {pull['with']['strip']}"
run = [x for x in steps if x.get("name") == "Purge the staging tree"][0]["run"]
assert ':(exclude)staging/$KIND' in run and "exit 1" in run, f"{act}: no guard against a change outside staging/<kind>"
print("ok   purge-staging: dispatch or call, rpm and deb, each committing staging/<kind> only behind its guard")
PY

# the purge guard, run as written: a checkout changed outside staging/<kind> is refused
step "$here/.github/actions/purge-staging/action.yml" - '^Purge the staging tree ' "$t/purge.sh" >/dev/null
mkdir -p "$t/g/bin" "$t/g/act"
printf '#!/bin/bash\n[ -z "${TOUCH:-}" ] || echo changed >> "build/channel/$TOUCH"\n' > "$t/g/act/purge-staging.sh"
chmod +x "$t/g/act/purge-staging.sh"
guard() { # <file the fake purge changes, or empty>
    rm -rf "$t/g/w"; mkdir -p "$t/g/w/build/channel/rpm" "$t/g/w/build/channel/staging/deb"
    (cd "$t/g/w/build/channel" && git init -q && echo a > rpm/a && echo b > staging/deb/b && git add -A &&
        git -c user.name=t -c user.email=t@example.org commit -qm seed)
    (cd "$t/g/w" && env GITHUB_ACTION_PATH="$t/g/act" GITHUB_ENV="$t/g/env" KIND=deb SKELETON= TOUCH="$1" bash -e "$t/purge.sh" 2>&1)
}
guard staging/deb/b >/dev/null || fail "the purge guard refused a change inside staging/deb"
err=$(guard rpm/a) && fail "the purge guard let a change of rpm/ through"
echo "$err" | grep -q 'outside staging/deb' || fail "the purge guard does not name what it refused: $err"
err=$(guard staging/rpm-x) && fail "the purge guard let a new file outside staging/deb through"
ok "the purge refuses a checkout changed outside staging/<kind>"

for f in "$here/.github/actions/add-openmixer/add-staging.sh" "$here/.github/actions/purge-staging/purge-staging.sh"; do
    bash -n "$f" || fail "syntax $f"
done
echo "staging-channel: all passed"
