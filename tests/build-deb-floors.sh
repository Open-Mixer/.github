#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Generated lower-layer floors for debs (.github#312): floors-deb.py apply gives every bare Depends of an installed
# OpenMixer package (apt took it from openmixer.org, or a local file) "(>= <upstream version>)", the staged +git suffix
# dropped, and leaves a Debian package, an alternative, a substvar, a versioned name and the source stanza as they are;
# check fails a deb depending on an OpenMixer package with no version and passes a floored one. The tools are fakes.
# Sabotage: an apply that floors nothing turns the omx-contract arm red.
#
#   tests/build-deb-floors.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
F=$here/.github/actions/build-deb/floors-deb.py
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/control" >&2 2>/dev/null || true; exit 1; }
cat > "$work/dpkg-query" <<'X'
#!/bin/bash
case ${@: -1} in
  omx-contract) echo "install ok installed 0.23.2+git1795557437.5582f07" ;;
  libomx-domain0) echo "install ok installed 0.23.2" ;;
  boot-contract) echo "install ok installed 0.1.0" ;;
  python3) echo "install ok installed 3.13.5-1" ;;
  *) exit 1 ;;
esac
X
cat > "$work/apt-cache" <<'X'
#!/bin/bash
n=${@: -1}
case $n in
  omx-contract|libomx-domain0) src=" 500 https://www.openmixer.org/staging/deb trixie/main amd64 Packages" ;;
  python3) src=" 500 http://deb.debian.org/debian trixie/main amd64 Packages" ;;
  boot-contract) src="" ;;
esac
printf '%s:\n  Installed: x\n  Version table:\n *** x 100\n' "$n"
[ -n "$src" ] && printf '       %s\n' "$src"
printf '        100 /var/lib/dpkg/status\n     0.0.1 500\n        500 http://other.example/debian trixie/main amd64 Packages\n'
X
cat > "$work/dpkg-deb" <<'X'
#!/bin/bash
[ "$3" = Depends ] && cat "$2.depends"
X
chmod +x "$work"/dpkg-query "$work"/apt-cache "$work"/dpkg-deb
export FLOORS_DPKG_QUERY=$work/dpkg-query FLOORS_APT_CACHE=$work/apt-cache FLOORS_DPKG_DEB=$work/dpkg-deb
cat > "$work/control" <<'X'
Source: demo
Build-Depends: debhelper-compat (= 13), omx-contract

Package: demo
Architecture: all
Depends: ${misc:Depends}, omx-contract, python3,
 libomx-domain0, boot-contract, omx-contract | other, omx-contract-data (= ${binary:Version})
Description: demo
 demo
X
cp "$work/control" "$work/control.orig"
python3 "$F" apply "$work/control" > "$work/out"
d=$(awk '/^Depends:/{f=1} f{printf "%s", $0} /^Description/{exit}' "$work/control")
case $d in *'omx-contract (>= 0.23.2),'*) ;; *) fail "omx-contract got no floor, or the staged +git suffix stayed: $d" ;; esac
case $d in *'libomx-domain0 (>= 0.23.2)'*) ;; *) fail "libomx-domain0 got no floor" ;; esac
case $d in *'boot-contract (>= 0.1.0)'*) ;; *) fail "a local-file sibling got no floor" ;; esac
# shellcheck disable=SC2016 # literal substvars, as debian/control spells them
for keep in '${misc:Depends}' ' python3,' 'omx-contract | other' 'omx-contract-data (= ${binary:Version})'; do
    case $d in *"$keep"*) ;; *) fail "changed what it must leave: $keep" ;; esac
done
grep -q '^Build-Depends: debhelper-compat (= 13), omx-contract$' "$work/control" || fail "the source stanza was touched"
grep -q 'floors: 3 generated' "$work/out" || fail "count line: $(cat "$work/out")"
echo "ok   apply: OpenMixer names floored at the upstream version; the rest and Build-Depends left"

echo 'omx-contract, python3' > "$work/bare.deb.depends"
echo 'omx-contract (>= 0.23.2), python3' > "$work/good.deb.depends"
if python3 "$F" check "$work/bare.deb" > "$work/out" 2>&1; then fail "check passed a deb depending on omx-contract bare"; fi
grep -q 'bare.deb Depends omx-contract with no version' "$work/out" || fail "check does not name it: $(cat "$work/out")"
python3 "$F" check "$work/good.deb" > "$work/out" 2>&1 || fail "check refused a floored deb: $(cat "$work/out")"
echo "ok   check: an unversioned OpenMixer dependency fails, a floored one passes"

