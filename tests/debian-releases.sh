#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Debian is trixie only (owner ruling 2026-11-28): promote-staged, purge-staging and promote-wave refuse a bookworm
# suite-matrix by name, through the one refusal release-matrix/debian-releases.sh (which matrix.sh applies to build-deb.yml
# and check-matrix), offline. Proves:
#   - the debian-releases action's run block, run as the runner runs it, refuses '["bookworm", "trixie"]' and
#     '["bookworm"]' by name (exit 2), passes '["trixie"]' and '[]', and refuses a value that is not a JSON array;
#   - each of the three workflows' FIRST job opens with the action on inputs.suite-matrix, before any other step, and
#     its suite-matrix default passes;
#   - sabotage: the action with a debian-releases.sh that passes everything lets bookworm through, and a workflow whose
#     first step is taken away is red here.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

# the action's run block, extracted from action.yml and run with the action path a runner gives it
python3 -I - "$here/.github/actions/debian-releases/action.yml" > "$t/run.sh" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])
PY
act() { # <action dir> <releases json>: rc, output in $t/out
  local rc=0; GITHUB_ACTION_PATH=$1 RELEASES=$2 bash "$t/run.sh" > "$t/out" 2>&1 || rc=$?; echo "$rc"
}
A=$here/.github/actions/debian-releases
for v in '["bookworm", "trixie"]' '["bookworm"]'; do
  [ "$(act "$A" "$v")" = 2 ] && grep -q "::error::Debian release 'bookworm' is not in the full matrix" "$t/out" || { cat "$t/out"; fail "$v is not refused by name"; }
done
[ "$(act "$A" '["trixie"]')" = 0 ] || { cat "$t/out"; fail "trixie is refused"; }
[ "$(act "$A" '[]')" = 0 ] || { cat "$t/out"; fail "an empty list is refused"; }
[ "$(act "$A" 'trixie')" = 2 ] && grep -q 'not a JSON array' "$t/out" || fail "a value that is not a JSON array passed"
ok "debian-releases: bookworm refused by name, trixie and [] pass, a non-array refused"

# sabotage: a debian-releases.sh that passes everything lets bookworm through
mkdir -p "$t/sab/release-matrix" "$t/sab/debian-releases"
cp "$here/.github/actions/release-matrix/full.txt" "$t/sab/release-matrix/"
printf '#!/bin/bash\nexit 0\n' > "$t/sab/release-matrix/debian-releases.sh"; chmod +x "$t/sab/release-matrix/debian-releases.sh"
[ "$(act "$t/sab/debian-releases" '["bookworm", "trixie"]')" = 0 ] || fail "sabotage: with the refusal passing everything, bookworm is still refused (the action refuses on its own)"
ok "sabotage: the action without the shared refusal lets bookworm through"

# the three workflows: the first job opens with the action on suite-matrix; its default passes
wired() { # <workflow file> -> one line per finding
  python3 -I - "$1" <<'PY'
import sys, yaml, json, re
p = sys.argv[1]; w = yaml.safe_load(open(p))
first = next(iter(w["jobs"]))
steps = w["jobs"][first].get("steps", [])
want = "Open-Mixer/.github/.github/actions/debian-releases@openmixer-v1"
s = steps[0] if steps else {}
if s.get("uses") != want or re.sub(r"\s", "", str(s.get("with", {}).get("releases", ""))) != "${{inputs.suite-matrix}}":
    print("%s: job %s does not open with debian-releases on inputs.suite-matrix" % (p, first))
d = w[True]["workflow_call"]["inputs"]["suite-matrix"]["default"]
if json.loads(d) != ["trixie"]:
    print("%s: suite-matrix default %s" % (p, d))
PY
}
for f in promote-staged purge-staging promote-wave; do
  out=$(wired "$here/.github/workflows/$f.yml"); [ -z "$out" ] || fail "$out"
done
ok "promote-staged, purge-staging and promote-wave open their first job with debian-releases on suite-matrix"
python3 -I - "$here/.github/workflows/purge-staging.yml" "$t/purge.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); j = next(iter(w["jobs"])); w["jobs"][j]["steps"].pop(0)
yaml.safe_dump(w, open(sys.argv[2], "w"))
PY
[ -n "$(wired "$t/purge.yml")" ] || fail "sabotage: purge-staging without its first step is not seen"
ok "sabotage: a workflow whose refusal step is taken away is red"
echo "debian-releases: all passed"
