#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# jobs.sh [--max N] [--cgroup-root DIR] [--proc-cgroup FILE]
# Prints the number of parallel jobs (make -j) a heavy job should run: the CPU quota of the cgroup it runs in, never
# nproc, which inside a container counts the HOST's cores. The quota is read from cgroup v2's cpu.max (or v1's
# cpu.cfs_quota_us over cpu.cfs_period_us) at the job's cgroup and every ancestor visible to it, the tightest winning,
# and rounded up (half a CPU is 1, never 0). With no quota visible it is nproc. The declared runner cap, --max or the
# environment's OMX_RUNNER_CPUS, bounds either: a job in a container whose cgroup namespace hides the runner pod's
# limit still builds within what the runner was given. Why it chose what it chose goes to stderr.
set -euo pipefail
root=/sys/fs/cgroup self=/proc/self/cgroup max=${OMX_RUNNER_CPUS:-}
while [ $# -gt 0 ]; do
  case $1 in
    --max) max=${2:-}; shift 2 ;;
    --cgroup-root) root=$2; shift 2 ;;
    --proc-cgroup) self=$2; shift 2 ;;
    *) echo "jobs.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
ceil() { awk -v q="$1" -v p="$2" 'BEGIN { n = int(q / p); if (n * p < q) n++; if (n < 1) n = 1; print n }'; }
nproc=${JOBS_NPROC:-$(nproc)}
best= seen=
walk() {  # $1 the hierarchy's mount, $2 the job's path in it, $3 v2|v1
  local d=$1${2%/} q p r
  while :; do
    if [ "$3" = v2 ] && [ -r "$d/cpu.max" ]; then
      read -r q p < "$d/cpu.max"
    elif [ "$3" = v1 ] && [ -r "$d/cpu.cfs_quota_us" ]; then
      q=$(cat "$d/cpu.cfs_quota_us"); p=$(cat "$d/cpu.cfs_period_us")
    else q=; fi
    if [ -n "$q" ] && [ "$q" != max ] && [ "$q" != -1 ]; then
      n=$(ceil "$q" "$p"); r=${d#"$1"}; seen="$seen ${r:-/}=$q/$p"
      { [ -z "$best" ] || [ "$n" -lt "$best" ]; } && best=$n
    fi
    [ "$d" = "$1" ] || [ "$d" = "${1%/}" ] && break
    d=$(dirname "$d"); case $d in "$1"*|"${1%/}") ;; *) break ;; esac
  done
}
if [ -e "$root/cgroup.controllers" ]; then
  path=$(sed -n 's/^0:://p' "$self" 2>/dev/null | head -1)
  walk "$root" "${path:-/}" v2
else
  line=$(grep -E '^[0-9]+:([^:]*,)?cpu(,[^:]*)?:' "$self" 2>/dev/null | head -1 || true)
  ctl=$(echo "$line" | cut -d: -f2); path=$(echo "$line" | cut -d: -f3-)
  for m in "$root/$ctl" "$root/cpu,cpuacct" "$root/cpu"; do [ -d "$m" ] && { walk "$m" "${path:-/}" v1; break; }; done
fi
n=${best:-$nproc}
cap=
if [ -n "$max" ]; then cap=$(ceil "$max" 1); [ "$cap" -lt "$n" ] && n=$cap; fi
echo "jobs: $n (cgroup quota:${seen:- none visible}; nproc $nproc; runner cap ${cap:-none})" >&2
echo "$n"
