#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Every publish-rpms (build-rpm.yml) and publish-debs (build-deb.yml) call tells the action where the CALLER's channel is
# served: served-url is <base-url>/rpm or <base-url>/deb. The actions default it to www.openmixer.org, so a FreeREAC dry
# run (base-url https://freereac.github.io) checked its packages' installability against the OpenMixer channel: reac-pw's
# fc45 build "needs libreac >= 1.11.0, which nothing meets" while FreeREAC's own channel serves libreac 1.11.0 for fc45.
# A planted call without served-url must be refused, or the check proves nothing.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
check() { # <workflow> <action> <family> -> prints offences
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys, yaml
path, action, fam = sys.argv[1:]
d = yaml.safe_load(open(path))
calls = [s for j in d["jobs"].values() for s in j.get("steps", [])
         if str(s.get("uses", "")).startswith("Open-Mixer/.github/.github/actions/%s@" % action)]
if not calls:
    print("%s: no %s call" % (path, action))
want = "${{ inputs.base-url }}/%s" % fam
for s in calls:
    got = (s.get("with") or {}).get("served-url")
    if got != want:
        print("%s: a %s call (%s) passes served-url %r, not %r" % (path, action, s.get("id", s.get("name", "unnamed")), got, want))
PY
}
fail=0
for t in "build-rpm publish-rpms rpm" "build-deb publish-debs deb"; do
    # shellcheck disable=SC2086 # three words, split on purpose
    set -- $t
    out=$(check "$here/../.github/workflows/$1.yml" "$2" "$3")
    [ -z "$out" ] || { echo "FAIL: $out" >&2; fail=1; }
done
# the planted pair: the same workflow with one served-url removed is refused
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
awk 'done || $0 != "          served-url: ${{ inputs.base-url }}/rpm" { print; next } { done = 1 }' \
    "$here/../.github/workflows/build-rpm.yml" > "$w/build-rpm.yml"
[ -n "$(check "$w/build-rpm.yml" publish-rpms rpm)" ] || { echo "NOT A RESULT: a publish-rpms call without served-url was accepted" >&2; exit 2; }
[ $fail = 0 ] || exit 1
echo "publish served-url: ok (every publish-rpms and publish-debs call reads the caller's own channel)"
