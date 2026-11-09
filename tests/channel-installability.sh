#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# channel-installability, each arm on a throwaway channel, offline:
#   ceiling  a library released above a published consumer's ceiling is red and names the consumer ("release it in
#            the same pass"); the consumer's new release in the same pass, or in this very release, turns it green; a
#            dependency between our own packages without a floor or a ceiling is red; a shared library's shlibs floor is
#            not; the same for rpm Requires, plain and rich.
#   deb      dose-debcheck: the library alone above the consumer's ceiling is red although the old library is still in
#            the tree (apt takes the newest and does not go back: plugin-hostd-protocol 0.5.0); a patch
#            inside the ceiling is green; a package broken before the release is reported, not held against it.
#   rpm      dnf repoclosure --newest, the same three cases on rpms built here.
# Usage: tests/channel-installability.sh [ceiling|deb|rpm]...   (no argument: ceiling, then each arm whose tools exist)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
gate=$here/.github/actions/channel-installability/gate.py
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }
# expect <rc> <text the output must hold, or -> <label> -- <gate args>
expect() {
  local want=$1 must=$2 label=$3; shift 4
  local rc=0
  python3 -I "$gate" "$@" > "$t/out" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then bad "$label: exit $rc, want $want"; sed 's/^/     /' "$t/out" | tail -15; return; fi
  if [ "$must" != - ] && ! grep -qF -- "$must" "$t/out"; then bad "$label: the output does not say '$must'"; sed 's/^/     /' "$t/out" | tail -15; return; fi
  ok "$label"
}

stanza() { # name version arch [depends]
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$1" "$2" "$3"
  [ -z "${4:-}" ] || printf 'Depends: %s\n' "$4"
  echo
}

arm_ceiling() {
  local d=$t/ceiling; mkdir -p "$d"
  { stanza libproto0 0.4.3 amd64
    stanza libproto0 0.4.4 amd64
    stanza hostd 0.19.1 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~), libc6 (>= 2.34)'
    stanza clap-host 0.30.6 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~), libcore1 (>= 0.30.6)'
    stanza libcore1 0.30.6 amd64
  } > "$d/published"
  stanza libproto0 0.5.0 amd64 > "$d/lib-alone"
  stanza libproto0 0.4.5 amd64 > "$d/lib-patch"
  { stanza libproto0 0.5.0 amd64
    stanza hostd 0.20.0 amd64 'libproto0 (>= 0.5.0~), libproto0 (<< 0.6~)'
    stanza clap-host 0.31.0 amd64 'libproto0 (>= 0.5.0~), libproto0 (<< 0.6~)'
  } > "$d/whole-pass"
  { stanza libproto0 0.5.0 amd64
    stanza hostd 0.20.0 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~)'
    stanza clap-host 0.31.0 amd64 'libproto0 (>= 0.5.0~), libproto0 (<< 0.6~)'
  } > "$d/pass-misfit"
  stanza tool 1.0.0 amd64 'hostd (>= 0.19.0~)' > "$d/no-ceiling"
  stanza tool 1.0.0 amd64 'hostd (<< 0.20~)' > "$d/no-floor"
  stanza tool 1.0.0 amd64 'hostd (>= 0.19.0~), hostd (<< 0.20~), libcore1 (>= 0.30.6), libc6 (>= 2.34)' > "$d/tool-ok"

  expect 1 'published clap-host 0.30.6 declares (libproto0 (<< 0.5~)): release it in the same pass' 'ceiling: a library alone above its consumer'"'"'s ceiling is red, naming clap-host' -- \
    ceiling --kind deb --published "$d/published" --new "$d/lib-alone"
  grep -qF 'published hostd 0.19.1 declares' "$t/out" && ok 'ceiling: ... and naming hostd' || bad 'ceiling: hostd not named'
  grep -qF 'libproto0 (<< 0.5~)' "$t/out" && ok 'ceiling: ... with the ceiling it falls outside' || bad 'ceiling: the ceiling not named'
  expect 0 - 'ceiling: a patch inside the ceiling is green' -- ceiling --kind deb --published "$d/published" --new "$d/lib-patch"
  expect 0 'its new release is in the same pass' 'ceiling: the consumers named in the same pass turn it green' -- \
    ceiling --kind deb --published "$d/published" --new "$d/lib-alone" --same-pass 'hostd clap-host'
  expect 1 'published hostd 0.19.1 declares' 'ceiling: one consumer of two in the pass is still red for the other' -- \
    ceiling --kind deb --published "$d/published" --new "$d/lib-alone" --same-pass 'clap-host'
  expect 0 - 'ceiling: the consumers released in this very release turn it green' -- \
    ceiling --kind deb --published "$d/published" --new "$d/whole-pass"
  expect 1 'hostd 0.20.0 of this pass requires libproto0 (<< 0.5~)' 'ceiling: a consumer of the pass that does not fit is red' -- \
    ceiling --kind deb --published "$d/published" --new "$d/pass-misfit"
  expect 1 'without a ceiling' 'ceiling: a new dependency on our own package without a ceiling is red' -- \
    ceiling --kind deb --published "$d/published" --new "$d/no-ceiling"
  grep -qF '(<< 0.20~)' "$t/out" && ok 'ceiling: ... and says the R-107 ceiling' || bad 'ceiling: no R-107 hint'
  expect 1 'without a floor' 'ceiling: one without a floor is red' -- \
    ceiling --kind deb --published "$d/published" --new "$d/no-floor"
  expect 0 - 'ceiling: floor and ceiling, a shlibs floor on libcore1 and a Debian package pass' -- \
    ceiling --kind deb --published "$d/published" --new "$d/tool-ok"

  # rpm: repoquery's format, rich and plain Requires, a constraint without a release
  { printf '@@libproto 0.4.4-1.fc44 x86_64\nrtld(GNU_HASH)\n'
    printf '@@hostd 0.19.1-1.fc44 x86_64\n(libproto(x86-64) >= 0.4.4 with libproto(x86-64) < 0.5)\nlibproto.so.0()(64bit)\n'
    printf '@@hostd-devel 0.19.1-1.fc44 noarch\nhostd = 0.19.1-1.fc44\npkgconfig(libproto) < 0.5\n'
  } > "$d/rpm-published"
  printf '@@libproto 0.5.0-1.fc44 x86_64\nrtld(GNU_HASH)\n' > "$d/rpm-lib-alone"
  printf '@@libproto 0.4.5-1.fc44 x86_64\nrtld(GNU_HASH)\n' > "$d/rpm-lib-patch"
  printf '@@tool 1.0.0-1.fc44 noarch\nhostd >= 0.19\n' > "$d/rpm-no-ceiling"
  expect 1 'published hostd 0.19.1-1.fc44 declares (libproto < 0.5): release it in the same pass' 'ceiling (rpm): a library alone above a rich-dependency ceiling is red' -- \
    ceiling --kind rpm --published "$d/rpm-published" --new "$d/rpm-lib-alone"
  expect 0 - 'ceiling (rpm): a patch inside it is green' -- ceiling --kind rpm --published "$d/rpm-published" --new "$d/rpm-lib-patch"
  expect 1 'without a ceiling' 'ceiling (rpm): a Requires without a ceiling is red' -- \
    ceiling --kind rpm --published "$d/rpm-published" --new "$d/rpm-no-ceiling"

  # the version orders the gate compares with, against the cases that bite
  python3 -I -B - "$gate" <<'PY' && ok 'ceiling: dpkg and rpm version order' || bad 'ceiling: version order'
