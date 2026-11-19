#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The same-pass reader (.github/actions/same-pass), on throwaway repositories, run the way the action runs it: in the
# caller's checkout, with the dispatch list, the ref and the built commit as its inputs.
#   A. a .github/release-same-pass at the built commit gives its names, comments stripped;
#   B. a dispatch list given wins over the file;
#   C. no file at the built commit gives an empty list, and no error;
#   D. a name that is not a package name is refused by name, from the file and from the list;
#   E. a ref other than the built commit is fetched and its file read (the source-ref path);
#   F. a ref that cannot be fetched is refused by name;
#   G. sabotage: without the name rule an invalid name is accepted, so arm D is what catches it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
reader=$here/.github/actions/same-pass/same-pass.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
yes() { echo "ok   $*"; }
no() { echo "FAIL $*"; fail=1; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
# throwaway repositories only: their commits are not signed (the runner's and the desk's global signing is off here)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

# origin: one commit with the file (two names and a comment), one naming another package, one with no file, one
# carrying a name that is not a package name.
o=$t/origin
git init -q -b main "$o"
git -C "$o" config uploadpack.allowReachableSHA1InWant true
mkdir -p "$o/.github"
printf '%s\n' 'plugin-hostd   # the first' 'plugin-hostd-protocol' > "$o/.github/release-same-pass"
git -C "$o" add -A && git -C "$o" commit -qm one
sha1=$(git -C "$o" rev-parse HEAD)
printf '%s\n' 'other-pkg' > "$o/.github/release-same-pass"
git -C "$o" commit -qam two
sha2=$(git -C "$o" rev-parse HEAD)
git -C "$o" rm -q .github/release-same-pass && git -C "$o" commit -qm three
sha3=$(git -C "$o" rev-parse HEAD)
mkdir -p "$o/.github"
printf '%s\n' 'ok-pkg' 'BAD_Name' > "$o/.github/release-same-pass"
git -C "$o" add -A && git -C "$o" commit -qm four
sha4=$(git -C "$o" rev-parse HEAD)

ws=$t/ws
# at <sha>: the workspace at that commit, with what an earlier arm left behind removed
at() { git -C "$ws" checkout -qf "$1" && git -C "$ws" clean -qfd; }
git clone -q "$o" "$ws"
at "$sha1"

# run <script> <built sha> <list> <ref>: the reader in the workspace; sets rc, got (the list output), err (its messages)
run() {
  local script=$1 built=$2 list=$3 ref=$4 out e
  out=$t/out.$RANDOM; e=$t/err.$RANDOM; : > "$out"
  rc=0
  (cd "$ws" && env LIST="$list" REF="$ref" GITHUB_SHA="$built" GITHUB_OUTPUT="$out" bash "$script") >"$e" 2>&1 || rc=$?
  got=$(sed -n 's/^list=//p' "$out")
  err=$(cat "$e")
}

run "$reader" "$sha1" "" ""
if [ "$rc" = 0 ] && [ "$got" = "plugin-hostd plugin-hostd-protocol" ]; then yes "A. the file at the built commit gives its names"
else no "A. the file gives its names: rc=$rc list='$got' err='$err'"; fi

run "$reader" "$sha1" "pkg-one   pkg-two" ""
if [ "$rc" = 0 ] && [ "$got" = "pkg-one pkg-two" ]; then yes "B. the dispatch list wins over the file"
else no "B. the dispatch list wins: rc=$rc list='$got' err='$err'"; fi

at "$sha3"
run "$reader" "$sha3" "" ""
if [ "$rc" = 0 ] && [ -z "$got" ]; then yes "C. no file at the built commit gives an empty list"
else no "C. no file gives an empty list: rc=$rc list='$got' err='$err'"; fi

run "$reader" "$sha3" "" "$sha2"
if [ "$rc" = 0 ] && [ "$got" = "other-pkg" ]; then yes "E. a ref other than the built commit is fetched and read"
else no "E. the named ref is read: rc=$rc list='$got' err='$err'"; fi

at "$sha4"
run "$reader" "$sha4" "" ""
if [ "$rc" != 0 ] && [[ "$err" == *"'BAD_Name' is not a package name"* ]] && [ -z "$got" ]; then yes "D. an invalid name in the file is refused by name"
else no "D. an invalid name in the file is refused: rc=$rc list='$got' err='$err'"; fi

run "$reader" "$sha1" "ok-pkg Bad;Name" ""
if [ "$rc" != 0 ] && [[ "$err" == *"'Bad;Name' is not a package name"* ]]; then yes "D. an invalid name in the list is refused by name"
else no "D. an invalid name in the list is refused: rc=$rc err='$err'"; fi

run "$reader" "$sha1" "" "0000000000000000000000000000000000000001"
if [ "$rc" != 0 ] && [[ "$err" == *"cannot fetch source-ref"* ]]; then yes "F. a ref that cannot be fetched is refused by name"
else no "F. an unfetchable ref is refused: rc=$rc err='$err'"; fi

# G. sabotage: the name rule dropped from a copy of the reader, the invalid name is then accepted
# shellcheck disable=SC2016 # the sed pattern is literal text
sed 's/\[\[ "\$n" =~/[[ "x" =~/' "$reader" > "$t/sab.sh"
if cmp -s "$t/sab.sh" "$reader"; then no "G. sabotage: there is no name rule to drop"
else
  at "$sha4"
  run "$t/sab.sh" "$sha4" "" ""
  if [ "$rc" = 0 ] && [ "$got" = "ok-pkg BAD_Name" ]; then yes "G. sabotage: without the name rule BAD_Name is accepted, so D is what catches it"
  else no "G. sabotage: without the name rule the invalid name still refused: rc=$rc list='$got'"; fi
fi

exit "$fail"
