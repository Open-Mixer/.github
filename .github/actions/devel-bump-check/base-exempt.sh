#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# base-exempt.sh <base commit> <caller workflow ref> <called workflow> <judged value> <base label> <judged label>
#   (run in the caller's checkout; prints value=... and differs=... lines)
#
# The bump-exempt a change is judged by is the one its caller's workflow file had at the BASE of the change, never one
# the change sets itself (.github#292, #294); errors go to stdout, which the caller prints: a pull request's merge base (devel-bump-check), a push's
# github.event.before (release-preflight), a promotion's recorded build (promote-staged). <caller workflow ref> is
# github.workflow_ref (owner/repo/<path>@<ref>); <called workflow> the reusable workflow whose with: carries the value
# (build-rpm.yml, build-deb.yml, promote-staged.yml), read by exempt-at.py beside this file. Prints value=<the base
# value> and differs=<a sentence naming both values, empty when they are the same>. An empty, all-zero or unreachable
# base commit, and a value exempt-at.py cannot read, are refused by name.
set -euo pipefail
usage='usage: base-exempt.sh <base commit> <caller workflow ref> <called workflow> <judged value> <base label> <judged label>'
commit=${1-}; ref=${2:?$usage}; called=${3:?$usage}; judged=${4-}; blabel=${5:?$usage}; jlabel=${6:?$usage}
here=$(dirname "$(readlink -f "$0")")
wf=${ref%%@*}; wf=${wf#*/*/}
if [ -z "$commit" ] || [[ $commit =~ ^0+$ ]] || ! { git cat-file -e "$commit^{commit}" 2>/dev/null || git fetch -q origin "$commit" 2>/dev/null; }; then
    echo "::error::the bump-exempt of $wf at $blabel ('${commit:-none}') cannot be read: that commit is not in this checkout"
    exit 1
fi
at=$(mktemp)
git show "$commit:$wf" > "$at" 2>/dev/null || rm -f "$at"
base=$(python3 -I "$here/exempt-at.py" "$at" "$called") || { echo "::error::the bump-exempt of $wf at $blabel ($commit) cannot be read"; exit 1; }
rm -f "$at"
read -r -a h <<< "$judged"; read -r -a b <<< "$base"
judged=${h[*]+"${h[*]}"} base=${b[*]+"${b[*]}"}
echo "value=$base"
if [ "$judged" != "$base" ]; then
    echo "differs=bump-exempt is '$base' at $blabel and '$judged' at $jlabel"
else
    echo "differs="
fi
