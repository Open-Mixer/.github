#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The zita-convolver package carries Open-Mixer/plugin-qualify#29's fix: three guitarix plugins (gx_amp, gx_cabinet,
# gxmetal_head) crash in plugin-qualify's lifecycle step at 192 kHz in 128-frame blocks on the stock library, because a
# convolution level is set running inside its own thread, so a stop () and cleanup () before that thread is first
# scheduled free what it then uses. In a Fedora container, as root, with the OpenMixer channel reachable:
#   - the stock zita-convolver crashes in that cell (the positive control: a cell that never crashes proves nothing);
#   - ours, built through the pinned-rpms action from packaging/zita-convolver at the commit pins.txt pins, installed
#     over it, crashes in none of the runs;
#   - its Release sorts above the Fedora build it replaces, so dnf takes it.
# RUNS (default 10) runs per plugin, 30 lifecycles a run, each run under a 120 s wall clock.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runs=${RUNS:-10}
failures=0
ok() { echo "ok      $1"; }
bad() { echo "FAILED  $1"; failures=$((failures + 1)); }
M=/usr/libexec/plugin-qualify/lv2_measure

grep -qx 'retries=10' /etc/dnf/dnf.conf || echo 'retries=10' >> /etc/dnf/dnf.conf
dnf install -y -q --setopt=install_weak_deps=False "${OPENMIXER_CHANNEL:-https://www.openmixer.org}/rpm/openmixer-release.noarch.rpm" >/dev/null
dnf install -y -q --setopt=install_weak_deps=False plugin-qualify lv2-guitarix-plugins zita-convolver >/dev/null

# crashes: one line per plugin, "<plugin> <crashed runs>"
crashes() {
    local u n bad
    for u in gx_amp#GUITARIX gx_cabinet#CABINET gxmetal_head#metal_head; do
        bad=0
        for n in $(seq "$runs"); do
            ulimit -c 0
            timeout -s KILL 120 "$M" "http://guitarix.sourceforge.net/plugins/$u" 192000 128 30 3 >/dev/null 2>&1 || bad=$((bad + 1))
        done
        echo "$u $bad"
    done
}

stock=$(rpm -q zita-convolver)
before=$(crashes)
echo "$stock:"; sed 's/^/        /' <<< "$before"
if awk '{ s += $2 } END { exit !(s > 0) }' <<< "$before"; then ok "the stock $stock crashes in the 192 kHz / 128 cell (the positive control)"
else bad "the stock $stock does not crash in the cell: this check proves nothing here"; fi

out=$(mktemp -d)
if "$here/.github/actions/pinned-rpms/build.sh" "$out" zita-convolver > "$out/build.log" 2>&1; then ok "ours builds through pinned-rpms"
else bad "ours does not build through pinned-rpms:"; tail -5 "$out/build.log" | sed 's/^/        /'; fi
ours=$(rpm -q zita-convolver)
if [[ $ours == *.omx* ]]; then ok "ours is installed over the stock one: $ours"; else bad "the installed zita-convolver is not ours: $ours"; fi
if [ "$(rpm --eval "%{lua: print(rpm.vercmp('${ours#zita-convolver-}', '${stock#zita-convolver-}'))}")" = 1 ]; then
    ok "ours sorts above $stock"
else bad "ours ($ours) does not sort above $stock"; fi

after=$(crashes)
echo "$ours:"; sed 's/^/        /' <<< "$after"
if awk '{ s += $2 } END { exit !(s == 0) }' <<< "$after"; then ok "ours crashes in none of the runs"
else bad "ours still crashes"; fi

rm -rf "$out"
[ "$failures" = 0 ] && echo "zita-convolver-crash: ok" || echo "zita-convolver-crash: $failures failed"
exit $((failures > 0))
