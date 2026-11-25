#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# bump-check.sh <kind> <version> <name> <package>...   (paths of the channel tree on stdin; run in the checkout)
#
# A change to a package carries its version bump (.github#289). When the channel root or staging holds <version> of a
# package of that kind (../release-preflight/already-served.sh, STAGING=true, KIND=<kind>, RELEASES as set), the head is
# judged by ../package-paths/served-change.sh, as the merge to devel is (release-preflight): against BUILT, the commit
# that built it (staging/<kind>/built/<name>/<version>.commit, read by the action), or, with no record, the pull
# request's own change from CHANGE_BASE (merge-base of its base and head). Every path that can change a package is
# refused by name; exempt paths alone pass. A version published nowhere passes. EXEMPT is the bump-exempt at the merge base
# (the action, base-exempt.sh), and JUDGED names both values when the head's differs (.github#292).
set -euo pipefail
usage='usage: bump-check.sh <kind> <version> <name> <package>...'
kind=${1:?$usage}; version=${2:?$usage}; name=${3:?$usage}
shift 3
[ "$#" -gt 0 ] || { echo "::error::no package names: cannot tell whether v$version is published"; exit 1; }
here=$(dirname "$(readlink -f "$0")")
if out=$(KIND=$kind STAGING=true "$here/../release-preflight/already-served.sh" "v$version" "$@" 2>&1); then
    echo "v$version is published nowhere yet: a merge of this pull request publishes it"
    exit 0
fi
served=$(printf '%s\n' "$out" | sed -n 's/^::error::v[^ ]* is already served: \([^ ]*\).*/\1/p' | paste -sd' ')
[ -n "$served" ] || { printf '%s\n' "$out"; exit 1; }
echo "::notice::v$version is published already ($served)"
# the pull request is judged by the bump-exempt at its merge base: the action sets EXEMPT to it, and JUDGED names both
# values when the head's differs (base-exempt.sh, .github#292)
judged=${JUDGED:-}
[ -z "$judged" ] || echo "::notice::$judged: this pull request is judged by the base value; a changed bump-exempt takes effect once it is on devel"
"$here/../package-paths/served-change.sh" "$version" "staging/$kind/built/$name/$version.commit" "${BUILT:-}" "${CHANGE_BASE:-}" \
    "this pull request (merge-base..head)" || {
    echo "::error::v$version is published already ($served): a change to the package needs its version bump"
    [ -z "$judged" ] || echo "::error::$judged: judged by the base value, so the change above is packaged; land the bump-exempt change in a pull request that changes no packaged path"
    exit 1
}
