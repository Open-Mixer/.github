#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A pull request into devel INSTALLS its lower layers from the staging channel, as published packages, and builds only
# its own repository (owner, 2026-11-25; .github#270): the staged lower package is the one the build gets. On a
# throwaway channel, offline, the way build-rpm.yml's build job does it:
#   - the real channel serves omx-lower 1.1, the staging channel omx-lower 1.0: the staged build is BELOW the real one
#     (a stale staged package, trap 344), so only the staging channel's priority (10, against the real channel's 99)
#     can make it win; version order alone takes the real one;
#   - the control: with the real channel alone, `dnf builddep` of a consumer that build-requires omx-lower installs
#     1.1, so the measurement can tell the two apart;
#   - add-staging.sh run as add-openmixer runs it for a pull request into devel (STAGING_FOR_DEVEL=true), then the same
#     builddep: the staged omx-lower 1.0 is installed, from openmixer-staging-noarch, though the real 1.1 is newer;
#   - the staging tree gone: the same add-staging.sh refuses by name, and nothing falls back to the real channel.
# gpgcheck is off for the throwaway packages (they are unsigned); the signed path is the publish's, tested there.
# Sabotage: the staging repository at priority 99 (the real channel's) is red: version order then takes 1.1.
# Runs as root in a throwaway Fedora container: it rewrites /etc/yum.repos.d.
#
#   devel-pr-staged-install.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "devel-pr-staged-install.sh rewrites /etc/yum.repos.d of a throwaway container: run it as root there" >&2; exit 2; }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || fail "$tool is not installed"; done
# shellcheck disable=SC1091
rel=$(. /etc/os-release && echo "$VERSION_ID")

ch=$t/channel
mk() { # <dir> <name> <version>; a noarch package
    local d=$t/rb-$2-$3
    mkdir -p "$d"
    printf 'Name: %s\nVersion: %s\nRelease: 1\nSummary: t\nLicense: MIT\nBuildArch: noarch\n%%description\nt\n%%files\n' "$2" "$3" > "$d/p.spec"
    rpmbuild -bb -D "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $2 $3"
    mkdir -p "$1"; mv "$d"/RPMS/noarch/*.rpm "$1/"
}
for tree in rpm staging/rpm; do for a in "$(uname -m)" noarch; do mkdir -p "$ch/$tree/fedora/$rel/$a"; done; done
mk "$ch/rpm/fedora/$rel/noarch" omx-lower 1.1
mk "$ch/staging/rpm/fedora/$rel/noarch" omx-lower 1.0
for tree in rpm staging/rpm; do for a in "$(uname -m)" noarch; do createrepo_c -q "$ch/$tree/fedora/$rel/$a"; done; done
printf 'Name: omx-upper\nVersion: 1\nRelease: 1\nSummary: t\nLicense: MIT\nBuildRequires: omx-lower\n%%description\nt\n' > "$t/upper.spec"

# the system: no distribution repository (offline), the real channel as openmixer-release adds it
mkdir -p "$t/distro-repos"; mv /etc/yum.repos.d/*.repo "$t/distro-repos/" 2>/dev/null || true
restore() { rm -f /etc/yum.repos.d/openmixer*.repo; mv "$t/distro-repos"/*.repo /etc/yum.repos.d/ 2>/dev/null || true; rm -rf "$t"; }
trap restore EXIT
sed "s|https://www.openmixer.org/|file://$ch/|" "$here/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
dnfo=(-q -y --setopt='*.gpgcheck=0' --setopt='*.repo_gpgcheck=0' --disablerepo='openmixer-testing*')

installed() { rpm -q --qf '%{version}' omx-lower 2>/dev/null || echo none; }
dnf "${dnfo[@]}" builddep "$t/upper.spec" >/dev/null 2>&1 || fail "builddep on the real channel alone"
[ "$(installed)" = 1.1 ] || fail "the control: with the real channel alone builddep installed omx-lower $(installed), want 1.1"
ok "control: the real channel alone gives the build omx-lower 1.1"
dnf "${dnfo[@]}" remove omx-lower >/dev/null 2>&1

STAGING_FOR_DEVEL=true BASE_URL=file://$ch "$here/.github/actions/add-openmixer/add-staging.sh" > "$t/add.log" 2>&1 ||
    { cat "$t/add.log"; fail "add-staging.sh, as for a pull request into devel, did not add a served staging channel"; }
dnf "${dnfo[@]}" builddep "$t/upper.spec" >/dev/null 2>&1 || fail "builddep with the staging channel added"
[ "$(installed)" = 1.0 ] || fail "a pull request into devel built against omx-lower $(installed), not the staged 1.0 (the staging priority did not win over the newer real 1.1)"
from=$(dnf repoquery --installed --qf '%{from_repo}' omx-lower 2>/dev/null | tail -1)
[ "$from" = openmixer-staging-noarch ] || fail "omx-lower 1.0 came from '$from', not the staging channel"
ok "a pull request into devel: builddep installs the staged omx-lower 1.0 from openmixer-staging-noarch, over the newer real 1.1 (priority, not version)"
dnf "${dnfo[@]}" remove omx-lower >/dev/null 2>&1; rm -f /etc/yum.repos.d/openmixer-staging.repo

mv "$ch/staging" "$t/staging-gone"
if STAGING_FOR_DEVEL=true BASE_URL=file://$ch "$here/.github/actions/add-openmixer/add-staging.sh" > "$t/gone.log" 2>&1; then
    cat "$t/gone.log"; fail "with no staging channel, a pull request into devel was let through to the real channel"
fi
grep -q 'a pull request into devel builds against the staging channel' "$t/gone.log" || { cat "$t/gone.log"; fail "the refusal does not say why"; }
[ ! -e /etc/yum.repos.d/openmixer-staging.repo ] || fail "a refused staging channel left a repository file"
ok "no staging channel: a pull request into devel is refused by name, never built against the real channel"
echo "devel-pr-staged-install: all passed"