import importlib.util, sys
s = importlib.util.spec_from_file_location("gate", sys.argv[1]); g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
deb = [("0.5.0", "0.5~", 1), ("0.4.4", "0.5~", -1), ("1.0~rc1", "1.0", -1), ("1:0.1", "2.0", 1), ("0.10.9-1", "0.10.10-1", -1),
       ("0.1.0-8~omx", "0.1.0-8", -1), ("1.9.10+2015", "1.9.10", 1), ("1.0", "1.0-0", 0)]
rpm = [("0.5.0-1.fc44", "0.5", 1), ("0.4.4-1.fc44", "0.5", -1), ("1.0~rc1", "1.0", -1), ("1.0^git1", "1.0", 1),
       ("0.19.1-1.fc44", "0.19.1-2.fc44", -1), ("0.19.1-1.fc44", "0.19.1", 0), ("1:0.1", "2.0", 1), ("0.10", "0.9", 1)]
bad = [(a, b, w) for a, b, w in deb if g.deb_cmp(a, b) != w] + [(a, b, w) for a, b, w in rpm if g.rpm_cmp(a, b) != w]
assert g.satisfies("deb", "0.5.0", "<<", "0.5~") is False and g.satisfies("rpm", "0.4.9-1.fc44", "<", "0.5") is True
sys.exit(1 if bad else 0)
PY
}

