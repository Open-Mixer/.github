#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# served-change.sh <version> <record> <built commit> <change base> <change label>   (run in the checkout, at HEAD)
#
# Judges a change to a tree whose <version> the channel already serves (.github#289), for a merge to devel
# (release-preflight) and a pull request into devel (devel-bump-check) alike:
#   - with a record of the build (<built commit>, read from <record>): the paths from that commit to HEAD;
#   - without one (a version published before the records): the change itself, <change base>..HEAD (a pull request:
#     the merge base of its base and head; a push: github.event.before). An empty, all-zero or unreachable base cannot
#     be judged and is refused by name.
# Every path that can change a package (package-paths.sh, EXEMPT as set) is refused, each named: the version needs its
# bump. Exempt paths alone pass, with a notice (naming the missing record when there is none). Exit 0 passes, 1 refuses.
set -euo pipefail
usage='usage: served-change.sh <version> <record> <built commit> <change base> <change label>'
version=${1:?$usage}; rec=${2:?$usage}; built=${3-}; base=${4-}; label=${5:?$usage}
here=$(dirname "$(readlink -f "$0")")
reach() { [ -n "$1" ] && [[ ! $1 =~ ^0+$ ]] && { git cat-file -e "$1^{commit}" 2>/dev/null || git fetch -q origin "$1" 2>/dev/null; }; }
if [ -n "$built" ]; then
    reach "$built" || { echo "::error::this checkout has no commit $built, which built the served v$version, and cannot fetch it"; exit 1; }
    from=$built since="since $built, the build of the served v$version"
else
    reach "$base" ||
        { echo "::error::v$version is served, $rec does not record the commit that built it, and $label cannot be read (its base is '${base:-none}'): bump the version"; exit 1; }
    from=$base since="in $label, and the served v$version has no build record ($rec)"
fi
changed=$(git diff --name-only "$from" HEAD | "$here/package-paths.sh")
if [ -n "$changed" ]; then
    while IFS= read -r p; do echo "::error::$p changes the package $since: bump the version"; done <<< "$changed"
    exit 1
fi
if [ -n "$built" ]; then
    echo "::notice::v$version is served, built by $built, and nothing since changes a package"
else
    echo "::notice::v$version is served and $rec does not record the commit that built it; $label changes no package (exempt paths alone)"
fi
