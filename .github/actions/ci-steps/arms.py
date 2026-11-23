#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""arms.py: the reader held to its table (arms.yml, beside this file).

  arms.py               every row: what ci_steps.py says of tests/x.sh against the row's `want`; and, for a row that is
                        only a script, what the real shell does with it against the same `want` (the oracle), so the
                        table states the shell's behaviour and not an opinion of it. Exit 1 naming each row that fails.
  arms.py --reader F    the same rows against another reader file
  arms.py --sabotage    the sabotage rows (sabotage.yml): each breaks the reader's handling of an arm in a copy of the
                        reader, and the table must go red in that arm; exit 1 naming each break the table did not see
"""
import argparse
import importlib.util
import os
import resource
import shlex
import signal
import subprocess
import sys
import tempfile
import time

import yaml

sys.dont_write_bytecode = True  # the reader is loaded from its file: leave no cache beside it
HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = "tests/x.sh"
# the stub the oracle runs as tests/x.sh: it leaves a mark, and its last command's status is X_STATUS (so it fails the
# same way executed, sourced or exec'd)
STUB = '#!/bin/sh\necho ran >> "$MARK"\n[ "${X_STATUS:-0}" = 0 ]\n'


MEMORY, SECONDS = 256 << 20, 10  # what reading one step may use: an input past it is to be refused by name


def guarded(fn, *args):
    """fn(*args) with the address space capped at MEMORY above what the process holds and SECONDS of wall time."""
    def late(signum, frame):
        raise TimeoutError()
    held = resource.getrlimit(resource.RLIMIT_AS)
    with open("/proc/self/statm", encoding="ascii") as f:
        used = int(f.read().split()[0]) * os.sysconf("SC_PAGE_SIZE")
    resource.setrlimit(resource.RLIMIT_AS, (used + MEMORY, held[1]))
    old = signal.signal(signal.SIGALRM, late)
    signal.alarm(SECONDS)
    try:
        return fn(*args)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)
        resource.setrlimit(resource.RLIMIT_AS, held)


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
    if "gen" in row:  # an adversarial input too big or deep to write out: `gen: [text, times, tail]`
        text, times, tail = row["gen"]
        row = dict(row, run=text * times + tail)
    if "run" in row:
        step["run"] = row["run"]
    job = dict({"runs-on": "ubuntu-latest"}, **(row.get("job") or {}))
    job["steps"] = row.get("steps") or [step]
    return dict(row.get("workflow") or {}, jobs={"j": job})


def said(reader, row):
    """What the reader says of the target in the row's workflow, in the shape of `want`."""
    try:
        report = guarded(reader.read, workflow_of(row))
    except (MemoryError, RecursionError, TimeoutError) as e:
        return "died: %s (the reader must refuse by name, within %d MiB and %d s)" % (
            type(e).__name__, MEMORY >> 20, SECONDS)
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


def run_table(reader, quiet=False, with_oracle=True):
    """-> the rows that failed, as (arm, name, what)."""
    failed = []
    for row in rows():
        label = "arm %-2s %s" % (row["arm"], row["name"])
        got = said(reader, row)
        problems = []
        if got != row["want"]:
            problems.append("the reader says %s, the table wants %s" % (got, row["want"]))
        if with_oracle and oracle_applies(row):
            did = oracle(reader, row)
            if did:
                problems.append("ORACLE: the table wants %s, but %s" % (row["want"], did))
        for what in problems:
            failed.append((row["arm"], row["name"], what))
        if not quiet:
            print(("FAIL " if problems else "ok   ") + label + "".join("\n       " + p for p in problems))
    return failed


def sabotage(source):
    """Each break of sabotage.yml on a copy of the reader's source.
    -> the rows the table did not see, as (arm, name, why)."""
    with open(os.path.join(HERE, "sabotage.yml"), encoding="utf-8") as f:
        breaks = yaml.safe_load(f)
    missed = []
    for b in breaks:
        label = "arm %-2s %s" % (b["arm"], b["name"])
        edits = b.get("edits") or [[b["old"], b["new"]]]
        bad = [old for old, _ in edits if source.count(old) != 1]
        if bad:
            missed.append((b["arm"], b["name"], "the text to break occurs not once"))
            print("FAIL " + label + "\n       the text to break occurs not once: %r" % bad[0])
            continue
        broken = source
        for old, new in edits:
            broken = broken.replace(old, new)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "ci_steps_broken.py")
            with open(path, "w", encoding="utf-8") as f:
                f.write(broken)
            try:
                red = sorted({r[0] for r in run_table(load_reader(path), quiet=True, with_oracle=False)})
            except Exception as e:  # a break that crashes the reader is red too, but say so
                red = [b["arm"]]
                label += " (the reader raised %s)" % type(e).__name__
        if b["arm"] in red:
            print("red  %s  [arms red: %s]" % (label, ", ".join(map(str, red))))
        else:
            missed.append((b["arm"], b["name"], "the table stayed green in the arm"))
            print("FAIL %s\n       the table stayed green in the arm (red: %s)" % (label, red or "none"))
    return missed


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reader", default=os.path.join(HERE, "ci_steps.py"))
    ap.add_argument("--sabotage", action="store_true")
    args = ap.parse_args()
    if args.sabotage:
        with open(args.reader, encoding="utf-8") as f:
            missed = sabotage(f.read())
        print("ci-steps sabotage: %d breaks not seen" % len(missed))
        sys.exit(1 if missed else 0)
    table = rows()
    failed = run_table(load_reader(args.reader))
    arms = sorted({r["arm"] for r in table})
    red = sorted({f[0] for f in failed})
    print("ci-steps arms: %d rows in %d arms, %d rows with the oracle; %d failures in arms %s"
          % (len(table), len(arms), sum(1 for r in table if oracle_applies(r)), len(failed), red or "none"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