arm_deb() {
  command -v dose-debcheck >/dev/null || { bad 'deb: dose-debcheck is not installed (apt-get install dose-distcheck)'; return; }
  local d=$t/deb; mkdir -p "$d/channel/debian/bookworm"
  { stanza libc6 2.36-9 amd64; stanza python3 3.11.2-1 amd64; } > "$d/bg"
  { stanza libproto0 0.4.3 amd64
    stanza libproto0 0.4.4 amd64
    stanza hostd 0.19.1 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~), libc6 (>= 2.34)'
    stanza clap-host 0.30.6 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~)'
    stanza hostd-tests 0.19.1 amd64 'hostd (= 0.19.1), python3'
    stanza already-broken 1.0 all 'nothing-provides-this'
    stanza panel 0.9.1 all 'hostd (>= 0.15~)'
  } > "$d/channel/debian/bookworm/Packages"
  stanza libproto0 0.5.0 amd64 > "$d/lib-alone"
  stanza libproto0 0.4.5 amd64 > "$d/lib-patch"
  { stanza libproto0 0.5.0 amd64
    stanza hostd 0.20.0 amd64 'libproto0 (>= 0.5.0~), libproto0 (<< 0.6~)'
    stanza clap-host 0.31.0 amd64 'libproto0 (>= 0.5.0~), libproto0 (<< 0.6~)'
    stanza hostd-tests 0.20.0 amd64 'hostd (= 0.20.0)'
  } > "$d/whole-pass"
  args=(deb --channel "$d/channel" --suite bookworm --arch amd64 --bg "$d/bg")
  expect 1 'clap-host 0.30.6 was installable and is not' 'deb: the library alone is red although 0.4.4 is still in the tree' -- \
    "${args[@]}" --new-index "$d/lib-alone"
  grep -qF 'libproto0:amd64 (< 0.5~)' "$t/out" && ok 'deb: ... naming the unmet dependency' || bad 'deb: unmet dependency not named'
  grep -qF 'hostd 0.19.1 was installable and is not' "$t/out" && ok 'deb: ... and hostd' || bad 'deb: hostd not named'
  grep -qF 'hostd-tests 0.19.1 was installable and is not' "$t/out" && ok 'deb: ... and what installs through it' || bad 'deb: hostd-tests not named'
  grep -qF 'RED deb: debian/bookworm amd64 newest: apt-get install clap-host fails on a clean machine: clap-host : Depends: libproto0 (< 0.5~)' "$t/out" \
    && ok 'deb (newest): apt-get -s names the package and the reason' || bad 'deb (newest): apt-get -s finding missing'
  grep -qF 'HYGIENE: panel 0.9.1 depend on hostd with no ceiling' "$t/out" \
    && ok 'deb (hygiene): a published build without a ceiling is flagged' || bad 'deb (hygiene): not flagged'
  expect 0 - 'deb: a patch inside the ceiling is green' -- "${args[@]}" --new-index "$d/lib-patch"
  grep -qF 'already-broken 1.0 was already uninstallable before' "$t/out" && ok 'deb: a package broken before is reported, not red' \
    || bad 'deb: the earlier breakage is not reported'
  expect 0 - 'deb: the whole pass in one release is green' -- "${args[@]}" --new-index "$d/whole-pass"
  expect 0 'until the rest of the pass' 'deb: the consumers named in the same pass excuse their breakage' -- \
    "${args[@]}" --new-index "$d/lib-alone" --same-pass 'hostd clap-host'
  # the republish of the bad library (a re-run after it went out) is still red: before leaves its own version out
  stanza libproto0 0.5.0 amd64 >> "$d/channel/debian/bookworm/Packages"
  expect 1 'clap-host 0.30.6 was installable and is not' 'deb: a re-run after the library went out is still red' -- \
    "${args[@]}" --new-index "$d/lib-alone"
  expect 0 - 'deb: --drop leaves it out, and the channel without it is green' -- \
    "${args[@]}" --new-index "$d/lib-patch" --drop libproto0=0.5.0
  expect 2 'could not take the measurement' 'deb: an index that cannot be read is not a pass' -- \
    deb --channel "$d/nowhere" --suite bookworm --arch amd64 --bg "$d/bg" --new-index "$d/lib-patch"
}

