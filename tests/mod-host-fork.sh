#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The OpenMixer fork of mod-host at its pin in .github/pins.txt: the tests of the fixes it carries pass, and the
# installed protocol library passes actions/mod-host-protocol/checks/framing-test.sh. Then each fix is taken out
# again and the check that guards it must fail: without the src/ part of #113 or of #116 framing-test.sh fails,
# without the src/ part of the bind-address change its bind check fails, without the src/ part of #112 the
# AddressSanitizer test of #112 (make utils-run) fails. Needs git, gcc, make, python3, pkg-config and libasan.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fetch=$here/../.github/actions/mod-host-protocol/fetch-source.sh
check=$here/../.github/actions/mod-host-protocol/checks/framing-test.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# the commits of the fork that carry each fix, by subject (a rewritten history keeps its subjects)
fix113='Split socket input into NUL-terminated commands (#113)'
fix116='protocol: the command table holds 128 commands, and one past it is refused out loud'
fixbind='socket: both ports listen on 127.0.0.1 unless told otherwise'
fix112='Do not read before an empty string when trimming spaces (#112)'

# the library of <tree>, installed into <tree>/prefix
install_lib() {
    make -s -C "$1" lib && make -s -C "$1" install-lib PREFIX="$1/prefix" LIBDIR="$1/prefix/lib"
}

# expect <exit status> <text the output must hold, or empty> <name> <command>...
expect() {
    local want=$1 text=$2 name=$3
    shift 3
    "$@" > "$work/out" 2>&1
    local got=$?
    if [ "$got" = "$want" ] && { [ -z "$text" ] || grep -qF -- "$text" "$work/out"; }; then
        echo "ok      $name"
    else
        cat "$work/out"
        echo "FAILED  $name: wanted exit $want${text:+ and \"$text\"}, got exit $got"
        failures=$((failures + 1))
    fi
}

"$fetch" "$work/all" || exit 1
install_lib "$work/all" || exit 1
expect 0 "" "the tests of #112 and #113, with every fix" make -s -C "$work/all/tests" utils-run socket-run
expect 0 "" "the protocol tests of the library, with every fix" make -s -C "$work/all" test-protocol test-protocol-commands
expect 0 "all passed" "the bind-address tests of the library, with every fix" make -s -C "$work/all/tests" bind-run
expect 0 "ok      command of exactly 1024 bytes" "the installed library carries #113" "$check" "$work/all/prefix"

"$fetch" "$work/without-113" "$fix113" || exit 1
install_lib "$work/without-113" || exit 1
expect 1 "FAILED  command of exactly 1024 bytes" \
    "sabotage: without the fix of #113 the framing test fails" "$check" "$work/without-113/prefix"

"$fetch" "$work/without-116" "$fix116" || exit 1
install_lib "$work/without-116" || exit 1
expect 1 "FAILED  65 commands registered" \
    "sabotage: without #116 the library refuses the 65th command" "$check" "$work/without-116/prefix"

"$fetch" "$work/without-bind" "$fixbind" || exit 1
install_lib "$work/without-bind" || exit 1
expect 1 "FAILED  default bind" \
    "sabotage: without the bind-address change the library listens on every address" "$check" "$work/without-bind/prefix"

"$fetch" "$work/without-112" "$fix112" || exit 1
expect 2 "AddressSanitizer: heap-buffer-overflow" \
    "sabotage: without the fix of #112 its AddressSanitizer test fails" make -s -C "$work/without-112/tests" utils-run

if [ "$failures" != 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
