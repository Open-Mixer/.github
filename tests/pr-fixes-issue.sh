#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The pr-fixes-issue check over planted pull request bodies: red plants (no keyword, a keyword with no reference, a
# reference of another owner, a reference inside code), green plants (Fixes #12, closes Open-Mixer/omx-dsp#5, Resolves
# FreeREAC/libreac#81, several), exit 2 on an unreadable body, the workflow wiring (off by default, body by env) and one
# sabotage: a checker that accepts any owner is green on the foreign-owner plant, which the test catches.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/pr-fixes-issue
chk=$act/pr-fixes-issue.py
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# a fake gh answers `gh api repos/R/pulls/N -q .body` from $BODYFILE; the body is read from the API, as in the action
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/sh
[ "$1" = api ] && [ "$2" = repos/o/r/pulls/7 ] || { echo "gh: unexpected $*" >&2; exit 1; }
[ -f "$BODYFILE" ] || { echo "gh: HTTP 404" >&2; exit 1; }
cat "$BODYFILE"
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" BODYFILE="$tmp/body" PR_REPO=o/r
runc() { local s=$1; shift; printf '%s' "$1" > "$BODYFILE"; PR_NUMBER=7 python3 -I "$s" >"$tmp/out" 2>&1; }
red() { local rc=0; runc "$chk" "$2" || rc=$?; [ "$rc" = 1 ] || fail "red plant '$1' gave $rc: $(cat "$tmp/out")"; }
green() { runc "$chk" "$2" || fail "green plant '$1' refused: $(cat "$tmp/out")"; }

# red plants
red "empty body" ""
red "no keyword" "Adds the thing. See #12 for background."
red "keyword with no reference" "Fixes the build and closes the loop."
red "keyword, a number, no hash" "Fixes 12"
red "keyword then a bare owner/repo" "Fixes Open-Mixer/omx-dsp"
red "reference of another owner" "Fixes someone-else/repo#5"
red "another owner beside a good one" $'Fixes #12\nFixes evil/repo#9'
red "a fenced code block holds the reference" $'Notes\n```\nFixes #12\n```\n'
red "inline code holds the reference" 'Write `Fixes #12` in the body.'
red "an unclosed fence runs to the end" $'Intro\n```\nFixes #12'
red "keyword glued to a word" "Prefixes #12"
red "the number glued to a word" "Fixes #12abc"
runc "$chk" nothing || true; grep -q 'no closing reference' "$tmp/out" || fail "the missing piece is not named"
grep -q 'evil/repo#9 is not an Open-Mixer or FreeREAC reference' "$tmp/out" 2>/dev/null || { runc "$chk" $'Fixes evil/repo#9' || true; grep -q 'evil/repo#9 is not an Open-Mixer or FreeREAC reference' "$tmp/out" || fail "the foreign owner is not named: $(cat "$tmp/out")"; }

# green plants
green "Fixes #12" "Fixes #12"
green "closes a sibling" "closes Open-Mixer/omx-dsp#5"
green "Resolves FreeREAC" "Resolves FreeREAC/libreac#81"
green "any case" "FIXED #3"
green "owner in lower case" "Fixes open-mixer/omx-dsp#5"
green "FreeREAC in mixed case" "Fixes FreeReac/freereac#5"
red "another owner in lower case" "Fixes someone-else/repo#5"
green "a colon" "Resolves: #4"
green "in a paragraph" $'Adds a thing.\n\nCloses #12 and fixes Open-Mixer/omx-dsp#741.'
green "several, one other-owner-free list" $'Fixes #1\nFixes #2\nResolves FreeREAC/reac-pw#3'
green "a good reference after a code block" $'```\nFixes #99999\n```\nFixes #12'
green "CRLF line endings" $'Intro\r\nFixes #12\r\n'