arm_rpm() {
  for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || { bad "rpm: $tool is not installed"; return; }; done
  dnf repoclosure --help >/dev/null 2>&1 || { bad 'rpm: dnf repoclosure is not installed (dnf5-plugins)'; return; }
  local d=$t/rpm; mkdir -p "$d/top" "$d/channel/fedora/44/x86_64" "$d/channel/fedora/44/noarch" "$d/new-alone" "$d/new-patch" "$d/new-pass" "$d/empty"
  mk() { # name version requires... ; a noarch package with a .fc44 dist tag
    local n=$1 v=$2; shift 2
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\nBuildArch: noarch\n' "$n" "$v"
      for r in "$@"; do printf 'Requires: %s\n' "$r"; done
      printf '%%description\nt\n%%files\n'; } > "$d/top/$n-$v.spec"
    rpmbuild -bb -D "_topdir $d/top" -D 'dist .fc44' "$d/top/$n-$v.spec" >/dev/null 2>&1 || { echo "rpmbuild $n $v failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc44.noarch.rpm"
  }
  for p in "libproto 0.4.3" "libproto 0.4.4"; do mv "$(mk $p)" "$d/channel/fedora/44/noarch/"; done
  mv "$(mk hostd 0.19.1 '(libproto >= 0.4.4 with libproto < 0.5)')" "$d/channel/fedora/44/noarch/"
  mv "$(mk clap-host 0.30.6 'libproto >= 0.4.4' 'libproto < 0.5')" "$d/channel/fedora/44/noarch/"
  mv "$(mk already-broken 1.0 'nothing-provides-this')" "$d/channel/fedora/44/noarch/"
  # an old build without a ceiling, and a consumer of it: dnf can fall back to it
  mv "$(mk hostd 0.17.0 'libproto >= 0.2')" "$d/channel/fedora/44/noarch/"
  mv "$(mk panel 1.0 'hostd >= 0.15')" "$d/channel/fedora/44/noarch/"
  mv "$(mk libproto 0.5.0)" "$d/new-alone/"
  mv "$(mk libproto 0.4.5)" "$d/new-patch/"
  cp "$d/new-alone/"*.rpm "$d/new-pass/"
  mv "$(mk hostd 0.20.0 '(libproto >= 0.5.0 with libproto < 0.6)')" "$d/new-pass/"
  mv "$(mk clap-host 0.31.0 '(libproto >= 0.5.0 with libproto < 0.6)')" "$d/new-pass/"
  createrepo_c -q "$d/channel/fedora/44/x86_64"; createrepo_c -q "$d/channel/fedora/44/noarch"
  # no system repositories: the throwaway packages need none, and the test stays offline
  args=(rpm --channel "$d/channel" --fedora 44 --arch x86_64 --reposdir "$d/empty")
  expect 1 'clap-host 0.30.6-1.fc44.noarch was installable and is not' 'rpm: the library alone is red although 0.4.4 is still in the tree' -- \
    "${args[@]}" --new-dir "$d/new-alone"
  grep -qF 'libproto < 0.5' "$t/out" && ok 'rpm: ... naming the unmet dependency' || bad 'rpm: unmet dependency not named'
  grep -qF 'hostd 0.19.1-1.fc44.noarch was installable and is not' "$t/out" && ok 'rpm: ... and hostd (a rich dependency)' || bad 'rpm: hostd not named'
  grep -qF 'published clap-host 0.30.6-1.fc44 declares (libproto < 0.5): release it in the same pass' "$t/out" && ok 'rpm: ... and the ceiling arm names the consumer' || bad 'rpm: ceiling arm silent'
  grep -qF 'RED rpm: fedora/44 x86_64 newest: installing panel falls back to libproto 0.4.4-1.fc44, not its newest 0.5.0-1.fc44: with libproto 0.5.0-1.fc44 requested, dnf takes hostd 0.17.0-1.fc44 instead' "$t/out" \
    && ok 'rpm (newest): a fallback to an old build is red, naming the package' || bad 'rpm (newest): fallback not found'
  grep -qF 'HYGIENE: hostd 0.17.0-1.fc44 depend on libproto with no ceiling' "$t/out" \
    && ok 'rpm (hygiene): the old build without a ceiling is flagged' || bad 'rpm (hygiene): not flagged'
  expect 0 - 'rpm: a patch inside the ceiling is green' -- "${args[@]}" --new-dir "$d/new-patch"
  grep -qF 'already-broken 1.0-1.fc44.noarch was already uninstallable before' "$t/out" && ok 'rpm: a package broken before is reported, not red' \
    || bad 'rpm: the earlier breakage is not reported'
  expect 0 - 'rpm: the whole pass in one release is green' -- "${args[@]}" --new-dir "$d/new-pass"
  expect 2 'could not take the measurement' 'rpm: a repository that cannot be read is not a pass' -- \
    rpm --channel "$d/nowhere" --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new-patch"
}

arms=("$@")
if [ ${#arms[@]} = 0 ]; then
  arms=(ceiling)
  command -v dose-debcheck >/dev/null && arms+=(deb)
  command -v createrepo_c >/dev/null && command -v rpmbuild >/dev/null && arms+=(rpm)
fi
for arm in "${arms[@]}"; do "arm_$arm"; done
[ "$fail" = 0 ] && echo "channel-installability (${arms[*]}): ok" || echo "channel-installability (${arms[*]}): FAILED"
exit "$fail"
