#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# channel-installability judges the real channel alone: a staged minor present only in the staging channel does not
# change its verdict, even on a machine that has the staging channel added (add-staging.sh), because the gate reads
# the tree it is handed (rpm/, never staging/rpm/) and disables every system repository whose id starts with
# openmixer. The arms, on a throwaway channel, offline:
#   - the real channel serves omx-lib 3.13.0 and omx-app, which needs omx-lib below 3.14. A release that brings
#     omx-tool with the same range is GREEN; one that brings omx-needs-new, which needs omx-lib 3.14 or later, is RED:
#     published alone it would not install;
#   - the same with omx-lib 3.14.0 staged in staging/rpm and the staging channel added as a consumer adds it: the same
#     two verdicts. The staged minor neither breaks the first nor rescues the second;
#   - the control: the same staging repository under ids the gate does not know (a leak) turns the second GREEN, so
#     the measurement can see a staged package when one reaches it.
# The gate is .github/actions/channel-installability/gate.py of this tree, else GATE, else the one on origin/main
# (the branch that carries it). Runs as root in a throwaway Fedora container: it rewrites /etc/yum.repos.d.
#
#   staging-installability.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "staging-installability.sh rewrites /etc/yum.repos.d of a throwaway container: run it as root there" >&2; exit 2; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
gate=$here/.github/actions/channel-installability/gate.py
if [ ! -f "$gate" ]; then
    if [ -n "${GATE:-}" ]; then gate=$GATE
    elif git -C "$here" show origin/main:.github/actions/channel-installability/gate.py > "$t/gate.py" 2>/dev/null; then gate=$t/gate.py
    else echo "channel-installability's gate.py is not in this tree, GATE is unset and origin/main is not fetched: not measured" >&2; exit 2
    fi
fi
for tool in rpmbuild createrepo_c dnf python3; do command -v $tool >/dev/null || fail "$tool is not installed"; done
dnf repoclosure --help >/dev/null 2>&1 || fail "dnf repoclosure is not installed (dnf5-plugins)"

ch=$t/channel
mk() { # <dir> <name> <version> <release> [requires]; a noarch package
    local d=$t/rb-$2-$3-$4
    mkdir -p "$d"
    { printf 'Name: %s\nVersion: %s\nRelease: %s\nSummary: t\nLicense: MIT\nBuildArch: noarch\n' "$2" "$3" "$4"
      [ -z "${5:-}" ] || printf 'Requires: %s\n' "$5"
      printf '%%description\nt\n%%files\n'; } > "$d/p.spec"
    rpmbuild -bb -D "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $2 $3"
    mkdir -p "$1"; mv "$d"/RPMS/noarch/*.rpm "$1/"
}
for a in x86_64 noarch; do mkdir -p "$ch/rpm/fedora/44/$a" "$ch/staging/rpm/fedora/44/$a"; done
mk "$ch/rpm/fedora/44/noarch" omx-lib 3.13.0 1.fc44
mk "$ch/rpm/fedora/44/noarch" omx-app 1.0 1.fc44 '(omx-lib >= 3.13 with omx-lib < 3.14)'
mk "$ch/staging/rpm/fedora/44/noarch" omx-lib 3.14.0 1.git5f455d3.fc44
mk "$t/new-ok" omx-tool 1.0 1.fc44 '(omx-lib >= 3.13 with omx-lib < 3.14)'
mk "$t/new-red" omx-needs-new 1.0 1.fc44 '(omx-lib >= 3.14 with omx-lib < 3.15)'
for d in rpm staging/rpm; do for a in x86_64 noarch; do createrepo_c -q "$ch/$d/fedora/44/$a"; done; done

# the system: no distribution repository (offline), the real channel as openmixer-release adds it
mkdir -p "$t/distro-repos"; mv /etc/yum.repos.d/*.repo "$t/distro-repos/" 2>/dev/null || true
sed "s|https://www.openmixer.org/|file://$ch/|" "$here/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo

verdict() { # <label> <new dir>: runs the gate as run.sh does (no --reposdir: the system's repositories), prints rc and verdict
    local rc=0
    python3 -I "$gate" rpm --channel "$ch/rpm" --fedora 44 --arch x86_64 --new-dir "$2" > "$t/$1.out" 2>&1 || rc=$?
    echo "$rc $(grep -o 'channel-installability rpm: [A-Z]*' "$t/$1.out" || echo none)"
}
green="0 channel-installability rpm: GREEN" red="1 channel-installability rpm: RED"
v=$(verdict real-ok "$t/new-ok"); [ "$v" = "$green" ] || { cat "$t/real-ok.out"; fail "omx-tool on the real channel alone: $v"; }
v=$(verdict real-red "$t/new-red"); [ "$v" = "$red" ] || { cat "$t/real-red.out"; fail "omx-needs-new on the real channel alone: $v"; }
grep -q 'omx-needs-new 1.0-1.fc44.noarch is new and does not install' "$t/real-red.out" || { cat "$t/real-red.out"; fail "the red verdict does not name omx-needs-new"; }
ok "on the real channel alone: omx-tool is GREEN, omx-needs-new (omx-lib >= 3.14) is RED"

BASE_URL=file://$ch "$here/.github/actions/add-openmixer/add-staging.sh" >/dev/null
dnf -q -y --disablerepo='*' --enablerepo='openmixer*' --setopt='*.repo_gpgcheck=0' makecache >/dev/null || fail "the staging channel does not load"
dnf repoquery --disablerepo='*' --enablerepo='openmixer*' --setopt='*.repo_gpgcheck=0' omx-lib > "$t/rq" 2>&1 || true; grep -q 'omx-lib-0:3.14.0-1.git5f455d3' "$t/rq" || { cat "$t/rq"; fail "the staged minor is not visible to dnf"; }
v=$(verdict staged-ok "$t/new-ok"); [ "$v" = "$green" ] || { cat "$t/staged-ok.out"; fail "a staged minor changed omx-tool's verdict to $v"; }
v=$(verdict staged-red "$t/new-red"); [ "$v" = "$red" ] || { cat "$t/staged-red.out"; fail "a staged minor changed omx-needs-new's verdict to $v"; }
grep -q '3\.14\.0' "$t/staged-ok.out" "$t/staged-red.out" && fail "the gate's report names the staged omx-lib 3.14.0"
ok "with omx-lib 3.14.0 staged and the staging channel added: the same two verdicts, GREEN and RED"

# the control: the staging repository under ids the gate does not disable reaches it, and the verdict changes
sed -e 's/^\[openmixer-staging\]/[leak-staging]/' -e 's/^\[openmixer-staging-noarch\]/[leak-staging-noarch]/' \
    /etc/yum.repos.d/openmixer-staging.repo > /etc/yum.repos.d/leak-staging.repo
rm /etc/yum.repos.d/openmixer-staging.repo
v=$(verdict leak "$t/new-red")
[ "$v" = "$green" ] || { cat "$t/leak.out"; fail "the control: a staged minor that reaches the gate left omx-needs-new at $v, so this test cannot see a leak"; }
ok "control: the same staging repository under ids the gate does not know turns omx-needs-new GREEN"
rm /etc/yum.repos.d/leak-staging.repo
mv "$t/distro-repos"/*.repo /etc/yum.repos.d/ 2>/dev/null || true
echo "staging-installability: all passed"
