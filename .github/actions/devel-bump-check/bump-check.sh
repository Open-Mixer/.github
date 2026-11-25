#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# bump-check.sh <kind> <version> <changed paths file> <package>...   (paths of the channel tree on stdin)
#
# A pull request into devel that changes a package carries its version bump (.github#289): a merge to devel whose version
# is published already publishes nothing, so the change would never reach a channel. Exits 1, naming every changed path
# and the published file, when <changed paths file> holds a path outside EXEMPT while the channel root or staging holds
# <version> of a package of that kind (../release-preflight/already-served.sh, STAGING=true, KIND=<kind>, RELEASES as
# set). Which paths change a package is ../package-paths/package-paths.sh's (.github/** exempt, EXEMPT adding globs). A
# pull request that changes exempt paths alone passes without judging the version.
set -euo pipefail
kind=${1:?usage: bump-check.sh <kind> <version> <changed paths file> <package>...}
version=${2:?usage: bump-check.sh <kind> <version> <changed paths file> <package>...}
changed=${3:?usage: bump-check.sh <kind> <version> <changed paths file> <package>...}
shift 3
[ "$#" -gt 0 ] || { echo "::error::no package names: cannot tell whether v$version is published"; exit 1; }
here=$(dirname "$(readlink -f "$0")")
# the one definition of a change to a package: ../package-paths/package-paths.sh (.github/** plus EXEMPT)
mapfile -t touching < <("$here/../package-paths/package-paths.sh" < "$changed")
if [ "${#touching[@]}" = 0 ]; then
    echo "the pull request changes exempt paths alone (.github/** ${EXEMPT:-}): no version bump is needed"
    exit 0
fi
if out=$(KIND=$kind STAGING=true "$here/../release-preflight/already-served.sh" "v$version" "$@" 2>&1); then
    echo "v$version is published nowhere yet: a merge of this pull request publishes it"
    exit 0
fi
served=$(printf '%s\n' "$out" | sed -n 's/^::error::v[^ ]* is already served: \([^ ]*\).*/\1/p' | paste -sd' ')
for p in "${touching[@]}"; do
    echo "::error::$p changes the package, and the head's version v$version is published already ($served): bump the version, or a merge to devel publishes nothing"
done
exit 1
