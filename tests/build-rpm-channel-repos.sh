#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# build-rpm.yml's "Show what the channel provides the build" asks dnf about the repositories of the release package it was told
# (openmixer: openmixer and openmixer-noarch; freereac: freereac alone), not always openmixer's: FreeREAC's build jobs failed with
# "No matching repositories for openmixer, openmixer-noarch". The dnf of the step is a recording stub.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
w=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
python3 -I - "$here/../.github/workflows/build-rpm.yml" "$w/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in d["jobs"].values() for s in j.get("steps", []) if s.get("name") == "Show what the channel provides the build"]
assert len(steps) == 1, f"{len(steps)} steps named so"
open(sys.argv[2], "w").write(steps[0]["run"])
PY
mkdir "$w/bin" "$w/etc"
printf '#!/bin/bash\necho "dnf $*" >> "%s/calls"\n' "$w" > "$w/bin/dnf"; chmod +x "$w/bin/dnf"
run() { # <release package> <repo file content>
    : > "$w/calls"; printf '%b' "$2" > "$w/etc/${1%-release}.repo"
    sed "s|/etc/yum.repos.d|$w/etc|g" "$w/step.sh" > "$w/run.sh"
    PATH=$w/bin:$PATH RELEASE_PACKAGE=$1 bash "$w/run.sh"
}
run openmixer-release '[openmixer]\n[openmixer-noarch]\n'
grep -q 'repoquery --repo openmixer --repo openmixer-noarch --whatprovides' "$w/calls" || fail "openmixer: $(cat "$w/calls")"
run freereac-release '[freereac]\n'
grep -q 'repoquery --repo freereac --qf' "$w/calls" || fail "freereac does not query its own repository: $(cat "$w/calls")"
! grep -q 'openmixer' "$w/calls" || fail "freereac queries an openmixer repository: $(cat "$w/calls")"
echo "build-rpm channel repos: ok"
