#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# contract-bootstrap-line.sh <event> <ref name> <package> [<bootstraps file>]: the line of .github/contract-bootstraps.txt
# a run of contract-bootstrap.yml releases, as `package=`, `version=` and `entry=` lines (its outputs). A tag push names
# it by the tag, bootstrap-<package>-<version>, which must match a line exactly; any other run (a dry run) by <package>,
# which must be the package of exactly one line. A line that is not <package> <version> <owner>/<repo>@<full commit> is
# refused, and so is a version that is not a plain release (digits and dots).
set -euo pipefail
event=${1:?event} ref=${2:-} want=${3:-} file=${4:-$(dirname "$(readlink -f "$0")")/../contract-bootstraps.txt}
no() { echo "::error::contract-bootstrap: $*" >&2; exit 1; }
lines=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$file") || no "$file has no line"
while read -r p v s extra; do
  [ -z "$extra" ] && [[ $p =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*-contract$ ]] && [[ $v =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    && [[ $s =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ ]] || no "'$p $v $s${extra:+ $extra}' is not <package>-contract <version> <owner>/<repo>@<full commit>"
done <<< "$lines"
if [ "$event" = push ]; then
  [[ $ref == bootstrap-* ]] || no "tag $ref is not bootstrap-<package>-<version>"
  hit=$(awk -v t="$ref" '"bootstrap-" $1 "-" $2 == t' <<< "$lines")
  [ -n "$hit" ] || no "tag $ref names no line of ${file##*/}"
else
  [ -n "$want" ] || no "a dry run names the package"
  hit=$(awk -v p="$want" '$1 == p' <<< "$lines")
  [ "$(grep -c . <<< "$hit")" -eq 1 ] || no "${file##*/} has $(grep -c . <<< "$hit") lines for $want, not one"
fi
read -r p v s <<< "$hit"
printf 'package=%s\nversion=%s\nentry=%s:%s\n' "$p" "$v" "$s" "$p"
