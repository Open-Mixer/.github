#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""ci_steps.py: which commands of a workflow's steps really run, and which can fail the job.

This is the frame only: every line of a `run:` value is taken as a command that runs and gates. The table in arms.yml is
red on it; the reader that meets the table follows.
"""
# what GitHub runs for a `shell:` value (workflow syntax, jobs.<job_id>.steps[*].shell); '' is a step with no shell
SHELL_TEMPLATES = {
    "": "bash -e {0}",
    "bash": "bash --noprofile --norc -eo pipefail {0}",
    "sh": "sh -e {0}",
}


def matches(cmd, want):
    """Whether a reported command is the wanted one: its command word (a path may be longer on the left), then every
    further wanted word among its arguments."""
    word = cmd["command"][2:] if cmd["command"].startswith("./") else cmd["command"]
    return (word == want[0] or word.endswith("/" + want[0])) and all(w in cmd["words"][1:] for w in want[1:])


def read(doc, path=""):
    jobs = []
    for job_id, job in (doc.get("jobs") or {}).items():
        steps = []
        for index, step in enumerate(job.get("steps") or [], 1):
            commands = []
            for number, line in enumerate(str(step.get("run", "")).splitlines(), 1):
                words = line.split()
                if words:
                    commands.append({"line": number, "command": words[0], "words": words, "runs": "always", "gates": True,
                                     "why": []})
            steps.append({"index": index, "name": step.get("name", ""), "read": True, "when": [], "commands": commands})
        jobs.append({"id": job_id, "when": [], "steps": steps})
    return {"workflow": path, "jobs": jobs}
