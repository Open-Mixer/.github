#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# wait.sh <channel repo> <commit>
#
# Wait until GitHub Pages has deployed <commit> of the channel repository, or a commit that contains it: the
# newest deployments of the github-pages environment are read, each with its latest status, and the wait ends
# when one is in state success and is that commit or ahead of it. Pages cancels a deployment when the next push
# arrives, so a later deployment may carry the commit. A deployment that failed, or none at all after
# REDEPLOY_AFTER seconds, makes it ask Pages for one more build (every REDEPLOY_AFTER seconds while not live).
# Pages builds are read too (pages/builds and pages/builds/latest): a build in status built of the commit, or of
# one ahead of it, counts as live even with no deployment record, and says so.
# After LIVE_TIMEOUT seconds (1800) it fails naming the deployment of the commit and its state.
# Env: CURL (default curl), GH_TOKEN or GITHUB_TOKEN, GITHUB_API_URL (default https://api.github.com),
# LIVE_TIMEOUT (1800), REDEPLOY_AFTER (300), POLL (20).
set -uo pipefail
repo=$1 commit=$2
CURL=${CURL:-curl} api=${GITHUB_API_URL:-https://api.github.com}
LIVE_TIMEOUT=${LIVE_TIMEOUT:-1800} REDEPLOY_AFTER=${REDEPLOY_AFTER:-300} POLL=${POLL:-20}
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}

get() { # get <path>: the JSON body, or nothing
    printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$token" |
        $CURL -fsSL -H @- "$api/repos/$repo/$1" 2>/dev/null
}

# sets live=1 when served; ours="id state" of the deployment of the commit ("none" when there is none);
# proof names the evidence ("deployment" or "build")
check() {
    local list id sha state rel bstate
    live= ours=none proof=
    list=$(get "deployments?environment=github-pages&per_page=10") || return 0
    while read -r id sha; do
        [ -n "$id" ] || continue
        state=$(get "deployments/$id/statuses?per_page=1" | jq -r '.[0].state // "none"' 2>/dev/null)
        [ -n "$state" ] || state=none
        [ "$sha" != "$commit" ] || { [ "$ours" != none ] || ours="$id $state"; }
        [ "$state" = success ] || continue
        if [ "$sha" = "$commit" ]; then live=1 proof=deployment; return 0; fi
        rel=$(get "compare/$commit...$sha" | jq -r '.status // ""' 2>/dev/null)
        case $rel in ahead|identical) live=1 proof=deployment; return 0 ;; esac
    done < <(jq -r '.[] | "\(.id) \(.sha)"' <<<"$list" 2>/dev/null)
    # Pages can build a commit without ever recording a deployment: a build in status built that is the commit,
    # or ahead of it, is evidence too
    while read -r bstate sha; do
        [ "$bstate" = built ] && [ -n "$sha" ] || continue
        if [ "$sha" = "$commit" ]; then live=1 proof=build; return 0; fi
        rel=$(get "compare/$commit...$sha" | jq -r '.status // ""' 2>/dev/null)
        case $rel in ahead|identical) live=1 proof=build; return 0 ;; esac
    done < <({ get "pages/builds/latest"; get "pages/builds?per_page=10"; } |
        jq -r 'if type == "array" then .[] else . end | select(type == "object") | "\(.status // "") \(.commit // "")"' 2>/dev/null)
}

request_build() { # never fails the wait
    if [ -z "$token" ]; then
        echo "::warning::no token (GH_TOKEN or GITHUB_TOKEN) -- not asking Pages for another build; still waiting"
        return 0
    fi
    local code
    code=$(printf 'Authorization: Bearer %s\nAccept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28\n' "$token" |
        $CURL -sS -o /dev/null -w '%{http_code}' -H @- -X POST "$api/repos/$repo/pages/builds") || code=000
    case $code in
        ""|2??) ;;
        403) echo "::warning::the Pages build request was refused (HTTP 403: the publish token cannot request a Pages build)" ;;
        *) echo "::warning::the Pages build request was refused (HTTP $code)" ;;
    esac
    return 0
}

start=$SECONDS next_redeploy=$REDEPLOY_AFTER
while :; do
    check
    if [ -n "$live" ]; then
        if [ "$proof" = build ]; then
            echo "pages: built $commit of $repo (build, no deployment record)"
        else
            echo "pages: $repo deployed $commit (deployment ${ours})"
        fi
        exit 0
    fi
    waited=$((SECONDS - start))
    if [ "$waited" -ge "$LIVE_TIMEOUT" ]; then
        set -- $ours
        if [ "$ours" = none ]; then
            echo "::error::after ${waited}s Pages has no deployment for $commit of $repo (the commit is pushed; the deployment never started)"
        else
            echo "::error::after ${waited}s Pages deployment $1 of $commit in $repo is '$2', not success (the commit is pushed; the deployment is not live)"
        fi
        exit 1
    fi
    if [ "$waited" -ge "$next_redeploy" ]; then
        case $ours in
            none|*" failure"|*" error"|*" inactive") echo "::warning::Pages deployment of $commit: $ours -- asking Pages to build the channel again"; request_build ;;
        esac
        next_redeploy=$((waited + REDEPLOY_AFTER))
    fi
    sleep "$POLL"
done
