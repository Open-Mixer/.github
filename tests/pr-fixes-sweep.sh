#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The pr-fixes-sweep classifier over a fixture (no network), the report it prints, and the workflow's read-only
# permissions. Sabotage: a classifier with no exempt branches lists main and the release lines, which the test names.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sw=$here/.github/actions/pr-fixes-sweep/sweep.py
wf=$here/.github/workflows/pr-fixes-sweep.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
NOW=2026-11-20T12:00:00Z

cat > "$tmp/fx.json" <<'JSON'
[
 {"repo": "Open-Mixer/a", "default_branch": "trunk",
  "issues": [
   {"number": 1, "title": "old, unlinked", "created_at": "2026-11-01T00:00:00Z", "linked_prs": 0},
   {"number": 2, "title": "old, linked", "created_at": "2026-11-01T00:00:00Z", "linked_prs": 1},
   {"number": 3, "title": "young, unlinked", "created_at": "2026-11-18T00:00:00Z", "linked_prs": 0},
   {"number": 4, "title": "exactly 7 days | pipe", "created_at": "2026-11-13T12:00:00Z", "linked_prs": 0}
  ],
  "open_pr_heads": ["lane/has-pr"],
  "branches": [
   {"name": "trunk", "message": "x"}, {"name": "main", "message": "x"}, {"name": "gh-pages", "message": "x"},
   {"name": "openmixer-v1", "message": "x"}, {"name": "release/3.1", "message": "x"}, {"name": "settle/190", "message": "x"},
   {"name": "lane/has-pr", "message": "no ref"},
   {"name": "lane/named-123-thing", "message": "no ref"},
   {"name": "fix/issue-45", "message": "no ref"},
   {"name": "lane/msg-ref", "message": "do it\n\nFixes #9"},
   {"name": "lane/msg-ref-owner", "message": "do it (FreeREAC/libreac#81)"},
   {"name": "lane/orphan", "message": "wip"},
   {"name": "lane/rev2", "message": "wip: sha 4abc123"},
   {"name": "lane/other-owner", "message": "see evil/x#5"}
  ]},
 {"repo": "FreeREAC/b", "default_branch": "main", "issues": [], "open_pr_heads": [], "branches": [{"name": "main", "message": ""}]},
 {"repo": "Open-Mixer/private", "error": "HTTP 404"}
]
JSON
"$sw" classify "$tmp/fx.json" --now $NOW > "$tmp/rep" || fail "the report run failed"
sec() { sed -n "/^## $1/,/^## /p" "$tmp/rep"; }
sec "Open issues" > "$tmp/iss"; sec "Branches" > "$tmp/br"

grep -q '^| Open-Mixer/a#1 | 2026-11-01 | old, unlinked |' "$tmp/iss" || fail "an old unlinked issue is not listed"
grep -q 'Open-Mixer/a#4 .*exactly 7 days \\| pipe' "$tmp/iss" || fail "an issue open exactly 7 days is not listed, or its pipe is not escaped"
! grep -q 'Open-Mixer/a#2' "$tmp/iss" || fail "a linked issue was listed"
! grep -q 'Open-Mixer/a#3' "$tmp/iss" || fail "a young issue was listed"
grep -q 'Open issues with no linked pull request for 7 days (2)' "$tmp/iss" || fail "issue count: $(head -1 "$tmp/iss")"

for b in lane/orphan lane/rev2 lane/other-owner; do grep -q "| Open-Mixer/a | $b |" "$tmp/br" || fail "$b is not listed"; done
for b in trunk main gh-pages openmixer-v1 release/3.1 settle/190 lane/has-pr lane/named-123-thing fix/issue-45 lane/msg-ref lane/msg-ref-owner; do
  ! grep -q "| $b |" "$tmp/br" || fail "$b was listed"
done
grep -q 'branches with no open pull request and no issue reference (3)\|Branches with no open pull request and no issue reference (3)' "$tmp/br" || fail "branch count: $(head -1 "$tmp/br")"
grep -q 'Open-Mixer/private' "$tmp/rep" && grep -q 'could not be read (1)' "$tmp/rep" || fail "an unreadable repository is not named"
grep -q '2 repositories read, 1 unreadable' "$tmp/rep" || fail "the read count is wrong"

# nothing readable is exit 2, never a green empty report
echo '[{"repo": "o/x", "error": "boom"}]' > "$tmp/none.json"
rc=0; "$sw" classify "$tmp/none.json" --now $NOW >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "an all-unreadable sweep gave $rc, not 2"

# the reader is read-only: every gh call in the script is `gh api` of a GraphQL query, and no mutation or write verb is spelled
! grep -nE 'mutation|-X |--method|DELETE|PATCH|POST|PUT|gh (issue|pr) ' "$sw" || fail "the script spells a write"
grep -q "'gh', 'api'" "$sw" || fail "sanity: the reader is not gh api"
grep -q 'time.sleep' "$sw" && grep -q '1.0 - ' "$sw" || fail "the reader is not paced to one call per second"

# the workflow declares read permissions only, a schedule and a manual dispatch, and no step writes
python3 -I - "$wf" <<'PY' || fail "workflow permissions"
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
perm = w["permissions"]
assert perm == {"contents": "read", "issues": "read", "pull-requests": "read"}, perm
assert "schedule" in w[True] and "workflow_dispatch" in w[True], list(w[True])
for name, j in w["jobs"].items():
    assert "permissions" not in j, "a job widens the permissions: " + name
    for s in j["steps"]:
        t = (s.get("run") or "") + (s.get("uses") or "")
        assert not any(x in t for x in ("gh issue", "gh pr", "gh label", "--method", "-X ", "DELETE", "POST", "PATCH")), t
PY

# sabotage: no exempt branches lists main and the release lines
sed 's/^EXEMPT = .*/EXEMPT = ()/' "$sw" > "$tmp/no-exempt.py"
grep -q '^EXEMPT = ()' "$tmp/no-exempt.py" || fail "sabotage setup: the copy was not made"
python3 -I "$tmp/no-exempt.py" classify "$tmp/fx.json" --now $NOW > "$tmp/rep2"
grep -q '| main |' "$tmp/rep2" && grep -q '| release/3.1 |' "$tmp/rep2" || fail "sabotage setup: main was not listed"
echo "sabotage: with no exempt branches main, openmixer-v1, release/* and settle/* are listed (the not-listed assertions go red on it)"
echo PASS
