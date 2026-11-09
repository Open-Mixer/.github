# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Every secret a release needs is set and not empty, and no workflow falls back from one secret to another
(`secrets.A || secrets.B` publishes under B when A was written empty, and nothing says so).
usage: check.py NAMES_SPACE_SEPARATED [workflow files...]; the values arrive as SECRETS_JSON (toJSON(secrets))."""
import json, os, re, sys

names = sys.argv[1].split()
bad = []
have = json.loads(os.environ.get("SECRETS_JSON") or "{}")
for n in names:
    if not have.get(n):
        bad.append(f"secret {n} is missing or empty")
fallback = re.compile(r"secrets\.[A-Za-z0-9_]+\s*\|\|")
for f in sys.argv[2:]:
    for i, line in enumerate(open(f), 1):
        if fallback.search(line):
            bad.append(f"{f}:{i}: falls back from one secret to another: {line.strip()}")
for b in bad:
    print("::error::" + b)
sys.exit(1 if bad else 0)
