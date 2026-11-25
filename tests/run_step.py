#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""run_step.py <root> <file.yml> <job> <step> <out.sh> [name=value ...]

Writes the shell of one step of a workflow (or of a composite action, with <job> '-') to <out.sh>, so a test runs the
step's own text with stub tools on PATH instead of a copy of it. <step> is id=<id>, name=<name> or uses=<action dir>.

A run step is its body. A step that uses Open-Mixer/.github/.github/actions/<dir>@... or ./.github/actions/<dir> is the
run steps of that composite action, in order, each in a subshell of its own with GITHUB_ACTION_PATH set and its env
mapped from the step's with: (a value written as an expression is taken from the name=value arguments, by the input's
name; an input not given takes its default). The step's own env: is not evaluated: the test exports what it names.
"""
import os
import re
import shlex
import sys

import yaml


def find(steps, sel):
    key, _, want = sel.partition("=")
    hits = []
    for s in steps:
        if key == "uses":
            u = str(s.get("uses", ""))
            if re.search(rf"(?:^|/)actions/{re.escape(want)}(?:@|$)", u):
                hits.append(s)
        elif str(s.get(key, "")) == want:
            hits.append(s)
    if len(hits) != 1:
        sys.exit(f"run_step: {len(hits)} steps match {sel}")
    return hits[0]


def main():
    root, path, job, sel, out = sys.argv[1:6]
    given = dict(a.split("=", 1) for a in sys.argv[6:])
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    steps = doc["runs"]["steps"] if job == "-" else doc["jobs"][job]["steps"]
    step = find(steps, sel)
    if "run" in step:
        body = step["run"]
    else:
        m = re.search(r"actions/([A-Za-z0-9_.-]+)(?:@|$)", str(step.get("uses", "")))
        if not m:
            sys.exit(f"run_step: {sel} neither runs nor uses an action of this repository")
        adir = os.path.join(root, ".github", "actions", m.group(1))
        action = yaml.safe_load(open(os.path.join(adir, "action.yml"), encoding="utf-8"))
        inputs = {k: str((v or {}).get("default", "")) for k, v in (action.get("inputs") or {}).items()}
        for k, v in (step.get("with") or {}).items():
            v = str(v)
            inputs[k] = given[k] if "${{" in v and k in given else ("" if "${{" in v else v)
        inputs.update({k: v for k, v in given.items() if k in inputs})
        parts = []
        for s in action["runs"]["steps"]:
            if "run" not in s:
                continue
            env = []
            for k, v in (s.get("env") or {}).items():
                v = str(v)
                mm = re.fullmatch(r"\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}", v.strip())
                env.append(f"export {k}={shlex.quote(inputs.get(mm.group(1), '') if mm else v)}")
            parts.append("(\n" + f"export GITHUB_ACTION_PATH={shlex.quote(adir)}\n" + "\n".join(env) + "\n" + s["run"] + "\n) || exit $?\n")
        body = "".join(parts)
    with open(out, "w", encoding="utf-8") as h:
        h.write("#!/bin/bash\n" + body)


if __name__ == "__main__":
    main()
