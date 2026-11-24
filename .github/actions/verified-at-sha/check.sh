#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# verified-at-sha: a release builds only a commit our own verify passed.
#
#   check.sh <owner/repo> <sha>   read the commit's combined status and judge it
#   check.sh --judge <status.json> <owner/repo> <sha>   judge a status document already read (the self-test's door)
#   check.sh --self-test          each refused shape must go red, each green shape pass
#
# The verdict is the commit status `cluster/verify` that our cluster verify (a scan of every main tip and PR head of
# the release repositories) or a stage box posts on the exact sha. `cluster/verify (staged)`, the same verify run
# against the staging channel of a release wave, counts as well: the rule the release tooling applies to a PR head.
#   pass:   at least one of the two contexts is success, and neither is failure or error
#   refuse: either is failure or error (named); neither is present; only pending (a wait never passes here)
# A status that cannot be read (HTTP other than 200, a body that is not JSON) is a refusal too, never a pass.
# Env: GH_TOKEN (optional: a public repository's statuses read without one; a private one needs statuses: read),
#      GITHUB_API_URL (default https://api.github.com).
# Output: `VERIFIED-AT-SHA OK <repo>@<sha> <context>` and exit 0, or `::error::` naming the repository, the sha and
# the context, and exit 1.
set -euo pipefail

CONTEXTS='cluster/verify|cluster/verify (staged)'

judge() {  # judge <status.json> <repo> <sha>
  python3 -I - "$1" "$2" "$3" "$CONTEXTS" <<'PY'
import json, sys
path, repo, sha, contexts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split("|")
where = "%s@%s" % (repo, sha)
try:
    doc = json.load(open(path))
    statuses = doc["statuses"]
    assert isinstance(statuses, list)
except Exception as e:
    print("::error::the commit status of %s could not be read (%s): a release builds only a commit whose %s is "
          "success, and an unread status is not one" % (where, e, contexts[0])); sys.exit(1)
# the combined status carries the newest status per context; keep the first seen, should the API ever repeat one
seen = {}
for s in statuses:
    if isinstance(s, dict) and s.get("context") in contexts:
        seen.setdefault(s["context"], s.get("state", ""))
red = ["%s is %s" % (c, st) for c, st in sorted(seen.items()) if st in ("failure", "error")]
if red:
    print("::error::%s: %s. A release builds only a commit our verify passed; fix main and tag the fixed commit"
          % (where, ", ".join(red))); sys.exit(1)
green = [c for c in contexts if seen.get(c) == "success"]
if green:
    print("VERIFIED-AT-SHA OK %s %s" % (where, green[0])); sys.exit(0)
if seen:
    print("::error::%s: %s is %s, not success. A tag waits for the verify of its commit to finish green before it is "
          "pushed; re-run this release once it has" % (where, ", ".join(sorted(seen)), ", ".join(seen[c] for c in sorted(seen))))
else:
    print("::error::%s carries no %s status: no verify of this commit ran. Every merge to main is verified by the "
          "cluster; tag a verified commit, or verify this one and re-run" % (where, contexts[0]))
sys.exit(1)
PY
}

fetch() {  # fetch <repo> <sha> <out>: the combined status, or a refusal naming what answered
  local api=${GITHUB_API_URL:-https://api.github.com} code
  local auth=()
  [ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
  code=$(curl -s --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o "$3" -w '%{http_code}' \
    "${auth[@]}" -H "Accept: application/vnd.github+json" "$api/repos/$1/commits/$2/status?per_page=100") || code=000
  if [ "$code" != 200 ]; then
    echo "::error::the commit status of $1@$2 answered HTTP $code: a release builds only a commit whose cluster/verify is success, and an unread status is not one (a private repository's release.yml must grant statuses: read)"
    return 1
  fi
}

self_test() {
  local t rc
  t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  expect() {  # expect <rc> <what> <statuses json array>
    printf '{"state":"x","statuses":%s}' "$3" > "$t/s.json"
    rc=0; judge "$t/s.json" o/r 0123456789abcdef0123456789abcdef01234567 > "$t/out" 2>&1 || rc=$?
    [ "$rc" = "$1" ] || { echo "self-test FAILED: $2 (rc $rc, wanted $1)"; cat "$t/out"; exit 1; }
    grep -q 'o/r@0123456789abcdef0123456789abcdef01234567' "$t/out" || { echo "self-test FAILED: $2 does not name the sha"; cat "$t/out"; exit 1; }
  }
  expect 0 "cluster/verify success" '[{"context":"cluster/verify","state":"success"}]'
  expect 0 "cluster/verify (staged) success" '[{"context":"cluster/verify (staged)","state":"success"}]'
  expect 0 "success beside another context's failure" '[{"context":"lint","state":"failure"},{"context":"cluster/verify","state":"success"}]'
  expect 1 "no status at all" '[]'
  expect 1 "only another context, green" '[{"context":"ci/build","state":"success"}]'
  expect 1 "cluster/verify pending" '[{"context":"cluster/verify","state":"pending"}]'
  expect 1 "cluster/verify failure" '[{"context":"cluster/verify","state":"failure"}]'
  expect 1 "cluster/verify error" '[{"context":"cluster/verify","state":"error"}]'
  expect 1 "staged success, plain failure" '[{"context":"cluster/verify","state":"failure"},{"context":"cluster/verify (staged)","state":"success"}]'
  expect 1 "a near name is not the context" '[{"context":"cluster/verify-old","state":"success"}]'
  printf 'not json' > "$t/s.json"
  rc=0; judge "$t/s.json" o/r 0123456789abcdef0123456789abcdef01234567 > "$t/out" 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "self-test FAILED: an unreadable status passed"; exit 1; }
  echo "VERIFIED-AT-SHA self-test OK"
}

case "${1:-}" in
  --self-test) self_test ;;
  --judge) [ $# = 4 ] || { echo "usage: check.sh --judge <status.json> <owner/repo> <sha>" >&2; exit 2; }; judge "$2" "$3" "$4" ;;
  -h|--help|'') sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] || exit 2 ;;
  *)
    [ $# = 2 ] || { echo "usage: check.sh <owner/repo> <sha>" >&2; exit 2; }
    [[ $2 =~ ^[0-9a-f]{40}$ ]] || { echo "::error::'$2' is not a full commit sha: the verify is judged on the exact commit"; exit 1; }
    f=$(mktemp); trap 'rm -f "$f"' EXIT
    fetch "$1" "$2" "$f"
    judge "$f" "$1" "$2"
    ;;
esac
