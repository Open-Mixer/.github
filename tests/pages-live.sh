#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# wait.sh of the pages-live action against a stub of the deployments REST API: a curl that answers from files and
# records the POSTs to the Pages builds endpoint. Arms: the commit's deployment is a success (green, no build
# asked); a later deployment that is ahead of the commit is a success (green); a deployment that is behind it is
# not; a deployment still in progress at the timeout (red, naming the deployment and its state); no deployment at
# all (red, and Pages is asked for a build); a failed deployment is followed by a new build that succeeds (green);
# a lagging deployment that turns success in time (green); no token (warned, still waits).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
wait_sh=$here/../.github/actions/pages-live/wait.sh
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
mkdir -p "$work/bin"
# $SITE_DIR/live answers until $SITE_DIR/redeployed exists or LIVE_AFTER reads were made; then $SITE_DIR/next does
cat > "$work/bin/curl" <<'STUB'
#!/bin/bash
url=${@: -1}; url=${url%%\?*}
case " $* " in *" -X POST "*)
    { echo "POST $url"; cat; } >> "$SITE_DIR/api.log"; touch "$SITE_DIR/redeployed"; exit 0 ;;
esac
n=$(( $(cat "$SITE_DIR/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SITE_DIR/reads"
f=${url#https://api.example/repos/Open-Mixer/channel/}; f=${f//\//_}
root=$SITE_DIR/live
if [ -d "$SITE_DIR/next" ] && { [ -e "$SITE_DIR/redeployed" ] || [ "$n" -gt "${LIVE_AFTER:-999999}" ]; }; then root=$SITE_DIR/next; fi
if [ -e "$root/$f" ]; then cat "$root/$f"; else echo "[]"; fi
STUB
chmod +x "$work/bin/curl"
export CURL=$work/bin/curl POLL=1 REDEPLOY_AFTER=2 LIVE_TIMEOUT=4 GH_TOKEN=test-token GITHUB_API_URL=https://api.example
C=cccccccc D=dddddddd

state() { # state <dir> <deployments json> <id:state>... : one tree of API answers
    local d=$1 list=$2; shift 2; mkdir -p "$d"
    echo "$list" > "$d/deployments"
    for s in "$@"; do printf '[{"state":"%s"}]\n' "${s#*:}" > "$d/deployments_${s%%:*}_statuses"; done
}
arm() { # arm <name> <expect ok|red> [pattern]
    local name=$1 dir=$work/$1 rc=0
    export SITE_DIR=$dir
    bash "$wait_sh" Open-Mixer/channel "$C" > "$dir/out.log" 2>&1 || rc=$?
    if [ "$2" = ok ]; then [ $rc = 0 ] || { cat "$dir/out.log"; fail "$name: expected green"; }
    else [ $rc != 0 ] || { cat "$dir/out.log"; fail "$name: expected red"; }; grep -q -- "$3" "$dir/out.log" || { cat "$dir/out.log"; fail "$name: no '$3'"; }; fi
    pass=$((pass + 1))
}

state "$work/served-at-once/live" "[{\"id\":11,\"sha\":\"$C\"}]" 11:success
arm served-at-once ok
[ ! -e "$work/served-at-once/api.log" ] || fail "served-at-once asked for a build it did not need"

state "$work/later-carries/live" "[{\"id\":12,\"sha\":\"$D\"},{\"id\":11,\"sha\":\"$C\"}]" 12:success 11:inactive
echo '{"status":"ahead"}' > "$work/later-carries/live/compare_$C...$D"
arm later-carries ok

state "$work/not-ahead/live" "[{\"id\":12,\"sha\":\"$D\"},{\"id\":11,\"sha\":\"$C\"}]" 12:success 11:in_progress
echo '{"status":"behind"}' > "$work/not-ahead/live/compare_$C...$D"
arm not-ahead red "deployment 11 of $C in Open-Mixer/channel is 'in_progress'"

state "$work/lagging/live" "[{\"id\":11,\"sha\":\"$C\"}]" 11:in_progress
arm lagging red "deployment 11 of $C in Open-Mixer/channel is 'in_progress'"
[ ! -e "$work/lagging/api.log" ] || fail "lagging: a deployment still in progress must not trigger another build"

state "$work/slow/live" "[{\"id\":11,\"sha\":\"$C\"}]" 11:in_progress
state "$work/slow/next" "[{\"id\":11,\"sha\":\"$C\"}]" 11:success
LIVE_AFTER=3 arm slow ok

state "$work/none/live" "[]"
arm none red "no deployment for $C"
grep -q '^POST https://api.example/repos/Open-Mixer/channel/pages/builds' "$work/none/api.log" || fail "none: Pages was not asked for a build"
grep -q '^Authorization: Bearer test-token' "$work/none/api.log" || fail "none: the build request carries no token"

state "$work/failed/live" "[{\"id\":11,\"sha\":\"$C\"}]" 11:failure
state "$work/failed/next" "[{\"id\":13,\"sha\":\"$C\"},{\"id\":11,\"sha\":\"$C\"}]" 13:success 11:failure
arm failed ok
grep -q '^POST .*/pages/builds' "$work/failed/api.log" || fail "failed: the build was not requested again"

state "$work/no-token/live" "[]"
(unset GH_TOKEN; arm no-token red "Pages has no deployment for $C")
grep -q '::warning::no token' "$work/no-token/out.log" || fail "no-token: no warning"
[ ! -e "$work/no-token/api.log" ] || fail "no-token: a build was requested without a token"
echo "ok   pages-live: $pass arms"