# apply-deb on a real package (needs dpkg-deb): the BUILT control gets the floors on one line, the package still
# unpacks, and two repacks with one SOURCE_DATE_EPOCH are the same bytes
if command -v dpkg-deb >/dev/null; then
    real_deb=$(command -v dpkg-deb)
    mkdir -p "$work/pkg/DEBIAN" "$work/pkg/usr/share/demo"; echo x > "$work/pkg/usr/share/demo/x"
    printf '%s\n' 'Package: demo' 'Version: 1.0' 'Architecture: all' 'Maintainer: t <t@t>' \
        'Depends: omx-contract, python3' 'Description: demo' ' demo' > "$work/pkg/DEBIAN/control"
    FLOORS_DPKG_DEB=$real_deb dpkg-deb --root-owner-group -b "$work/pkg" "$work/demo.deb" >/dev/null
    cp "$work/demo.deb" "$work/demo2.deb"
    SOURCE_DATE_EPOCH=1795600000 FLOORS_DPKG_DEB=$real_deb python3 "$F" apply-deb "$work/demo.deb" > "$work/out"
    SOURCE_DATE_EPOCH=1795600000 FLOORS_DPKG_DEB=$real_deb python3 "$F" apply-deb "$work/demo2.deb" > /dev/null
    [ "$(dpkg-deb -f "$work/demo.deb" Depends)" = 'omx-contract (>= 0.23.2), python3' ] || fail "apply-deb: built Depends is $(dpkg-deb -f "$work/demo.deb" Depends)"
    cmp -s "$work/demo.deb" "$work/demo2.deb" || fail "apply-deb: two repacks with one SOURCE_DATE_EPOCH differ"
    FLOORS_DPKG_DEB=$real_deb python3 "$F" check "$work/demo.deb" > "$work/out" 2>&1 || fail "check refused the floored deb: $(cat "$work/out")"
    echo "ok   apply-deb: the built package carries the floor, the same bytes twice, and passes check"

    # restamp: a .changes and a .buildinfo written for the package BEFORE its repack name its old sums; after restamp
    # every size and sum they list is the file's own. A package with nothing to floor is not repacked at all.
    rm -rf "$work/pkg2"; cp -r "$work/pkg" "$work/pkg2"; sed -i 's/^Depends: .*/Depends: python3/' "$work/pkg2/DEBIAN/control"
    mkdir -p "$work/out2"; dpkg-deb --root-owner-group -b "$work/pkg" "$work/out2/demo_1.0_all.deb" >/dev/null
    dpkg-deb --root-owner-group -b "$work/pkg2" "$work/out2/plain_1.0_all.deb" >/dev/null
    python3 - "$work/out2" <<'X'
import hashlib, os, sys
d = sys.argv[1]
def line(algo, f):
    b = open(os.path.join(d, f), 'rb').read(); return f' {hashlib.new(algo, b).hexdigest()} {len(b)} {f}'
debs = ['demo_1.0_all.deb', 'plain_1.0_all.deb']
open(f'{d}/demo_1.0_all.buildinfo', 'w').write('Format: 1.0\nSource: demo\nChecksums-Sha256:\n' + '\n'.join(line('sha256', f) for f in debs) + '\n')
files = debs + ['demo_1.0_all.buildinfo']
ch = 'Format: 1.8\nSource: demo\nChecksums-Sha1:\n' + '\n'.join(line('sha1', f) for f in files) + '\nChecksums-Sha256:\n' + '\n'.join(line('sha256', f) for f in files)
ch += '\nFiles:\n' + '\n'.join(line('md5', f).replace(f' {f}', f' misc optional {f}') for f in files) + '\n'
open(f'{d}/demo_1.0_all.changes', 'w').write(ch)
X
    plain_before=$(sha256sum < "$work/out2/plain_1.0_all.deb")
    SOURCE_DATE_EPOCH=1795600000 FLOORS_DPKG_DEB=$real_deb python3 "$F" apply-deb "$work/out2/demo_1.0_all.deb" "$work/out2/plain_1.0_all.deb" > "$work/out"
    [ "$(sha256sum < "$work/out2/plain_1.0_all.deb")" = "$plain_before" ] || fail "apply-deb repacked a package with nothing to floor"
    python3 "$F" restamp "$work/out2/demo_1.0_all.changes" > "$work/out" || fail "restamp failed: $(cat "$work/out")"
    python3 - "$work/out2" <<'X' || fail "restamp left a sum that is not the file's"
