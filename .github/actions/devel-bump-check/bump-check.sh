#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# bump-check.sh <kind> <version> <name> <package>...   (paths of the channel tree on stdin; run in the checkout)
#
# A change to a package carries its version bump (.github#289). When the channel root or staging holds <version> of a
# package of that kind (../release-preflight/already-served.sh, STAGING=true, KIND=<kind>, RELEASES as set), the head is
# judged against the commit that built the served version, BUILT (staging/<kind>/built/<name>/<version>.commit, read by
# the action): every path changed since it that can change a package (../package-paths/package-paths.sh, .github/**
# exempt, EXEMPT adding globs) is refused, named with the served version, because the merge would be red on devel too
# (release-preflight). A served version with no record of its build is refused by name: what changed since it cannot be
# told. A version published nowhere passes.
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
if [ -z "${BUILT:-}" ]; then
    echo "::error::v$version is published ($served), and staging/$kind/built/$name/$version.commit does not record the commit that built it: bump the version"
    exit 1
fi
mapfile -t touching < <(git diff --name-only "$BUILT" HEAD | "$here/../package-paths/package-paths.sh")
if [ "${#touching[@]}" = 0 ]; then
    echo "v$version is published, built by $BUILT, and nothing since changes a package (.github/** ${EXEMPT:-}): no version bump is needed"
    exit 0
fi
for p in "${touching[@]}"; do
    echo "::error::$p changes the package since $BUILT, and the head's version v$version is published already ($served): bump the version"
done
exit 1
