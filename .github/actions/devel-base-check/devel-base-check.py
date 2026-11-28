#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# devel-base-check.py [repo-root] | --self-test       (env OMX_HAS_DEVEL=true|false; unset, git ls-remote origin devel)
#
# Refuses, by file, job and step, every step of the calling repository that passes devel-channel to add-openmixer
# without devel-base. A wave stacked on a base wave (devel-chain.sh DC_BASE_CHANNEL sets the repository's
# OMX_DEVEL_BASE beside OMX_DEVEL_CHANNEL) is served only partly by its own tree: a step reading the wave's channel and
# not its base installs a package of the wave whose dependency only the base serves, and the install fails
# (plugin-hostd 0.22.4 of devel/n3 needs omx-clap-contract 0.36.0, which only devel/bc2 serves: omx-panel#287,
# plugin-qualify#207). Where devel-channel reads vars.OMX_DEVEL_CHANNEL, devel-base must be the same expression reading
# vars.OMX_DEVEL_BASE: the same condition, so a pull request into main reads no base where it reads no channel.
#
# In a repository with a devel branch every add-openmixer step reads the wave: a step passing neither devel-channel nor
# devel-base (a bare call, no with: at all, or devel-channel: '') installs from production only on a pull request into
# devel, and the wave stops on a package only the wave serves (plugin-db#104, fixed there in 69c55dd). Such a step is
# refused by name too. Whether the repository has a devel branch is OMX_HAS_DEVEL (true or false: the action asks the
# caller's origin, git ls-remote); unset, the checker asks the root's origin itself, and an origin it cannot read is
# exit 2, never a pass.
#
# Read: .github/workflows/*.y{a,}ml (every job's steps) and .github/actions/**/action.y{a,}ml (a composite action's
# steps). A step is an add-openmixer step when its uses names .github/actions/add-openmixer (the shared action at any
# ref, or the local ./.github/actions/add-openmixer).
# Exit 0 clean, 1 a step refused (each named), 2 nothing to read or a file that does not parse (an empty check proves
# nothing).
import glob
import os
import sys
import tempfile

try:
    import yaml
except ImportError:  # the runner image carries python3-yaml (no-local-copies' release-order.py reads it too)
    print("devel-base-check: python3-yaml is needed to read the workflows", file=sys.stderr)
    sys.exit(2)


def is_add_openmixer(uses):
    u = str(uses or "").split("@", 1)[0].rstrip("/")
    return u.endswith(".github/actions/add-openmixer")


def judge_steps(rel, where, steps, out, has_devel):
    for i, s in enumerate(steps or []):
        if not isinstance(s, dict) or not is_add_openmixer(s.get("uses")):
            continue
        name = s.get("name") or s.get("id") or f"#{i + 1}"
        w = s.get("with") or {}
        if not isinstance(w, dict):
            w = {}
        dc = str(w.get("devel-channel") or "").strip()
        db = str(w.get("devel-base") or "").strip()
        if dc == "":
            if has_devel:  # a bare call: on a pull request into devel it reads production only
                out.append(f"{rel}: {where} step {name!r}: add-openmixer reads no devel-channel and no devel-base in a repository "
                           "with a devel branch (a pull request into devel installs from production only)")
            continue  # no devel branch: no wave to read, so there is no base to read
        if db == "":
            out.append(f"{rel}: {where} step {name!r}: add-openmixer reads devel-channel {dc!r} without devel-base")
            continue
        if "OMX_DEVEL_CHANNEL" in dc:
            want = dc.replace("OMX_DEVEL_CHANNEL", "OMX_DEVEL_BASE")
            if db != want:
                out.append(f"{rel}: {where} step {name!r}: add-openmixer reads devel-channel {dc!r} but devel-base {db!r}, "
                           f"not the same expression reading vars.OMX_DEVEL_BASE ({want!r})")


