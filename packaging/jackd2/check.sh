#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Prove the installed jackd2 releases what dead clients leave in the metadata store (jackaudio/jack2#988).
#
#   check.sh [deaths]        default 200, more than the 157 that exhaust the store on amd64 without the fix
#
# Runs as root in a Debian container with the jackd2 packages under test installed, plus gcc, libjack-jackd2-dev,
# db-util and procps. Starts jackd on the dummy backend without realtime, then opens a probe client (probe.c beside
# this script: a port and a property) and kills it with SIGKILL, <deaths> times, reading the "Mutex in-use count" of
# /dev/shm/jack_db-<uid> after each death. Then kills jackd with SIGKILL and starts it again over what it left.
#
# Exit 0, FIXED: no client failed to open, the in-use count after the last death is the one after the first, and a
# client opens after the restart. Exit 1, LEAK: anything else, naming the first death that failed (BDB2034) or the
# count that grew. Exit 2: the check could not run (no jackd, no probe).
set -uo pipefail

deaths=${1:-200}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
env_dir=/dev/shm/jack_db-$(id -u)
stat=$(command -v db_stat || command -v db5.3_stat) || { echo "check: no db_stat (apt-get install db-util)" >&2; exit 2; }
command -v jackd >/dev/null || { echo "check: no jackd installed" >&2; exit 2; }
gcc -O1 -o "$work/probe" "$here/probe.c" -ljack || { echo "check: the probe does not build" >&2; exit 2; }

inuse() { "$stat" -h "$env_dir" -x 2>/dev/null | awk '/Mutex in-use count/ {print $1}'; }
jackd_pid=
start_jackd() {
    # ready when its engine segment is newer than the start: a killed server leaves the old one behind
    touch "$work/start"
    sleep 0.1
    jackd --no-realtime -d dummy -r 48000 -p 256 >>"$work/jackd.log" 2>&1 &
    jackd_pid=$!
    for _ in $(seq 1 600); do
        [ /dev/shm/jack_default_"$(id -u)"_0 -nt "$work/start" ] && sleep 0.5 && return 0
        sleep 0.1
    done
    echo "check: jackd did not start" >&2
    tail -5 "$work/jackd.log" >&2
    exit 2
}
stop() { kill -9 "$jackd_pid" 2>/dev/null; wait "$jackd_pid" 2>/dev/null; }

pkill -9 -x jackd 2>/dev/null
rm -rf /dev/shm/jack*
dpkg-query -W -f='check: ${Package} ${Version}\n' jackd2 libjack-jackd2-0
start_jackd
echo "check: base in-use $(inuse)"

first= last= failed=
for i in $(seq 1 "$deaths"); do
    "$work/probe" "p$i" >"$work/probe.out" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
        grep -q READY "$work/probe.out" && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if ! grep -q READY "$work/probe.out" || grep -q 'BDB\|failed' "$work/probe.out"; then
        failed="client $i, after $((i - 1)) unclean deaths: $(tr '\n' ' ' <"$work/probe.out")"
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        break
    fi
    kill -9 "$pid"
    wait "$pid" 2>/dev/null
    sleep 0.2
    last=$(inuse)
    [ -n "$first" ] || first=$last
    [ $((i % 25)) = 0 ] && echo "check: $i deaths, in-use $last"
done

stop
start_jackd
after=$("$work/probe" restart close 2>&1 | tr '\n' ' ')
echo "check: after a SIGKILLed jackd and a restart, in-use $(inuse), client: $after"
stop

if [ -n "$failed" ]; then
    echo "check: LEAK, $failed"
    exit 1
fi
if [ "$last" != "$first" ]; then
    echo "check: LEAK, in-use $first after the first death, $last after the $deaths-th"
    exit 1
fi
case $after in
    *BDB*|*failed*) echo "check: LEAK, the client after the restart cannot use the metadata store"; exit 1 ;;
    *READY*CLOSED*) ;;
    *) echo "check: LEAK, no client opens after the restart"; exit 1 ;;
esac
echo "check: FIXED, $deaths deaths, in-use $first after each, a client opens after a restart"
