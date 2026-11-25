#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# build-rpm.sh -r, the build of a merge to devel: the spec's own version and release at HEAD, no tag and no snapshot
# stamp, the same NEVRA a release of that version has (.github#289). Without -r the same tree is a snapshot (.git<time>.<sha>);
# -t and -r together are refused. On a throwaway git tree with a noarch spec, in a Fedora container (rpm-build, git).
#
#   build-devel-real.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
for tool in rpmbuild git; do command -v $tool >/dev/null || { echo "$tool is not installed" >&2; exit 2; }; done
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
tree=$t/omx-real
mkdir -p "$tree/packaging"
printf 'Name: omx-real\nVersion: 1.2.0\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\nBuildArch: noarch\nSource0: %%{name}-%%{version}.tar.gz\n%%description\nt\n%%prep\n%%setup -q\n%%files\n' \
    > "$tree/packaging/omx-real.spec"
git -C "$tree" init -q
git -C "$tree" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false add -A
git -C "$tree" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q -m "omx-real 1.2.0"
build=$here/.github/actions/build-rpm/build-rpm.sh
dist=$(rpm --eval '%{?dist}')

bash "$build" -C "$tree" -r "$t/real" > "$t/real.log" 2>&1 || { tail -20 "$t/real.log"; fail "build-rpm.sh -r did not build"; }
[ -f "$t/real/omx-real-1.2.0-1$dist.noarch.rpm" ] || { ls "$t/real"; fail "build-rpm.sh -r did not build omx-real-1.2.0-1$dist, the real NEVRA"; }
echo "ok   -r builds omx-real-1.2.0-1$dist.noarch.rpm, the release's own NEVRA, at an untagged HEAD"

bash "$build" -C "$tree" "$t/snap" > "$t/snap.log" 2>&1 || { tail -20 "$t/snap.log"; fail "the snapshot build did not build"; }
ls "$t/snap"/omx-real-1.2.0-1.git*.noarch.rpm >/dev/null 2>&1 || { ls "$t/snap"; fail "without -r the build is not a .git snapshot"; }
echo "ok   without -r the same tree is a snapshot (.git<time>.<sha>)"

rc=0; bash "$build" -C "$tree" -t v1.2.0 -r "$t/both" > "$t/both.log" 2>&1 || rc=$?
if [ "$rc" != 2 ] || ! grep -q 'exclude each other' "$t/both.log"; then cat "$t/both.log"; fail "-t and -r together were not refused (rc $rc)"; fi
echo "ok   -t and -r together are refused"
echo "build-devel-real: all passed"
