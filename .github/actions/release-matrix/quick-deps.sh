#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Refuse a full release built on a dependency the channel has for the quick set alone. A quick version exists for
# three cells; a full release on top of it would publish packages that the other cells cannot install, or that were
# built there against an older version than the one tested.
#
#   quick-deps.sh rpm|deb <cells.tsv: a file or an http(s) URL> [<installed list>]
#
# Run in the build container after the build installed its dependencies. Every installed package whose name and
# version the channel's cells.tsv (cells.sh) marks quick is named, and the run fails. <installed list> holds
# "<package> <version>" lines and replaces the question to rpm or dpkg (the tests use it).
# A channel that serves no cells.tsv yet (404) records no quick version: the check passes and says so. Any other
# failure to read it fails the run: a check that could not look is not a pass.
set -euo pipefail
kind=${1:?usage: quick-deps.sh rpm|deb <cells.tsv file or URL> [<installed list>]}
from=${2:?usage: quick-deps.sh rpm|deb <cells.tsv file or URL> [<installed list>]}
list=${3:-}
case $kind in rpm | deb) ;; *) echo "quick-deps.sh: rpm or deb, not '$kind'" >&2; exit 2 ;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

case $from in
http://* | https://*)
    code=$(curl -sSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o "$tmp/cells.tsv" -w '%{http_code}' "$from") ||
        { echo "::error::could not read $from" >&2; exit 1; }
    case $code in
    200) ;;
    404) echo "::notice::$from is not served yet: the channel records no quick version"; exit 0 ;;
    *) echo "::error::$from answered $code" >&2; exit 1 ;;
    esac
    ;;
*) [ -f "$from" ] || { echo "::error::no cells.tsv at $from" >&2; exit 1; }
    cp "$from" "$tmp/cells.tsv" ;;
esac
head -1 "$tmp/cells.tsv" | grep -q $'^# package\tversion\tset\tcells$' ||
    { echo "::error::$from is not a cells.tsv (its first line is not the header)" >&2; exit 1; }

if [ -n "$list" ]; then
    cp "$list" "$tmp/installed"
elif [ "$kind" = rpm ]; then
    rpm -qa --qf '%{NAME} %{VERSION}\n' > "$tmp/installed"
else
    # the upstream version, as cells.sh writes it: no epoch, no revision, no +git or ~git suffix
    dpkg-query -W -f '${Package} ${Version}\n' | sed -E 's/ [0-9]+:/ /; s/[+~]git.*$//; s/-[^-]*$//' > "$tmp/installed"
fi
[ -s "$tmp/installed" ] || { echo "::error::no installed package was listed" >&2; exit 1; }

bad=0
while IFS=$'\t' read -r n v s c; do
    [ "$s" = quick ] || continue
    grep -qxF -- "$n $v" "$tmp/installed" || continue
    echo "::error::this release is built on $n $v, which the channel has for the quick set alone ($c): release $n for the full matrix first"
    bad=$((bad + 1))
done < "$tmp/cells.tsv"
[ "$bad" = 0 ] || exit 1
echo "no installed package is a quick-only version of the channel ($(grep -c $'\tquick\t' "$tmp/cells.tsv" || true) quick version(s) recorded)"