# a body that cannot be read is exit 2, never a pass: no API answer, no pull request, no repository
rc=0; rm -f "$BODYFILE"; PR_NUMBER=7 python3 -I "$chk" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "no API answer gave $rc, not 2"
printf 'Fixes #1' > "$BODYFILE"
rc=0; PR_NUMBER= python3 -I "$chk" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "no pull request gave $rc, not 2"
rc=0; env -u PR_REPO PR_NUMBER=7 python3 -I "$chk" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "no repository gave $rc, not 2"

# the CURRENT body decides, not the event payload: the payload (PR_BODY, as an old run replays it) lacks the reference and the
# API has it -> green; the reverse -> red
printf 'Fixes #12' > "$BODYFILE"
rc=0; PR_NUMBER=7 PR_BODY="no reference" python3 -I "$chk" >/dev/null 2>&1 || rc=$?; [ "$rc" = 0 ] || fail "a fixed body stayed red ($rc)"
printf 'no reference now' > "$BODYFILE"
rc=0; PR_NUMBER=7 PR_BODY="Fixes #12" python3 -I "$chk" >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "a payload body hid an edit that removed the reference ($rc)"

# a hostile body is data: a shell metacharacter body is judged, never run
runc "$chk" '$(touch '"$tmp"'/pwned) `touch '"$tmp"'/pwned2` Fixes #1' || fail "a body with shell syntax was refused"
[ ! -e "$tmp/pwned" ] && [ ! -e "$tmp/pwned2" ] || fail "the body was executed"

# the workflow: its own reusable file, its job reads the API with pull-requests: read, the shared public-sources-check.yml
# declares no pull-requests permission (so every existing caller stays valid) and carries no trace of this check
python3 -I - "$here" <<'PY' || fail "workflow wiring"
import sys, yaml
h = sys.argv[1]
w = yaml.safe_load(open(h + "/.github/workflows/pr-fixes-issue.yml"))
assert "workflow_call" in w[True], list(w[True])
j = w["jobs"]["pr-fixes-issue"]
assert j["permissions"] == {"contents": "read", "pull-requests": "read"}, j.get("permissions")
assert w["permissions"] == {"contents": "read", "pull-requests": "read"}, w.get("permissions")
assert "pull_request" in j["if"], j["if"]
assert j["name"] == "the pull request body closes an issue", j["name"]
st = [s for s in j["steps"] if "pr-fixes-issue" in s.get("uses", "")][0]["with"]
assert st == {"number": "${{ github.event.pull_request.number }}"}, "no body is passed from the payload: " + str(st)
raw = open(h + "/.github/workflows/public-sources-check.yml").read()
ps = yaml.safe_load(raw)
assert ps["permissions"] == {"contents": "read"}, ps["permissions"]
assert "pull-requests" not in raw and "pr-fixes-issue" not in raw, "public-sources-check.yml carries the check or its permission"
for name, jj in ps["jobs"].items():
    assert "pull-requests" not in str(jj.get("permissions", "")), name
a = open(h + "/.github/actions/pr-fixes-issue/action.yml").read()
run = [l for l in a.splitlines() if l.strip().startswith("run:")]
assert len(run) == 1 and "inputs." not in run[0] and "event." not in run[0], run
assert "PR_NUMBER: ${{ inputs.number }}" in a and "PR_REPO: ${{ inputs.repository }}" in a and "GH_TOKEN: ${{ inputs.token }}" in a
assert "pull_request.body" not in a and "inputs.body" not in a
PY

# sabotage: a checker that accepts any owner is green on the foreign-owner plant; the red plant above catches it
sed 's/elif owner.lower() in OWNERS:/elif True:/' "$chk" > "$tmp/any-owner.py"
grep -q 'elif True:' "$tmp/any-owner.py" || fail "sabotage setup: the any-owner copy was not made"
runc "$tmp/any-owner.py" "Fixes someone-else/repo#5" || fail "sabotage setup: the any-owner copy should accept the foreign owner"
rc=0; runc "$chk" "Fixes someone-else/repo#5" || rc=$?
[ "$rc" = 1 ] || fail "the real checker accepted a foreign owner"
echo "sabotage: accepting any owner passes the foreign-owner plant (the red-plant assertion goes red on it); the real checker refuses it"
echo PASS
