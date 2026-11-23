#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The scan of every open pull request's commits for a subject with no blank line after it: against a stubbed gh it
# names the offender and exits 1, exits 0 when every commit is clean, exits 2 naming the call it could not read, skips
# an archived repository, and only ever reads. The rule is the checker's own: without it the scan is blind.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
scan=$here/tools/scan-open-pr-subjects.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$scan" ] || fail "no scan at $scan"

# a gh that answers from files: $FX/<words of the call joined by _>, every call logged; a missing file is an API error
mkdir -p "$tmp/bin" "$tmp/fx"
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$FX/calls"
case "$1 $2" in
  "repo list") f=repos_$3 ;;
  "pr list") f=prs_${4//\//_} ;;
  api\ *) f=${2%%\?*}; f=api_${f//\//_} ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 64 ;;
esac
[ -f "$FX/$f" ] || { echo "HTTP 403: API rate limit exceeded ($f)" >&2; exit 1; }
cat "$FX/$f"
STUB
chmod +x "$tmp/bin/gh"
run() { rc=0; out=$(FX=$tmp/fx PATH=$tmp/bin:$PATH "$scan" "$@" 2>"$tmp/err") || rc=$?; }
commits() { # file sha:message ... -> the pull request commits answer
  local f=$1 j='[]' c; shift
  for c in "$@"; do j=$(jq -c --arg s "${c%%:*}" --arg m "${c#*:}" '. + [{sha: $s, commit: {message: $m}}]' <<<"$j"); done
  echo "$j" > "$f"
}
bad=aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd; ok1=1111111111112222222222223333333333334444; ok2=5555555555556666666666667777777777778888
echo '[{"nameWithOwner":"OrgA/one","isArchived":false},{"nameWithOwner":"OrgA/old","isArchived":true}]' > "$tmp/fx/repos_OrgA"
echo '[{"nameWithOwner":"OrgB/two","isArchived":false}]' > "$tmp/fx/repos_OrgB"
echo '[{"number":7,"headRefOid":"x","baseRefName":"main"}]' > "$tmp/fx/prs_OrgA_one"
echo '[{"number":9,"headRefOid":"y","baseRefName":"main"}]' > "$tmp/fx/prs_OrgB_two"
commits "$tmp/fx/api_repos_OrgA_one_pulls_7_commits" "$bad:a change"$'\n'"its body starts on line 2" "$ok1:a clean change"$'\n\n'"its body"
commits "$tmp/fx/api_repos_OrgB_two_pulls_9_commits" "$ok2:a one-line change"

run OrgA OrgB
[ "$rc" = 1 ] || fail "an offending commit gave $rc, not 1: $out $(cat "$tmp/err")"
grep -qx "OrgA/one#7 ${bad:0:12}: a change" <<<"$out" || fail "the offender was not named: $out"
[ "$(grep -c '#' <<<"$out")" = 1 ] || fail "a clean commit was named: $out"
grep -q '2 repositories, 2 open pull requests, 3 commits, 1 offenders' <<<"$out" || fail "the count line is wrong: $out"
! grep -q 'OrgA_old\|OrgA/old' "$tmp/fx/calls" || fail "an archived repository was read"
# read-only: no call writes (a method, a field, or any gh verb but the three reads)
! grep -Eq -- '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |=|$)' "$tmp/fx/calls" || fail "the scan made a call that can write: $(cat "$tmp/fx/calls")"
! grep -Evq '^(repo list|pr list|api repos/[^ ]+/pulls/[0-9]+/commits)' "$tmp/fx/calls" || fail "the scan made a call that is not one of its three reads"

# clean: the same pull request without the offender
commits "$tmp/fx/api_repos_OrgA_one_pulls_7_commits" "$ok1:a clean change"$'\n\n'"its body"
run OrgA OrgB
[ "$rc" = 0 ] || fail "a clean scan gave $rc, not 0: $out $(cat "$tmp/err")"
grep -q '3 commits, 0 offenders\|2 commits, 0 offenders' <<<"$out" || fail "the clean count line is wrong: $out"

# unreadable: an API error is exit 2 and names the call, and is never a pass even beside an offender
commits "$tmp/fx/api_repos_OrgA_one_pulls_7_commits" "$bad:a change"$'\n'"its body starts on line 2"
rm "$tmp/fx/api_repos_OrgB_two_pulls_9_commits"
run OrgA OrgB
[ "$rc" = 2 ] || fail "an API error gave $rc, not 2"
{ grep -q 'OrgB/two#9' "$tmp/err" && grep -q 'rate limit' "$tmp/err"; } || fail "the unread call was not named: $(cat "$tmp/err")"
grep -q "OrgA/one#7 ${bad:0:12}" <<<"$out" || fail "the offender read before the error was not named"
rm "$tmp/fx/repos_OrgB"
run OrgA OrgB
{ [ "$rc" = 2 ] && grep -q 'OrgB' "$tmp/err"; } || fail "an unreadable organisation gave $rc, not 2"
echo "scan-open-pr-subjects: ok"
