#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Two builds of one commit give the same bytes, the DEB side: build-deb.sh builds a throwaway package from two
# checkouts of one commit at two different paths, a second apart, and every DEB of the second build (an amd64 binary
# and an arch-all package) is the first build's file, byte for byte. dpkg clamps the times to the changelog entry and
# maps the build path out of the debug info; this fails the day one of the two stops holding. Needs a Debian container
# with dpkg-dev, debhelper, build-essential, git and python3, as root (build-deb.sh installs the build dependencies).
#
#   tests/build-deb-same-bytes.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir -p tree/debian
git init -q -b main tree
cat > tree/demo.c <<'C'
#include <stdio.h>
int main(void) { puts("demo"); return 0; }
C
echo data > tree/demo.dat
printf 'demo: demo.c\n\t$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $<\ninstall: demo\n\tinstall -D -m 755 demo $(DESTDIR)/usr/bin/demo\n\tinstall -D -m 644 demo.dat $(DESTDIR)/usr/share/demo/demo.dat\n' > tree/Makefile
printf 'demo (1.0.0) unstable; urgency=medium\n\n  * x\n\n -- t <t@t>  Wed, 30 Sep 2026 12:00:00 +0000\n' > tree/debian/changelog
cat > tree/debian/control <<'CONTROL'
Source: demo
Section: misc
Priority: optional
Maintainer: t <t@t>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.7.0

Package: demo
Architecture: any
Depends: ${shlibs:Depends}, ${misc:Depends}
Description: demo built twice
 A demo.

Package: demo-data
Architecture: all
Depends: ${misc:Depends}
Description: data of the demo built twice
 Data.
CONTROL
printf '#!/usr/bin/make -f\n%%:\n\tdh $@\n' > tree/debian/rules
chmod +x tree/debian/rules
echo 'usr/bin/demo' > tree/debian/demo.install
echo 'usr/share/demo' > tree/debian/demo-data.install
git -C tree add -A
GIT_COMMITTER_DATE=2026-09-30T12:00:00Z git -C tree commit -q -m "First version" --date 2026-09-30T12:00:00Z

mkdir -p one two/deeper
git clone -q tree one/demo
git clone -q tree two/deeper/demo
"$here/.github/actions/build-deb/build-deb.sh" -C one/demo -L out1 > one.log 2>&1 || { tail -30 one.log; echo "FAIL the first build"; exit 1; }
sleep 1
"$here/.github/actions/build-deb/build-deb.sh" -C two/deeper/demo -L out2 > two.log 2>&1 || { tail -30 two.log; echo "FAIL the second build"; exit 1; }

fail=0
n=0
for deb in out1/*.deb; do
    f=$(basename "$deb")
    n=$((n + 1))
    [ -f "out2/$f" ] || { echo "FAIL the second build has no $f"; fail=1; continue; }
    cmp -s "$deb" "out2/$f" || { echo "FAIL $f differs between two builds of one commit"; fail=1; }
done
for want in amd64 all; do
    ls out1/demo*_"$want".deb > /dev/null 2>&1 || { echo "FAIL no $want package was built: $(ls out1)"; fail=1; }
done
[ "$(ls out2/*.deb | wc -l)" = "$n" ] || { echo "FAIL the two builds made different sets: $(ls out1 out2)"; fail=1; }
# a snapshot is named by the commit's time, then the commit: the build of a later commit sorts above an earlier one's
stamp=$(date -u -d 2026-09-30T12:00:00Z +%s).$(git -C tree rev-parse --short HEAD)
[ -f "out1/demo-data_1.0.0~git${stamp}_all.deb" ] || { echo "FAIL the snapshot is not 1.0.0~git$stamp: $(ls out1)"; fail=1; }
[ "$fail" = 0 ] && echo "ok: $n DEBs, the same bytes twice, named 1.0.0~git$stamp"
exit "$fail"