def has_devel_branch(root):
    v = os.environ.get("OMX_HAS_DEVEL", "").strip().lower()
    if v in ("true", "false"):
        return v == "true"
    if v:
        print(f"devel-base-check: OMX_HAS_DEVEL is {v!r}, not true or false", file=sys.stderr)
        return None
    import subprocess
    p = subprocess.run(["git", "-c", f"safe.directory={root}", "-C", root, "ls-remote", "--heads", "origin", "refs/heads/devel"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"devel-base-check: cannot ask {root}'s origin whether it has a devel branch: {p.stderr.strip()}", file=sys.stderr)
        return None
    return p.stdout.strip() != ""


def check(root):
    has_devel = has_devel_branch(root)
    if has_devel is None:
        return 2
    files = sorted(set(glob.glob(os.path.join(root, ".github/workflows/*.yml"))
                       + glob.glob(os.path.join(root, ".github/workflows/*.yaml"))
                       + glob.glob(os.path.join(root, ".github/actions/**/action.yml"), recursive=True)
                       + glob.glob(os.path.join(root, ".github/actions/**/action.yaml"), recursive=True)))
    if not files:
        print(f"devel-base-check: no workflow or action under {root}/.github to read (refusing: an empty check proves nothing)",
              file=sys.stderr)
        return 2
    out, broken = [], []
    for f in files:
        rel = os.path.relpath(f, root)
        try:
            with open(f, encoding="utf-8") as fh:
                doc = yaml.safe_load(fh)
        except (yaml.YAMLError, UnicodeDecodeError) as e:
            broken.append(f"{rel}: does not parse: {str(e).splitlines()[0]}")
            continue
        if not isinstance(doc, dict):
            continue
        for jn, j in (doc.get("jobs") or {}).items():
            if isinstance(j, dict):
                judge_steps(rel, f"job {jn}", j.get("steps"), out, has_devel)
        runs = doc.get("runs")
        if isinstance(runs, dict):
            judge_steps(rel, "composite action", runs.get("steps"), out, has_devel)
    for line in broken:
        print(line, file=sys.stderr)
    for line in out:
        print(line)
    if out:
        print(f"devel-base-check: {len(out)} add-openmixer step(s) do not read both the wave's devel channel and its base waves "
              "(pass devel-channel: <condition> && vars.OMX_DEVEL_CHANNEL || '' and devel-base: the same expression with "
              "vars.OMX_DEVEL_BASE)", file=sys.stderr)
        return 1
    if broken:
        return 2
    print(f"devel-base-check: every add-openmixer step of {len(files)} file(s) reading devel-channel reads devel-base too"
          + (" (devel branch: every step reads both)" if has_devel else " (no devel branch: a step may read neither)"))
    return 0


GOOD = "${{ github.base_ref == 'devel' && vars.OMX_DEVEL_CHANNEL || '' }}"
BASE = "${{ github.base_ref == 'devel' && vars.OMX_DEVEL_BASE || '' }}"


def self_test():
    arms = [  # name, want rc, file (relative), yaml
        ("both", 0, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: {GOOD}
          devel-base: {BASE}
"""),
        ("no-base", 1, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - name: Add the channel
        uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: {GOOD}
"""),
        ("empty-base", 1, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: {GOOD}
          devel-base: ''
"""),
        ("other-condition", 1, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: {GOOD}
          devel-base: ${{{{ vars.OMX_DEVEL_BASE }}}}
"""),
        ("local-action", 1, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: ./.github/actions/add-openmixer
        with:
          devel-channel: {GOOD}
"""),
        ("composite", 1, ".github/actions/x/action.yml", """runs:
  using: composite
  steps:
    - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
      with:
        devel-channel: ${{ inputs.devel-channel }}
"""),
        ("output-pair", 0, ".github/workflows/ci.yml", """jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: ${{ needs.preflight.outputs.devel-channel }}
          devel-base: ${{ needs.preflight.outputs.devel-base }}
"""),
        ("no-channel", 0, ".github/workflows/ci.yml", """jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          staging: true
"""),
        ("empty-channel", 0, ".github/workflows/ci.yml", """jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: ''
"""),
        ("other-action", 0, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer-not@openmixer-v1
        with:
          devel-channel: {GOOD}
"""),
        ("comment-is-not-a-base", 1, ".github/workflows/ci.yml", f"""jobs:
  a:
    steps:
      - uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
        with:
          devel-channel: {GOOD}
          # devel-base: {BASE}
"""),
        ("broken-yaml", 2, ".github/workflows/ci.yml", "jobs: [\n"),
    ]
    BARE = """jobs:
  a:
    steps:
      - name: Add the OpenMixer channel
        uses: Open-Mixer/.github/.github/actions/add-openmixer@openmixer-v1
"""
    devel_arms = [  # the same, in a repository with a devel branch (OMX_HAS_DEVEL=true): every step reads both
        ("devel-bare", 1, ".github/workflows/ci.yml", BARE),
        ("devel-staging-only", 1, ".github/workflows/ci.yml", arms[7][3]),
        ("devel-empty-channel", 1, ".github/workflows/ci.yml", arms[8][3]),
        ("devel-bare-composite", 1, ".github/actions/x/action.yml", """runs:
  using: composite
  steps:
    - uses: ./.github/actions/add-openmixer
"""),
        ("devel-both", 0, ".github/workflows/ci.yml", arms[0][3]),
        ("devel-output-pair", 0, ".github/workflows/ci.yml", arms[6][3]),
        ("devel-no-base", 1, ".github/workflows/ci.yml", arms[1][3]),
        ("devel-other-action", 0, ".github/workflows/ci.yml", """jobs:
  a:
    steps:
      - uses: actions/checkout@v4
"""),
    ]
    nodevel_bare = [("nodevel-bare", 0, ".github/workflows/ci.yml", BARE)]
    cases = [(a, "false") for a in arms + nodevel_bare] + [(a, "true") for a in devel_arms]
    cases.append((("devel-word-not-a-boolean", 2, ".github/workflows/ci.yml", BARE), "yes"))
    fails = 0
    with tempfile.TemporaryDirectory() as t:
        saved = os.environ.get("OMX_HAS_DEVEL")
        for (name, want, rel, body), devel in cases:
            os.environ["OMX_HAS_DEVEL"] = devel
            d = os.path.join(t, name)
            os.makedirs(os.path.dirname(os.path.join(d, rel)), exist_ok=True)
            with open(os.path.join(d, rel), "w", encoding="utf-8") as fh:
                fh.write(body)
            with open(os.devnull, "w") as null:
                so, se = sys.stdout, sys.stderr
                sys.stdout = sys.stderr = null
                try:
                    rc = check(d)
                finally:
                    sys.stdout, sys.stderr = so, se
            if rc != want:
                print(f"self-test FAIL {name}: rc {rc}, want {want}", file=sys.stderr)
                fails += 1
        os.environ["OMX_HAS_DEVEL"] = "false"
        os.makedirs(os.path.join(t, "nothing"))
        with open(os.devnull, "w") as null:
            se = sys.stderr
            sys.stderr = null
            try:
                rc = check(os.path.join(t, "nothing"))
            finally:
                sys.stderr = se
        if saved is None:
            os.environ.pop("OMX_HAS_DEVEL", None)
        else:
            os.environ["OMX_HAS_DEVEL"] = saved
        if rc != 2:
            print(f"self-test FAIL nothing to read: rc {rc}, want 2", file=sys.stderr)
            fails += 1
    if fails:
        print(f"devel-base-check self-test: {fails} arm(s) failed", file=sys.stderr)
        return 1
    print(f"devel-base-check self-test green ({len(cases) + 1} arms)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    sys.exit(check(sys.argv[1] if len(sys.argv) > 1 else "."))
