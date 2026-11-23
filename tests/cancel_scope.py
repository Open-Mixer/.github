# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""A superseded run is cancelled only on a pull request, never on a release.

Reads every workflow's concurrency blocks (the top-level one and each job's) and refuses any whose
cancel-in-progress can be true on a tag push, a workflow_dispatch or a release event. Only an absent key, a literal
false or an expression gated on github.event_name == 'pull_request' passes: a plain true, any other literal, an
expression with no such gate, or one that ORs the gate away is red, by file and block. Usage:
cancel_scope.py [--selftest] <repository root>"""
import os
import re
import sys
import tempfile

import yaml

GATED = re.compile(r"^github\.event_name\s*==\s*'pull_request'(\s*&&[^|]+)?$")


def verdict(value):
    """None when the value is safe on a release trigger, else the reason it is not."""
    if value is None or value is False:
        return None
    if isinstance(value, str):
        text = value.strip()
        m = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
        if m and GATED.match(m.group(1).strip()):
            return None
        if text.lower() == "false":
            return None
    return "cancel-in-progress %r can be true on a tag push, a dispatch or a release" % (value,)


def blocks(doc):
    if not isinstance(doc, dict):
        return
    if isinstance(doc.get("concurrency"), dict):
        yield "top level", doc["concurrency"]
    jobs = doc.get("jobs")
    for name, job in (jobs.items() if isinstance(jobs, dict) else []):
        if isinstance(job, dict) and isinstance(job.get("concurrency"), dict):
            yield "job " + str(name), job["concurrency"]


def scan(root):
    bad = []
    wf = os.path.join(root, ".github", "workflows")
    for fn in sorted(os.listdir(wf)) if os.path.isdir(wf) else []:
        if not fn.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(wf, fn), encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        for where, block in blocks(doc):
            why = verdict(block.get("cancel-in-progress"))
            if why:
                bad.append("%s (%s): %s" % (fn, where, why))
    return bad


def plant(root, name, text):
    d = os.path.join(root, ".github", "workflows")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
        fh.write(text)


def selftest():
    head = "on:\n  push:\n    tags: ['x-*']\n  workflow_dispatch:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps: []\n"
    cases = [
        ("literal-true", "concurrency:\n  group: g\n  cancel-in-progress: true\n", True),
        ("or-dispatch", "concurrency:\n  group: g\n  cancel-in-progress: ${{ github.event_name == 'pull_request' || github.event_name == 'pull_request_target' }}\n", True),
        ("ungated", "concurrency:\n  group: g\n  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}\n", True),
        ("or-true", "concurrency:\n  group: g\n  cancel-in-progress: ${{ github.event_name == 'pull_request' && true || true }}\n", True),
        ("literal-false", "concurrency:\n  group: g\n  cancel-in-progress: false\n", False),
        ("absent", "concurrency:\n  group: g\n", False),
        ("gated", "concurrency:\n  group: g\n  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n", False),
    ]
    for name, block, red in cases:
        for site in ("top", "job"):
            with tempfile.TemporaryDirectory() as t:
                if site == "top":
                    plant(t, "w.yml", block + head)
                else:
                    body = "".join("      " + line + "\n" for line in block.splitlines()[1:])
                    plant(t, "w.yml", "on:\n  push:\n    tags: ['x-*']\njobs:\n  a:\n    concurrency:\n" + body
                          + "    runs-on: ubuntu-latest\n    steps: []\n")
                got = bool(scan(t))
                if got != red:
                    sys.exit("selftest: %s at %s should be %s" % (name, site, "red" if red else "green"))
    print("cancel-scope selftest: %d planted forms seen correctly" % (len(cases) * 2))


def main(argv):
    args = argv[1:]
    if args and args[0] == "--selftest":
        selftest()
        return 0
    bad = scan(args[0] if args else ".")
    for line in bad:
        print("RED " + line)
    if bad:
        return 1
    print("cancel-scope: no concurrency block cancels on a release trigger")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
