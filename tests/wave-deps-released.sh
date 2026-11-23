#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# wave-deps' sibling lookup: a sibling whose wave branch is gone is released and skipped with a notice; one that cannot
# be read fails the run; one with the branch is kept with its head. Runs the action's own `key` step against a stand-in
# git, offline.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); base=${XDG_CACHE_HOME:-$HOME/.cache}; mkdir -p "$base"; T=$(mktemp -d "$base/wave-deps-test.XXXXXX"); trap 'rm -rf "$T"' EXIT; fail=0
python3 - "$here/.github/actions/wave-deps/action.yml" > "$T/key.sh" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))['runs']['steps']
print(next(s for s in steps if s.get('id') == 'key')['run'])
PY
mkdir -p "$T/bin" "$T/act"
cat > "$T/bin/git" <<'SH'
#!/bin/bash
case "$*" in
  *ls-remote*/kept.git*) printf 'abc123\trefs/heads/dedupe/all\n' ;;
  *ls-remote*/released.git*) : ;;
  *ls-remote*/broken.git*) exit 128 ;;
esac
SH
printf '#!/bin/bash\nexit 0\n' > "$T/act/build.sh"; printf 'x' > "$T/build-rpm.sh"; chmod +x "$T/bin/git" "$T/act/build.sh"
mkdir -p "$T/build-rpm" "$T/build-deb"; touch "$T/build-rpm/build-rpm.sh" "$T/build-deb/build-deb.sh" "$T/build-deb/render-changelog.sh"
run() { env -i PATH="$T/bin:/usr/bin:/bin" GITHUB_ACTION_PATH="$T/act" GITHUB_OUTPUT="$T/out" BRANCH=dedupe/all OWNER=o REPOS="$1" \
  bash -c "sleep() { :; }; export -f sleep; . $T/key.sh" > "$T/log" 2>&1; }
: > "$T/out"; if run "kept released"; then
  grep -qx 'repos=kept' "$T/out" || { echo "FAIL a released sibling is not dropped: $(grep repos= "$T/out")"; fail=1; }
  grep -q 'kept=abc123' "$T/out" || { echo "FAIL the kept sibling's head is missing"; fail=1; }
  grep -q 'notice::wave-deps: o/released has no dedupe/all: released' "$T/log" || { echo "FAIL no notice for the released sibling"; fail=1; }
else echo "FAIL a released sibling fails the run: $(tail -1 "$T/log")"; fail=1; fi
: > "$T/out"; if run "kept broken"; then echo "FAIL an unreadable sibling passes"; fail=1; fi
: > "$T/out"; run "released" && grep -qx 'repos=' "$T/out" || { echo "FAIL all released does not give an empty list"; fail=1; }
[ $fail = 0 ] && echo "wave-deps released siblings: ok"; exit $fail
