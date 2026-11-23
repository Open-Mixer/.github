#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The RPM half of the channel publish: two releases of one package go through publish-tree.sh and the
# repository answers `dnf updateinfo` with the changelog text of each. Needs a Fedora container with
# rpm-build, createrepo_c, python3-rpm and dnf.
#
#   tests/updateinfo.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

mkdir -p top/SPECS rpms
for v in 1.0.0 1.1.0; do
    if [ "$v" = 1.0.0 ]; then
        log='* Wed Sep 30 2026 Pau Aliagas <linuxnow@gmail.com> - 1.0.0-1
- First package.'
    else
        log='* Wed Oct 07 2026 Pau Aliagas <linuxnow@gmail.com> - 1.1.0-1
- Quieter start, and a 100%% fix.

* Wed Sep 30 2026 Pau Aliagas <linuxnow@gmail.com> - 1.0.0-1
- First package.'
    fi
    cat > top/SPECS/demo.spec <<SPEC
Name: demo
Version: $v
Release: 1%{?dist}
Summary: A demo for the channel
License: GPL-3.0-or-later
URL: https://github.com/Open-Mixer/demo
BuildArch: noarch
%description
Demo.
%install
mkdir -p %{buildroot}%{_datadir}/demo
echo $v > %{buildroot}%{_datadir}/demo/version
%files
%{_datadir}/demo/version
%changelog
$log
SPEC
    rpmbuild --define "_topdir $work/top" --define 'dist .fc44' -ba top/SPECS/demo.spec >build.log 2>&1 || { cat build.log >&2; exit 1; }
done
cp top/RPMS/noarch/*.rpm top/SRPMS/*.rpm rpms/

"$here/.github/actions/publish-rpms/publish-tree.sh" "$work/tree" rpms
dest=$work/tree/fedora/44/noarch
test -f "$dest/repodata/repomd.xml"
grep -q 'type="updateinfo"' "$dest/repodata/repomd.xml" || { echo "repomd.xml has no updateinfo" >&2; exit 1; }

# a second publish of the same tree keeps one updateinfo, not two
"$here/.github/actions/publish-rpms/publish-tree.sh" "$work/tree" rpms
[ "$(grep -c 'type="updateinfo"' "$dest/repodata/repomd.xml")" = 1 ]
[ "$(find "$dest/repodata" -name '*updateinfo*' | wc -l)" = 1 ]


# a machine that holds 1.0.0 is told what 1.1.0 brings, and nothing about what it already has
dnfq() { dnf --setopt=reposdir=/nonexistent --setopt=cachedir="$work/cache" --repofrompath="t,file://$dest" --setopt=t.gpgcheck=0 "$@"; }
rpm -i --nodeps --nosignature "$dest/demo-1.0.0-1.fc44.noarch.rpm"
out=$(dnfq updateinfo info 2>&1)
echo "$out"
grep -q 'Name        : FMX-demo-1.1.0-1.fc44' <<<"$out"
grep -q 'Description : - Quieter start, and a 100% fix\.' <<<"$out"
grep -q 'releases/tag/v1.1.0' <<<"$out"
! grep -q 'FMX-demo-1.0.0' <<<"$out"
out=$(dnfq check-update --changelogs 2>&1 || true)
echo "$out"
echo "updateinfo tests: all passed"