import hashlib, os, re, sys
d = sys.argv[1]; algos = {'Files': 'md5', 'Checksums-Sha1': 'sha1', 'Checksums-Sha256': 'sha256'}
for name in ('demo_1.0_all.changes', 'demo_1.0_all.buildinfo'):
    field = None
    for l in open(os.path.join(d, name)).read().split('\n'):
        m = re.match(r'^([A-Za-z0-9-]+):', l)
        if m: field = m.group(1); continue
        if field in algos and l.startswith(' ') and l.strip():
            p = l.split(); b = open(os.path.join(d, p[-1]), 'rb').read()
            assert p[0] == hashlib.new(algos[field], b).hexdigest() and p[1] == str(len(b)), (name, l)
X
    echo "ok   restamp: every sum the .changes and the .buildinfo list is the repacked file's; a package with no floor is not repacked"
else
    echo "skip apply-deb arm: no dpkg-deb here (CI runs it)"
fi

# end to end (needs dpkg-buildpackage, debhelper and lintian): a real package whose Depends names an OpenMixer package
# goes through build-deb.sh with lintian on; the floor lands in the built .deb and lintian passes on the restamped
# .changes (it failed with checksum-mismatch-in-changes-file before restamp, .github#312)
if command -v dpkg-buildpackage >/dev/null && command -v lintian >/dev/null && command -v dh >/dev/null; then
    src=$work/e2e/demo; mkdir -p "$src/debian/source"; git -C "$work/e2e" init -q demo 2>/dev/null || git init -q "$src"
    echo '3.0 (native)' > "$src/debian/source/format"
    printf 'demo (1.0.0) unstable; urgency=medium\n\n  * Initial release.\n\n -- Tools Test <tools-test@example.invalid>  Thu, 26 Nov 2026 00:00:00 +0000\n' > "$src/debian/changelog"
    printf '%s\n' 'Source: demo' 'Section: misc' 'Priority: optional' 'Maintainer: Tools Test <tools-test@example.invalid>' \
        'Build-Depends: debhelper-compat (= 13)' 'Standards-Version: 4.7.0' 'Rules-Requires-Root: no' '' 'Package: demo' \
        'Architecture: all' 'Depends: ${misc:Depends}, omx-contract' 'Description: fixture of the generated floors test' \
        ' A fixture whose dependency on an OpenMixer package gets its floor.' > "$src/debian/control"
    mkdir -p "$src/data"; echo fixture > "$src/data/fixture.txt"; echo 'data/fixture.txt usr/share/demo' > "$src/debian/demo.install"
    printf '#!/usr/bin/make -f\n%%:\n\tdh $@\n' > "$src/debian/rules"; chmod +x "$src/debian/rules"
    printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n\nFiles: *\nCopyright: 2026 Tools Test\nLicense: GPL-3+\n On Debian systems, see /usr/share/common-licenses/GPL-3.\n' > "$src/debian/copyright"
    git -C "$src" -c user.name=t -c user.email=t@t add -A; git -C "$src" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm demo
    mkdir -p "$work/e2e/out"
    if (cd "$src" && env -u FLOORS_DPKG_DEB FLOORS_DPKG_QUERY=$work/dpkg-query FLOORS_APT_CACHE=$work/apt-cache \
            bash "$here/.github/actions/build-deb/build-deb.sh" -r "$work/e2e/out") > "$work/e2e.log" 2>&1; then
        d=$(dpkg-deb -f "$work/e2e/out/demo_1.0.0_all.deb" Depends)
        case $d in *'omx-contract (>= 0.23.2)'*) ;; *) fail "e2e: the built Depends is $d" ;; esac
        ! grep -q -E 'checksum-mismatch-in-changes-file|file-size-mismatch' "$work/e2e.log" || fail "e2e: lintian found stale sums"
        echo "ok   e2e: build-deb.sh floors the built package and lintian passes on its restamped .changes"
    else
        tail -25 "$work/e2e.log" >&2; fail "e2e: build-deb.sh failed (lintian on the restamped .changes?)"
    fi
else
    echo "skip e2e arm: no dpkg-buildpackage/debhelper/lintian here (CI's deb job runs it)"
fi

sed "s/out.append(f'{d} (>= {v})')/out.append(d)/" "$F" > "$work/sab.py"
cp "$work/control.orig" "$work/control"; python3 "$work/sab.py" apply "$work/control" >/dev/null
! grep -q 'omx-contract (>= 0.23.2)' "$work/control" || fail "the sabotage did not take"
echo "ok   sabotage: without the floor the apply arm goes red"
echo "build-deb-floors.sh: all arms ok"
