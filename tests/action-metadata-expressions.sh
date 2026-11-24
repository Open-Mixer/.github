#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# The runner evaluates ${{ }} in an action's metadata, and in its name, description and input or output descriptions
# no context is available: `origin/${{ github.base_ref }}` in doc-gate's input description failed the action's load
# for its first caller ("Unrecognized named-value: 'github'", .github#275). An expression belongs only where one is
# evaluated in context: an input's default, an output's value, the steps under runs. The same holds for a reusable
# workflow's name and the descriptions of its workflow_call inputs, outputs and secrets.
#   1. every .github/actions/*/action.yml and every .github/workflows/*.yml, checked;
#   2. sabotage: a copy of doc-gate's action.yml with the expression put back in a description is refused by name.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
check() {
    python3 -I - "$@" <<'PY'
import sys, yaml
bad = []
def has(v): return isinstance(v, str) and "${{" in v
for p in sys.argv[1:]:
    d = yaml.safe_load(open(p))
    if not isinstance(d, dict): continue
    on = d.get("on", d.get(True))
    if "runs" in d:  # an action
        for k in ("name", "description", "author"):
            if has(d.get(k)): bad.append(f"{p}: {k}")
        for sect in ("inputs", "outputs"):
            for n, spec in (d.get(sect) or {}).items():
                if isinstance(spec, dict) and has(spec.get("description")): bad.append(f"{p}: {sect}.{n}.description")
    elif isinstance(on, dict) and isinstance(on.get("workflow_call"), dict):
        wc = on["workflow_call"]
        for sect in ("inputs", "outputs", "secrets"):
            for n, spec in (wc.get(sect) or {}).items():
                if isinstance(spec, dict) and has(spec.get("description")): bad.append(f"{p}: workflow_call.{sect}.{n}.description")
for b in bad: print(f"FAIL: {b} holds a ${{{{ }}}} expression: metadata is not evaluated in context, the action or workflow cannot load", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}
mapfile -t files < <(ls "$root"/.github/actions/*/action.yml "$root"/.github/workflows/*.yml)
[ "${#files[@]}" -gt 20 ] || { echo "FAIL: only ${#files[@]} files found to check" >&2; exit 1; }
check "${files[@]}"
echo "no expression in action or reusable-workflow metadata (${#files[@]} files): ok"
work=$(mktemp -d "${TMPDIR:-/tmp}/action-metadata.XXXXXX"); trap 'rm -rf -- "$work"' EXIT
python3 -I - "$root/.github/actions/doc-gate/action.yml" "$work/action.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); d["inputs"]["base"]["description"] = "the base ref (origin/${{ github.base_ref }})"
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
if check "$work/action.yml" 2> "$work/err"; then echo "FAIL: the sabotaged description passed" >&2; exit 1; fi
grep -q 'inputs.base.description holds' "$work/err" || { cat "$work/err"; echo "FAIL: the refusal does not name the field" >&2; exit 1; }
echo "sabotage: an expression in an input description is refused by name: ok"
