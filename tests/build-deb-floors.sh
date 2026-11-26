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

sed "s/out.append(f'{d} (>= {v})')/out.append(d)/" "$F" > "$work/sab.py"
cp "$work/control.orig" "$work/control"; python3 "$work/sab.py" apply "$work/control" >/dev/null
! grep -q 'omx-contract (>= 0.23.2)' "$work/control" || fail "the sabotage did not take"
echo "ok   sabotage: without the floor the apply arm goes red"
echo "build-deb-floors.sh: all arms ok"
