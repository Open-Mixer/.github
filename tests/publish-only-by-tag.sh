#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Publish only by tagging (docs/release-operations.md): every job that signs or pushes to the channel, npm or a
# GitHub release must carry the tag condition, and no workflow a person can start by hand may take a publish input.
# Fails by name, workflow and job. Argument: the directory of workflows (default .github/workflows).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
exec python3 -I - "${1:-$here/.github/workflows}" <<'PY'
import sys, glob, os, re, json, yaml
TAG = "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
# what makes a job a publisher: the signing/pushing actions, a release upload, an npm publish
PUBLISHER = re.compile(r"actions/(publish-rpms|publish-debs|release-attach)\b|gh release (create|upload)|npm publish")
bad = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.yml'))):
    name = os.path.basename(path)
    doc = yaml.safe_load(open(path))
    on = doc.get(True, doc.get('on')) or {}
    if isinstance(on, dict) and 'workflow_dispatch' in on:
        for i in ((on['workflow_dispatch'] or {}).get('inputs') or {}):
            if 'publish' in i.lower():
                bad.append(f"{name}: workflow_dispatch input '{i}' can switch publishing on by hand")
    for job, body in (doc.get('jobs') or {}).items():
        text = json.dumps(body)
        if PUBLISHER.search(text) and TAG not in text:
            bad.append(f"{name}: job '{job}' publishes without the tag condition ({TAG})")
        for key, val in ((body.get('env') or {}).items()):
            if key == 'DO_PUBLISH' and TAG not in str(val):
                bad.append(f"{name}: job '{job}' DO_PUBLISH lacks the tag condition")
    if 'inputs.publish' in open(path).read() and isinstance(on, dict) and 'workflow_call' not in on:
        bad.append(f"{name}: reads inputs.publish but is not a called workflow")
for b in bad: print("FAIL " + b)
if bad: sys.exit(1)
print("ok   every publishing job runs only on a tag push; no dispatch input publishes")
PY
