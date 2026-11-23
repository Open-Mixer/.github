#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# doc-gate (.github/actions/doc-gate): the shared documentation gate, proven on a scratch repository under a stand-in
# doxygen (its warnings a file, its pages written as doxygen names them) and then the real one: the set compare (a new
# row, a stale row, a swapped row, a duplicate, a missing last newline, continuation lines joined), --update only ever
# lower, --list; a missing Doxyfile, baseline or pin, another doxygen version, no doxygen, no log, no page, a run from
# a subdirectory, each refused by name; a header with no @file, an untracked header, @cond and @internal, each red by
# name; a Doxyfile that silences the gate red by key, a setting behind @INCLUDE read; against the base: a watched
# setting changed red by key with both values and the accept flag one-shot, a baseline row added red, a base without
# the gate named, an empty, unknown and stale remote base refused through resolve-base; the Python half: a ruff
# finding, every form of noqa counted by ruff, a changed ruff configuration, no ruff, no configuration; sabotage: a
# count compare passes the swap, no settings check passes EXTRACT_ALL; the real doxygen: documented headers of one
# name give no row, a dropped @return warns by name, a planted EXTRACT_ALL is read back. The job installs doxygen and
# ruff; their absence is red, by name.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/.github/actions/doc-gate/doc-gate.sh" --self-test
# the acceptance is a key (.github#120): the reusable workflow and the action pass nothing by default, never a boolean
# false, which the gate would read as a key given with nothing changed (red on every caller)
python3 -I - "$here" <<'PY'
import sys, yaml
h = sys.argv[1]
wf = yaml.safe_load(open(h + "/.github/workflows/doc-gate.yml"))
on = wf.get("on", wf.get(True))
i = on["workflow_call"]["inputs"]["accept-config-change"]
assert i["type"] == "string" and i["default"] == "", ("doc-gate.yml accept-config-change", i)
a = yaml.safe_load(open(h + "/.github/actions/doc-gate/action.yml"))["inputs"]["accept-config-change"]
assert a["default"] == "", ("action accept-config-change", a)
print("doc-gate: accept-config-change is a key, empty by default, in the workflow and the action")
PY
