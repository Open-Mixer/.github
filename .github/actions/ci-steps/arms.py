#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""arms.py: the reader held to its table (arms.yml, beside this file).

  arms.py               every row: what ci_steps.py says of tests/x.sh against the row's `want`; and, for a row that is
                        only a script, what the real shell does with it against the same `want` (the oracle), so the
                        table states the shell's behaviour and not an opinion of it. Exit 1 naming each row that fails.
  arms.py --reader F    the same rows against another reader file
"""
import argparse
import importlib.util
import os
import shlex
import subprocess
import sys
import tempfile
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = "tests/x.sh"
# the stub the oracle runs as tests/x.sh: it leaves a mark, and its last command's status is X_STATUS (so it fails the
# same way executed, sourced or exec'd)
STUB = '#!/bin/sh\necho ran >> "$MARK"\n[ "${X_STATUS:-0}" = 0 ]\n'


def load_reader(path):
    spec = importlib.util.spec_from_file_location("ci_steps_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def rows():
    with open(os.path.join(HERE, "arms.yml"), encoding="utf-8") as f:
        return yaml.safe_load(f)


def workflow_of(row):
    step = dict(row.get("step") or {})
    if "run" in row:
        step["run"] = row["run"]
    job = dict({"runs-on": "ubuntu-latest"}, **(row.get("job") or {}))
    job["steps"] = row.get("steps") or [step]
    return dict(row.get("workflow") or {}, jobs={"j": job})


def said(reader, row):
    """What the reader says of the target in the row's workflow, in the shape of `want`."""
    report = reader.read(workflow_of(row))
    hits, unread = [], False
    for job in report["jobs"]:
        for step in job["steps"]:
            unread = unread or step.get("read") is False
            for cmd in step["commands"]:
                if reader.matches(cmd, [TARGET]):
                    hits.append((job, step, cmd))
    if not hits:
        return "unread" if unread else "absent"
    if len(hits) > 1:
        return "%d commands match" % len(hits)
    job, step, cmd = hits[0]
    got = {"runs": cmd["runs"], "gates": cmd["gates"]}
    when = list(job.get("when") or []) + list(step.get("when") or [])
    if when:
        got["when"] = when
    return got


def execute(template, script, status, env):
    """Run the script as the runner would (the template is GitHub's for the row's shell), tests/x.sh being the stub.
    -> (exit status, whether the stub ran)"""
    with tempfile.TemporaryDirectory() as d:
        os.mkdir(os.path.join(d, "tests"))
        stub = os.path.join(d, "tests", "x.sh")
        with open(stub, "w", encoding="utf-8") as f:
            f.write(STUB)
        os.chmod(stub, 0o755)
        with open(os.path.join(d, "step.sh"), "w", encoding="utf-8") as f:
            f.write(script)
        mark = os.path.join(d, "mark")
        run_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "MARK": mark, "X_STATUS": str(status)}
        run_env.update(env)
        r = subprocess.run(shlex.split(template.replace("{0}", "step.sh")), cwd=d, env=run_env, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
        if "&" in script:  # a backgrounded stub may write its mark after the shell left
            deadline = time.monotonic() + 1.0
            while not os.path.exists(mark) and time.monotonic() < deadline:
                time.sleep(0.02)
        return r.returncode, os.path.exists(mark)


def oracle_applies(row):
    if row.get("oracle") is False or "run" not in row or row["want"] == "unread":
        return False
    if row.get("steps") or row.get("job") or row.get("workflow"):
        return False
    return set(row.get("step") or {}) <= {"shell"}


def oracle(reader, row):
    """-> '' when the real shell does what `want` says, else what it did instead."""
    want = row["want"]
    template = reader.SHELL_TEMPLATES.get((row.get("step") or {}).get("shell", ""), (row.get("step") or {}).get("shell"))
    env = (row.get("oracle") or {}).get("gates-env", {}) if isinstance(row.get("oracle"), dict) else {}
    if want == "absent" or want["runs"] == "never":
        for status in (0, 1):
            if execute(template, row["run"], status, env)[1]:
                return "the shell ran it"
        return ""
    if want["runs"] == "conditional":
        code, ran = execute(template, row["run"], 0, {})
        if ran or code != 0:
            return "the step did not go green without it (exit %d, ran: %s)" % (code, ran)
        if not env:
            return ""
    else:
        code, ran = execute(template, row["run"], 0, env)
        if not ran:
            return "the shell did not run it (exit %d)" % code
    code, ran = execute(template, row["run"], 1, env)
    if not ran:
        return "the shell did not run it when it was to fail (exit %d)" % code
    if (code != 0) != want["gates"]:
        return "its failure left the step with exit %d" % code
    return ""


def run_table(reader, quiet=False):
    """-> the rows that failed, as (arm, name, what)."""
    failed = []
    for row in rows():
        label = "arm %-2s %s" % (row["arm"], row["name"])
        got = said(reader, row)
        problems = []
        if got != row["want"]:
            problems.append("the reader says %s, the table wants %s" % (got, row["want"]))
        if oracle_applies(row):
            did = oracle(reader, row)
            if did:
                problems.append("ORACLE: the table wants %s, but %s" % (row["want"], did))
        for what in problems:
            failed.append((row["arm"], row["name"], what))
        if not quiet:
            print(("FAIL " if problems else "ok   ") + label + "".join("\n       " + p for p in problems))
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reader", default=os.path.join(HERE, "ci_steps.py"))
    args = ap.parse_args()
    table = rows()
    failed = run_table(load_reader(args.reader))
    arms = sorted({r["arm"] for r in table})
    red = sorted({f[0] for f in failed})
    print("ci-steps arms: %d rows in %d arms, %d rows with the oracle; %d failures in arms %s"
          % (len(table), len(arms), sum(1 for r in table if oracle_applies(r)), len(failed), red or "none"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
