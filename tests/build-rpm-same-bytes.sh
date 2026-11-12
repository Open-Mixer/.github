#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Two builds of one commit give the same bytes: build-rpm.sh builds a throwaway package twice, a second apart, and
# every RPM of the second build (the source package, an x86_64 binary with its debug packages, a noarch subpackage)
# is the first build's file, byte for byte. A build tree whose path changes from one build to the next fails here in
# all of them (rpm keeps the path in the source package's header, and every binary names its source package by
# digest), and so does a source archive that carries the clock. The builder is set up the way a rebuild that compares bytes sets
# itself up: a fixed build host name and the build time taken from the %changelog
# entry, which changelog.sh dates with the commit; build-rpm.sh leaves those two to the builder, so a release keeps its
# real build time. Needs a Fedora container with rpm-build, gcc, git and python3.
#
#   tests/build-rpm-same-bytes.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir home
printf '%s\n' '%_buildhost demo-builder' '%source_date_epoch_from_changelog 1' '%use_source_date_epoch_as_buildtime 1' \
    '%clamp_mtime_to_source_date_epoch 1' > home/.rpmmacros
export HOME=$work/home

mkdir -p tree/packaging
git init -q -b main tree
cat > tree/demo.c <<'C'
#include <stdio.h>
int main(void) { puts("demo"); return 0; }
C
echo data > tree/demo.dat
cat > tree/packaging/demo.spec <<'SPEC'
Name: demo
Version: 1.0.0
Release: 1%{?dist}
Summary: A demo built twice
License: GPL-3.0-or-later
Source0: %{name}-%{version}.tar.gz
BuildRequires: gcc
%description
A demo.
%package data
Summary: The demo's data
BuildArch: noarch
%description data
Data.
%prep
%autosetup
%build
gcc %{optflags} %{build_ldflags} -o demo demo.c
%install
install -D -m 755 demo %{buildroot}%{_bindir}/demo
install -D -m 644 demo.dat %{buildroot}%{_datadir}/demo/demo.dat
%files
%{_bindir}/demo
%files data
%{_datadir}/demo/
SPEC
git -C tree add -A
GIT_COMMITTER_DATE=2026-09-30T12:00:00Z git -C tree commit -q -m "First version" --date 2026-09-30T12:00:00Z

"$here/.github/actions/build-rpm/build-rpm.sh" -C tree one > one.log 2>&1 || { tail -30 one.log; echo "FAIL the first build"; exit 1; }
sleep 1
"$here/.github/actions/build-rpm/build-rpm.sh" -C tree two > two.log 2>&1 || { tail -30 two.log; echo "FAIL the second build"; exit 1; }

fail=0
n=0
for rpm in one/*.rpm; do
    f=$(basename "$rpm")
    n=$((n + 1))
    [ -f "two/$f" ] || { echo "FAIL the second build has no $f"; fail=1; continue; }
    cmp -s "$rpm" "two/$f" || { echo "FAIL $f differs between two builds of one commit"; fail=1; }
done
for want in src x86_64 noarch; do
    ls one/demo-*."$want".rpm > /dev/null 2>&1 || { echo "FAIL no $want package was built: $(ls one)"; fail=1; }
done
ls one/demo-debuginfo-*.rpm > /dev/null 2>&1 || { echo "FAIL no debug package was built, the build tree path is not under test"; fail=1; }
[ "$(ls two/*.rpm | wc -l)" = "$n" ] || { echo "FAIL the two builds made different sets: $(ls one two)"; fail=1; }
[ "$fail" = 0 ] && echo "ok: $n RPMs, the same bytes twice"
exit "$fail"
