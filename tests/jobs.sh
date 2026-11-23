#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The jobs helper (.github/actions/jobs/jobs.sh): the -j a heavy job builds with comes from the CPU quota of the
# cgroup it runs in, never from nproc, which in a container counts the HOST's cores (a 24-core node with fourteen
# runners of three CPUs each swamps when every job runs make -j24). Offline, over fixture cgroup trees:
#   A. cgroup v2, cpu.max "200000 100000" -> 2, whatever nproc says;
#   B. a quota that is not a whole CPU rounds up: "150000 100000" -> 2, "50000 100000" -> 1 (never 0);
#   C. nested cgroups: the tightest quota on the path from the job's cgroup to the root wins;
#   D. cgroup v1, cpu.cfs_quota_us 300000 over cpu.cfs_period_us 100000 -> 3;
#   E. no quota anywhere ("max", or -1 on v1): nproc, then the declared runner cap --max (or OMX_RUNNER_CPUS);
#   F. the cap bounds a quota too: a quota of 3 with --max 1 -> 1;
#   H. build-rpm and build-deb export the helper's count (RPM_BUILD_NCPUS, DEB_BUILD_OPTIONS parallel=);
#   G. sabotage: a copy of the helper that answers nproc must fail A, so this test can tell the two apart.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
helper=${JOBS_HELPER:-$here/.github/actions/jobs/jobs.sh}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }
[ -x "$helper" ] || { echo "FAIL no helper at $helper"; exit 1; }

# v2 tree: $1 dir, $2 the job's cgroup path, then path=cpu.max pairs
v2() { local d=$1 p=$2; shift 2; mkdir -p "$d/fs$p"; : > "$d/fs/cgroup.controllers"; printf '0::%s\n' "$p" > "$d/self"
       for kv in "$@"; do mkdir -p "$d/fs${kv%%=*}"; printf '%s\n' "${kv#*=}" > "$d/fs${kv%%=*}/cpu.max"; done; }
run() { local d=$1; shift; JOBS_NPROC=24 OMX_RUNNER_CPUS= "$helper" --cgroup-root "$d/fs" --proc-cgroup "$d/self" "$@"; }
expect() { local want=$1 what=$2; shift 2; local got; got=$(run "$@" 2>/dev/null) || got="exit $?"
           [ "$got" = "$want" ] && yes "$what: $got" || no "$what: got '$got', wanted $want"; }

v2 "$t/a" /job "/job=200000 100000";                      expect 2 "A. v2 quota of 2 CPUs (nproc 24)" "$t/a"
v2 "$t/b1" /job "/job=150000 100000";                     expect 2 "B. 1.5 CPUs rounds up" "$t/b1"
v2 "$t/b2" /job "/job=50000 100000";                      expect 1 "B. half a CPU is 1, never 0" "$t/b2"
v2 "$t/c" /pod/job "/pod=300000 100000" "/pod/job=max 100000"; expect 3 "C. the pod's quota above an unlimited job" "$t/c"
v2 "$t/c2" /pod/job "/pod=300000 100000" "/pod/job=100000 100000"; expect 1 "C. the tighter of pod and job" "$t/c2"
mkdir -p "$t/d/fs/cpu,cpuacct"; echo 300000 > "$t/d/fs/cpu,cpuacct/cpu.cfs_quota_us"; echo 100000 > "$t/d/fs/cpu,cpuacct/cpu.cfs_period_us"
printf '4:cpu,cpuacct:/\n' > "$t/d/self";                 expect 3 "D. v1 quota 300000/100000" "$t/d"
v2 "$t/e" /job "/job=max 100000";                         expect 24 "E. no quota: nproc" "$t/e"
                                                          expect 1 "E. no quota, --max 1" "$t/e" --max 1
got=$(OMX_RUNNER_CPUS=2 JOBS_NPROC=24 "$helper" --cgroup-root "$t/e/fs" --proc-cgroup "$t/e/self" 2>/dev/null || true)
[ "$got" = 2 ] && yes "E. no quota, OMX_RUNNER_CPUS=2: 2" || no "E. OMX_RUNNER_CPUS=2 gave '$got'"
v2 "$t/f" /job "/job=300000 100000";                      expect 1 "F. quota 3 capped by --max 1" "$t/f" --max 1

# H. the shared builders take their parallel jobs from the helper, never rpm's or debhelper's own count of the host
for a in build-rpm:RPM_BUILD_NCPUS build-deb:parallel=; do
  f=$here/.github/actions/${a%%:*}/action.yml
  if grep -q 'jobs/jobs.sh' "$f" && grep -q "${a#*:}" "$f" && grep -q 'max-jobs' "$f"; then yes "H. ${a%%:*} sizes its build by the jobs helper (${a#*:})"
  else no "H. ${a%%:*} does not take its parallel jobs from jobs/jobs.sh (${a#*:}, max-jobs)"; fi
done

# G. sabotage: the helper that every job had before, nproc, cannot pass A
if [ -z "${JOBS_SABOTAGE:-}" ]; then
  printf '#!/bin/sh\necho "${JOBS_NPROC:-$(nproc)}"\n' > "$t/nproc.sh"; chmod +x "$t/nproc.sh"
  if JOBS_HELPER="$t/nproc.sh" JOBS_SABOTAGE=1 bash "$0" >/dev/null 2>&1; then no "G. a helper answering nproc passed"; else yes "G. a helper answering nproc is red"; fi
fi
[ $fail = 0 ] && echo "jobs: every arm holds" || exit 1
