#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# channel-installability, each arm on a throwaway channel, offline:
#   ceiling  a library released above a published consumer's ceiling is red and names the consumer ("release it in
#            the same pass"); the consumer's new release in the same pass, or in this very release, turns it green; a
#            dependency between our own packages without a floor is red, and a floor alone is green (.github#102: the
#            owner's rule is floors only on our packages; a breaking release declares Breaks/Conflicts); the same for rpm
#            Requires, plain and rich.
#   deb      dose-debcheck: the library alone above the consumer's ceiling is red although the old library is still in
#            the tree (apt takes the newest and does not go back: plugin-hostd-protocol 0.5.0); a patch
#            inside the ceiling is green; a package broken before the release is reported, not held against it.
#   rpm      dnf repoclosure --newest, the same three cases on rpms built here.
#            And a dry run that built x86_64 only: a noarch contract bumped with aarch64 not built is red alone, green with
#            --unbuilt-arch-pass (aarch64 still checked), and a break on the built architecture stays red.
#            And a quick release (MATRIX_SET=quick, the omx-dsp 0.32.1 replay, rpm_quick): its noarch contract is
#            published into the quick set's architecture trees alone (fc44 and fc45 x86_64), the aarch64 and noarch trees
#            keep the packages they served, the aarch64 view still installs, and the check judges the quick cells alone,
#            naming each cell it leaves out.
#   external a release package that Requires another channel's release package (openmixer-release requires freereac-release):
#            refused when the dependency lives only in a channel nobody declared, green when the one declared file names it, the
#            external channel's own packages never judged, a channel that serves nothing named, a malformed declaration exit 2.
#   source   (same-pass) a name in the same-pass list is a SOURCE: it covers every binary the channel's own metadata says it
#            builds (rpm SOURCERPM, deb Source: field, the Package name when absent), and a package whose only unmet
#            requirement on its path is held by such a binary is reported, not red; any other breakage stays red.
# Usage: tests/channel-installability.sh [ceiling|deb_cells|deb|deb_source|deb_unbuilt|deb_dryrun_version|rpm|rpm_source|rpm_quick|external_deb|external_rpm|mirror_client]...   (no argument: ceiling, then each arm whose tools exist)
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
  expect 0 - 'ceiling: a FLOOR-ONLY dependency on our own package is green (.github#102: floors only on our packages)' -- \
    ceiling --kind deb --published "$d/published" --new "$d/no-ceiling"
  expect 1 'without a floor' 'ceiling: one without a floor is red' -- \
    ceiling --kind deb --published "$d/published" --new "$d/no-floor"
  expect 0 - 'ceiling: floor and ceiling, a shlibs floor on libcore1 and a Debian package pass' -- \
    ceiling --kind deb --published "$d/published" --new "$d/tool-ok"

  # a same-pass entry must be a source or a binary in the channel's metadata (.github: omx-clap-core named a REPOSITORY, its
  # source is omx-clap-host, and the pass passed silently): an entry that matches neither is refused by name, one line each
  expect 1 'same-pass entry omx-clap-core is neither a source nor a binary package in the channel' \
    'ceiling: a same-pass entry naming a repository (no source or binary of that name) is refused by name' -- \
    ceiling --kind deb --published "$d/published" --new "$d/whole-pass" --same-pass 'hostd clap-host omx-clap-core'
  [ "$(grep -c 'same-pass entry' "$t/out")" = 1 ] && ok 'ceiling: ... and only that entry is named' || bad 'ceiling: the refusal names more than the unknown entry'
  # a SOURCE whose binary is named otherwise (Source: field) is a name of the channel: accepted, nothing refused for it
  { printf 'Package: clap-host\nSource: clap-core (0.30.6-1)\nVersion: 0.30.6\nArchitecture: amd64\nDepends: libproto0 (>= 0.4.4~), libproto0 (<< 0.5~)\n\n'
    stanza libproto0 0.4.3 amd64
  } > "$d/src-published"
  expect 0 - 'ceiling: a same-pass source whose binary is named otherwise is accepted (clap-core builds clap-host)' -- \
    ceiling --kind deb --published "$d/src-published" --new "$d/lib-patch" --same-pass clap-core
  ! grep -q 'same-pass entry' "$t/out" && ok 'ceiling: ... and no same-pass line is refused' || bad 'ceiling: clap-core refused'
  # ceiling mode expands a same-pass SOURCE to its binaries exactly as the arms do (one expand_same_pass): clap-core builds
  # clap-host, so clap-host is released in the pass and its ceiling does not refuse the new library
  expect 0 'same pass: clap-core also covers its binaries clap-host' \
    'ceiling: a same-pass source covers its differently named binary (clap-host), as in the arms' -- \
    ceiling --kind deb --published "$d/src-published" --new "$d/lib-alone" --same-pass clap-core
  # a binary name is accepted
  expect 0 - 'ceiling: a same-pass binary name is accepted' -- ceiling --kind deb --published "$d/published" --new "$d/lib-patch" --same-pass clap-host
  ! grep -q 'same-pass entry' "$t/out" && ok 'ceiling: ... and no same-pass line is refused' || bad 'ceiling: clap-host refused'
  # a package new to the channel and built in this run is among the metadata: accepted. One named in the pass but not built
  # in this run is not in the metadata, and is refused (the omx-clap-core arm above)
  { stanza libproto0 0.4.5 amd64; stanza newsrc 1.0 amd64; } > "$d/patch-and-new"
  expect 0 - 'ceiling: a brand-new source built in this run is accepted' -- \
    ceiling --kind deb --published "$d/published" --new "$d/patch-and-new" --same-pass newsrc
  ! grep -q 'same-pass entry' "$t/out" && ok 'ceiling: ... and no same-pass line is refused' || bad 'ceiling: newsrc refused'

  # a pull request's snapshot (<v>~git<time>.<sha>, sorting below <v>) is judged at the <v> it would release (#93): a
  # published consumer's (>= <v>) floor does not refuse it; a snapshot of an older version still is
  { stanza libx7 1.10.4 amd64
    stanza consumer 1.0.43 amd64 'libx7 (>= 1.11.0)'
  } > "$d/snap-published"
  stanza libx7 1.11.0~git1794785975.a48ccb1 amd64 > "$d/snap-at-floor"
  stanza libx7 1.10.9~git1794785975.a48ccb1 amd64 > "$d/snap-too-old"
  expect 0 - 'ceiling: a snapshot of the version a consumer floors on is judged at that version, green' -- \
    ceiling --kind deb --published "$d/snap-published" --new "$d/snap-at-floor"
  expect 1 'libx7 1.10.9~git1794785975.a48ccb1 falls outside the range published consumer 1.0.43 declares (libx7 (>= 1.11.0))' \
    'ceiling: a snapshot of an older version is still red' -- ceiling --kind deb --published "$d/snap-published" --new "$d/snap-too-old"
  # REGRESSION FROM #94: a snapshot pass whose -dev pins '=' its own runtime package at the same snapshot. Pin and
  # package are one string; judging only the package at its release version (1.11.0) against the pin's snapshot
  # (= 1.11.0~git...) called them "two releases that do not fit each other" (libreac#65: every -dev that pins '=')
  { stanza libx7 1.11.0~git1794787685.e71e550 amd64
    stanza libx-dev 1.11.0~git1794787685.e71e550 amd64 'libx7 (= 1.11.0~git1794787685.e71e550)'
  } > "$d/snap-pass-pins"
  expect 0 - 'ceiling: a snapshot pass whose -dev pins = its own runtime package at the same snapshot, green' -- \
    ceiling --kind deb --published "$d/snap-published" --new "$d/snap-pass-pins"
  # ... while a -dev pinning '=' a version this pass does not release is still a misfit
  { stanza libx7 1.11.0~git1794787685.e71e550 amd64
    stanza libx-dev 1.11.0~git1794787685.e71e550 amd64 'libx7 (= 1.10.9)'
  } > "$d/snap-pass-mispins"
  expect 1 'do not fit each other' \
    'ceiling: a snapshot -dev pinning = another version of its runtime package is still red' -- \
    ceiling --kind deb --published "$d/snap-published" --new "$d/snap-pass-mispins"

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
  expect 0 - 'ceiling (rpm): a floor-only Requires on our own package is green (.github#102)' -- \
    ceiling --kind rpm --published "$d/rpm-published" --new "$d/rpm-no-ceiling"

  # no epochs (owner rule, while developing): an rpm Epoch or a Debian N: version, staged or served, is red by name
  stanza py3-proto 0.6.0 all > "$d/ep-none"
  stanza py3-proto 1:0.6.0 all > "$d/ep-deb-new"
  { stanza py3-proto 0.6.0 all; stanza py3-proto 2:0.5.0 all; } > "$d/ep-deb-served"
  printf '@@py3-proto 1:0.6.0-1.fc45 noarch\nrtld(GNU_HASH)\n' > "$d/ep-rpm-new"
  printf '@@py3-proto 0.6.0-1.fc45 noarch\nrtld(GNU_HASH)\n' > "$d/ep-rpm-none"
  printf '@@py3-proto 3:0.5.0-1.fc45 noarch\nrtld(GNU_HASH)\n' > "$d/ep-rpm-served"
  expect 0 - 'epochs: packages with no epoch are green (deb)' -- ceiling --kind deb --published "$d/ep-none" --new "$d/ep-none"
  expect 0 - 'epochs: packages with no epoch are green (rpm)' -- ceiling --kind rpm --published "$d/ep-rpm-none" --new "$d/ep-rpm-none"
  expect 1 'RED ceiling: deb: py3-proto 1:0.6.0 (all, staged) carries Debian epoch 1: no epochs (owner rule); prune and release a new version' \
    'epochs: a staged Debian N: version is refused by name' -- ceiling --kind deb --published "$d/ep-none" --new "$d/ep-deb-new"
  expect 1 'py3-proto 2:0.5.0 (all, served) carries Debian epoch 2: no epochs (owner rule)' \
    'epochs: a served Debian N: version is refused by name' -- ceiling --kind deb --published "$d/ep-deb-served" --new "$d/ep-none"
  expect 1 'RED ceiling: rpm: py3-proto 1:0.6.0-1.fc45 (noarch, staged) carries Epoch 1: no epochs (owner rule); prune and release a new version' \
    'epochs: a staged rpm Epoch is refused by name' -- ceiling --kind rpm --published "$d/ep-rpm-none" --new "$d/ep-rpm-new"
  expect 1 'py3-proto 3:0.5.0-1.fc45 (noarch, served) carries Epoch 3: no epochs (owner rule)' \
    'epochs: a served rpm Epoch is refused by name' -- ceiling --kind rpm --published "$d/ep-rpm-served" --new "$d/ep-rpm-none"

  # the source of a binary, read from the metadata: a deb Source field (its binNMU version dropped) or the Package name
  # when it is absent; an rpm SOURCERPM (the name before its version and release), none for a (none)
  python3 -I -B - "$gate" <<'PY' && ok 'source: deb Source field, absent -> the Package name; rpm SOURCERPM' || bad 'source: the source of a binary'
import importlib.util, sys
s = importlib.util.spec_from_file_location("gate", sys.argv[1]); g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
assert g.deb_source({"Package": "omx-clap-host", "Source": "omx-clap-core"}) == "omx-clap-core"
assert g.deb_source({"Package": "omx-clap-host", "Source": "omx-clap-core (0.32.5-1)"}) == "omx-clap-core"
assert g.deb_source({"Package": "omx-panel"}) == "omx-panel"
assert g.rpm_source_name("omx-clap-core-0.32.5-1.fc45.src.rpm") == "omx-clap-core"
assert g.rpm_source_name("(none)") is None
q = g.parse_rpm_query("@@omx-clap-host 0.32.5-1.fc45 x86_64 omx-clap-core-0.32.5-1.fc45.src.rpm\nrtld(GNU_HASH)\n@@old 1.0-1 noarch\n")
assert [p.source for p in q] == ["omx-clap-core", "old"], [p.source for p in q]
PY

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
  grep -qF 'HYGIENE: panel 0.9.1 depend on hostd' "$t/out" \
    && bad 'deb (hygiene): a floor-only published build is flagged (.github#102: floors only)' || ok 'deb (hygiene): a floor-only published build is not flagged'
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
  arm_deb_source
}

# SAME-PASS NAMES ARE SOURCES (plugin-hostd-protocol 0.6.0 dry run, 2026-11-19): the list named omx-clap-core, plugin-hostd and
# omx-panel, and the binaries those SOURCES build (omx-clap-host, libomx-panel-render-dev ...) stayed RED, with whatever
# installs through them. The gate reads the source of every binary from the channel's metadata (the Source: field, the Package
# name when absent) and a package whose only unmet requirement on its path is held by a same-pass binary is reported.
arm_deb_source() {
  command -v dose-debcheck >/dev/null || { bad 'deb source: dose-debcheck is not installed (apt-get install dose-distcheck)'; return; }
  local d=$t/debs; mkdir -p "$d/a/debian/bookworm" "$d/b/debian/bookworm" "$d/c/debian/bookworm"
  { stanza libc6 2.36-9 amd64; } > "$d/bg"
  # clap-host is built by the source clap-core; qualify installs through it and names no source (so it is its own)
  { stanza libproto0 0.4.4 amd64
    printf 'Package: clap-host\nSource: clap-core (0.30.6-1)\nVersion: 0.30.6\nArchitecture: amd64\nDepends: libproto0 (>= 0.4.4~), libproto0 (<< 0.5~)\n\n'
  } > "$d/a/debian/bookworm/Packages"
  { cat "$d/a/debian/bookworm/Packages"; stanza qualify 1.0 amd64 'clap-host (>= 0.30~), libproto0 (>= 0.4.4~)'; } > "$d/b/debian/bookworm/Packages"
  # the same, and an unrelated package capping the protocol too
  { cat "$d/b/debian/bookworm/Packages"; stanza unrelated 1.0 amd64 'libproto0 (>= 0.4.4~), libproto0 (<< 0.5~)'; } > "$d/c/debian/bookworm/Packages"
  stanza libproto0 0.5.0 amd64 > "$d/lib"
  local args=(--suite bookworm --arch amd64 --bg "$d/bg" --new-index "$d/lib")
  # (control) no same-pass: all three are red
  expect 1 'clap-host 0.30.6 was installable and is not' 'deb source: without a same-pass list the cap is red' -- deb --channel "$d/a" "${args[@]}"
  # (a) the SOURCE is listed, its binary is not named: reported, and nothing is red
  expect 0 'clap-host 0.30.6 is uninstallable until the rest of the pass (clap-host)' \
    'deb source: (a) a binary of a listed source is reported, not red' -- deb --channel "$d/a" "${args[@]}" --same-pass clap-core
  ! grep -qE '^(ERROR: |::error::)' "$t/out" && ok 'deb source: (a) ... and no line is an error' || bad 'deb source: (a) an error line'
  # (b) qualify names no same-pass package; it is broken only through clap-host, which the pass caps
  python3 -I "$gate" deb --channel "$d/b" "${args[@]}" --same-pass clap-core > "$t/out" 2>&1 || bad 'deb source: (b) the pass is not green'
  grep -F 'until the rest of the pass is released: apt-get install qualify fails' "$t/out" | grep -qF '(every unmet requirement on its path is held by clap-host, of the pass)' \
    && ok 'deb source: (b) a consumer broken only through a same-pass binary is reported' || bad 'deb source: (b) the consumer is not reported'
  # (c) an unrelated package caps the protocol too: not through any package of the pass, so red, and only it
  expect 1 'unrelated 1.0 was installable and is not' 'deb source: (c) a breakage outside the pass stays red' -- \
    deb --channel "$d/c" "${args[@]}" --same-pass clap-core
  grep -E '^(ERROR: |::error::)' "$t/out" | grep -qF unrelated && [ -z "$(grep -E '^(ERROR: |::error::)' "$t/out" | grep -vF unrelated)" ] \
    && ok 'deb source: (c) ... every red names unrelated alone, not clap-host nor qualify' || bad 'deb source: (c) a red is not unrelated'
  # (d) a same-pass entry that is neither a source nor a binary of the channel is refused by name, the rest still covered
  expect 1 'same-pass entry nosuch-repo is neither a source nor a binary package in the channel' \
    'deb source: (d) a same-pass repository name is refused by name' -- deb --channel "$d/a" "${args[@]}" --same-pass 'clap-core nosuch-repo'
  [ "$(grep -c 'same-pass entry' "$t/out")" = 1 ] && grep -qF 'uninstallable until the rest of the pass (clap-host)' "$t/out" \
    && ok 'deb source: (d) ... and the source is still covered' || bad 'deb source: (d) the refusal or the covering changed'
}

arm_deb_dryrun_version() {
  # a release dry run of a tree whose VERSION is already published: the run's own binaries must sort ABOVE the published
  # ones, or dose --latest 1 prunes them behind the release and refuses their dependents (omx-clap-core#126).
  command -v dose-debcheck >/dev/null || { bad 'deb dry-run version: dose-debcheck is not installed'; return; }
  local d=$t/debdry; mkdir -p "$d/channel/debian/trixie"
  { stanza libc6 2.36-9 arm64; } > "$d/bg"
  { stanza libcore1 0.32.5 arm64; stanza libcore-dev 0.32.5 arm64 'libcore1 (= 0.32.5)'; } > "$d/channel/debian/trixie/Packages"
  { stanza libcore1 0.32.5+git1795000000.abc1234 arm64; stanza libcore-dev 0.32.5+git1795000000.abc1234 arm64 'libcore1 (= 0.32.5+git1795000000.abc1234)'; } > "$d/plus"
  local args=(deb --channel "$d/channel" --suite trixie --arch arm64 --bg "$d/bg" --dry-run)
  expect 0 - 'deb dry-run version: 0.32.5+git... beside a published 0.32.5 is green' -- "${args[@]}" --new-index "$d/plus"
  # the workflow builds a dry run with +git (a staged run already does), a tag release with the clean version
  if grep -qF "separator: \${{ inputs.staged || !inputs.publish && '+git' || '~git' }}" "$here/.github/workflows/build-deb.yml"; then
    ok 'deb dry-run version: build-deb.yml builds a dry run as +git, above the published version'
  else bad 'deb dry-run version: build-deb.yml does not build a dry run as +git'; fi
}

arm_deb_unbuilt() {
  # a dry run that built amd64 only (release.yml arm: false): arm64 is judged only when the pass built an arm64 package
  command -v dose-debcheck >/dev/null || { bad 'deb unbuilt: dose-debcheck is not installed'; return; }
  local d=$t/debu; mkdir -p "$d/channel/debian/trixie"
  { stanza libc6 2.36-9 amd64; stanza libc6 2.36-9 arm64; } > "$d/bg"
  { stanza contract 0.4.4 all
    stanza libdsp-dev 0.4.4 amd64 'contract (>= 0.4.4~), contract (<< 0.5~)'
    stanza libdsp-dev 0.4.4 arm64 'contract (>= 0.4.4~), contract (<< 0.5~)'
  } > "$d/channel/debian/trixie/Packages"
  { stanza contract 0.5.0 all; stanza libdsp-dev 0.5.0 amd64 'contract (>= 0.5.0~), contract (<< 0.6~)'; } > "$d/amd64-only"
  { cat "$d/amd64-only"; stanza libdsp-dev 0.5.0 arm64 'contract (>= 0.5.0~), contract (<< 0.6~)'; } > "$d/both"
  { cat "$d/amd64-only"; stanza stale 1.0 arm64 'contract (<< 0.5~)'; } > "$d/arm64-stale"
  args=(deb --channel "$d/channel" --suite trixie --arch amd64 --arch arm64 --bg "$d/bg")
  expect 0 'debian/trixie arm64: not built in this pass, not judged' \
    'deb unbuilt: an amd64-only pass is not judged on arm64 against its stale packages' -- "${args[@]}" --dry-run --new-index "$d/amd64-only"
  expect 1 'RED deb: debian/trixie arm64: ' 'deb unbuilt: a REAL publish of an amd64-only pass is still judged on arm64, red on the stale pin' -- \
    "${args[@]}" --new-index "$d/amd64-only"
  expect 1 'RED deb: debian/trixie arm64: ' 'deb unbuilt: a pass that built arm64 is still judged on it, red on the stale candidate' -- \
    "${args[@]}" --new-index "$d/arm64-stale"
  expect 0 - 'deb unbuilt: a pass that built both and fits is green' -- "${args[@]}" --new-index "$d/both"
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
  grep -qF 'HYGIENE: hostd 0.17.0-1.fc44 depend on libproto' "$t/out" \
    && bad 'rpm (hygiene): a floor-only old build is flagged (.github#102: floors only)' || ok 'rpm (hygiene): a floor-only old build is not flagged'
  expect 0 - 'rpm: a patch inside the ceiling is green' -- "${args[@]}" --new-dir "$d/new-patch"
  grep -qF 'already-broken 1.0-1.fc44.noarch was already uninstallable before' "$t/out" && ok 'rpm: a package broken before is reported, not red' \
    || bad 'rpm: the earlier breakage is not reported'
  expect 0 - 'rpm: the whole pass in one release is green' -- "${args[@]}" --new-dir "$d/new-pass"
  # a pulled tree: channel-pull removes the dnf metadata, and the gate still measures the bytes it holds
  cp -a "$d/channel" "$d/pulled"; find "$d/pulled" -type d -name repodata -prune -exec rm -rf {} +
  expect 0 - 'rpm: a pulled tree without dnf metadata is measured, green for the whole pass' -- \
    rpm --channel "$d/pulled" --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new-pass"
  expect 1 'clap-host 0.30.6-1.fc44.noarch was installable and is not' 'rpm: ... and red for the library alone' -- \
    rpm --channel "$d/pulled" --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new-alone"
  [ ! -e "$d/pulled/fedora/44/noarch/repodata" ] && ok 'rpm: ... leaving the pulled tree without metadata' || bad 'rpm: the gate wrote into the pulled tree'
  expect 2 'could not take the measurement' 'rpm: a repository that cannot be read is not a pass' -- \
    rpm --channel "$d/nowhere" --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new-patch"
  arm_rpm_unbuilt "$d"
  arm_rpm_quick
  arm_rpm_source
}

arm_rpm_source() {
  for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || { bad "rpm source: $tool is not installed"; return; }; done
  local d=$t/rpms; mkdir -p "$d/top" "$d/a/fedora/44/noarch" "$d/a/fedora/44/x86_64" "$d/b/fedora/44/noarch" "$d/b/fedora/44/x86_64" "$d/c/fedora/44/noarch" "$d/c/fedora/44/x86_64" "$d/new" "$d/empty"
  mks() { # source binary version requires... ; the source's spec builds the binary as a subpackage, so its SOURCERPM names the source
    local src=$1 n=$2 v=$3; shift 3
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\nBuildArch: noarch\n' "$src" "$v"
      [ "$n" != "$src" ] || for r in "$@"; do printf 'Requires: %s\n' "$r"; done
      printf '%%description\nt\n'
      if [ "$n" != "$src" ]; then
        printf '%%package -n %s\nSummary: t\n' "$n"
        for r in "$@"; do printf 'Requires: %s\n' "$r"; done
        printf '%%description -n %s\nt\n%%files -n %s\n' "$n" "$n"
      fi
      printf '%%files\n'; } > "$d/top/$src-$n-$v.spec"
    rpmbuild -bb -D "_topdir $d/top" -D 'dist .fc44' "$d/top/$src-$n-$v.spec" >/dev/null 2>&1 || { echo "rpmbuild $n $v failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc44.noarch.rpm"
  }
  local ch lib_rpm; lib_rpm=$(mks libproto libproto 0.4.4)
  for ch in a b c; do cp "$lib_rpm" "$d/$ch/fedora/44/noarch/"; done
  # clap-host is built by the source clap-core; qualify installs through it and is its own source
  local ch_rpm; ch_rpm=$(mks clap-core clap-host 0.30.6 '(libproto >= 0.4.4 with libproto < 0.5)')
  local q_rpm; q_rpm=$(mks qualify qualify 1.0 'clap-host >= 0.30' 'libproto >= 0.4.4')
  local u_rpm; u_rpm=$(mks unrelated unrelated 1.0 '(libproto >= 0.4.4 with libproto < 0.5)')
  cp "$ch_rpm" "$d/a/fedora/44/noarch/"; cp "$ch_rpm" "$q_rpm" "$d/b/fedora/44/noarch/"; cp "$ch_rpm" "$q_rpm" "$u_rpm" "$d/c/fedora/44/noarch/"
  cp "$(mks libproto libproto 0.5.0)" "$d/new/"
  for ch in a b c; do createrepo_c -q "$d/$ch/fedora/44/x86_64"; createrepo_c -q "$d/$ch/fedora/44/noarch"; done
  local args=(rpm --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new")
  expect 1 'clap-host 0.30.6-1.fc44.noarch was installable and is not' 'rpm source: without a same-pass list the cap is red' -- \
    "${args[@]}" --channel "$d/a"
  # (a) the SOURCE is listed, its binary is not named: reported, and nothing is red
  expect 0 'clap-host 0.30.6-1.fc44.noarch is uninstallable until the rest of the pass (clap-host)' \
    'rpm source: (a) a binary of a listed source is reported, not red' -- "${args[@]}" --channel "$d/a" --same-pass clap-core
  ! grep -qE '^(ERROR: |::error::)' "$t/out" && ok 'rpm source: (a) ... and no line is an error' || bad 'rpm source: (a) an error line'
  # (b) qualify names no same-pass package; it is broken only through clap-host, which the pass caps
  python3 -I "$gate" "${args[@]}" --channel "$d/b" --same-pass clap-core > "$t/out" 2>&1 || bad 'rpm source: (b) the pass is not green'
  grep -qF 'until the rest of the pass is released: installing qualify falls back to libproto 0.4.4-1.fc44, not its newest 0.5.0-1.fc44' "$t/out" \
    && grep -F 'installing qualify falls back' "$t/out" | grep -qF '(every unmet requirement on its path is held by clap-host, of the pass)' \
    && ok 'rpm source: (b) a consumer broken only through a same-pass binary is reported' || bad 'rpm source: (b) the consumer is not reported'
  # (c) an unrelated package caps the protocol too: not through any package of the pass, so red
  expect 1 'unrelated 1.0-1.fc44.noarch was installable and is not' 'rpm source: (c) a breakage outside the pass stays red' -- \
    "${args[@]}" --channel "$d/c" --same-pass clap-core
  grep -E '^(ERROR: |::error::)' "$t/out" | grep -qF unrelated && [ -z "$(grep -E '^(ERROR: |::error::)' "$t/out" | grep -vF unrelated)" ] \
    && ok 'rpm source: (c) ... every red names unrelated alone, not clap-host nor qualify' || bad 'rpm source: (c) a red is not unrelated'
  # (d) a same-pass entry that is neither a source nor a binary of the channel is refused by name, the rest still covered
  expect 1 'same-pass entry nosuch-repo is neither a source nor a binary package in the channel' \
    'rpm source: (d) a same-pass repository name is refused by name' -- "${args[@]}" --channel "$d/a" --same-pass 'clap-core nosuch-repo'
  [ "$(grep -c 'same-pass entry' "$t/out")" = 1 ] && grep -qF 'uninstallable until the rest of the pass (clap-host)' "$t/out" \
    && ok 'rpm source: (d) ... and the source is still covered' || bad 'rpm source: (d) the refusal or the covering changed'
}

# A QUICK RELEASE NEVER REACHES A TREE OUTSIDE THE QUICK SET (omx-dsp 0.32.1, 2026-11-14). The quick set builds fc44 and
# fc45 x86_64; its noarch omx-dsp-contract 0.32.1 needs omx-dsp-devel 0.32.1, which no aarch64 tree serves. Placed in
# fedora/<release>/noarch, which dnf reads on every architecture, it made the aarch64 cells uninstallable and the check
# refused them. Under MATRIX_SET=quick the publish places a noarch package in the quick set's architecture trees of its
# release (release-matrix/quick.txt) and the check judges only the quick cells: the other trees stay as served.
arm_rpm_quick() {
  for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || { bad "rpm_quick: $tool is not installed"; return; }; done
  local d=$t/quick rel arch out rc; mkdir -p "$d/top" "$d/new" "$d/empty"
  local pub=$here/.github/actions/publish-rpms/publish-tree.sh run=$here/.github/actions/channel-installability/run.sh
  mkq() { # name version arch release requires...
    local n=$1 v=$2 arch=$3 r=$4; shift 4
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\n' "$n" "$v"
      [ "$arch" != noarch ] || printf 'BuildArch: noarch\n'
      for q in "$@"; do printf 'Requires: %s\n' "$q"; done
      printf '%%description\nt\n%%changelog\n* Sat Nov 14 2026 t <t@t> - %s-1\n- t\n%%files\n' "$v"; } > "$d/top/$n-$v-$arch-$r.spec"
    rpmbuild -bb --target "$arch" -D "_topdir $d/top" -D "dist .fc$r" -D 'debug_package %{nil}' "$d/top/$n-$v-$arch-$r.spec" >/dev/null 2>&1 \
      || { echo "rpmbuild $n $v $arch fc$r failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc$r.$arch.rpm"
  }
  for rel in 45; do
    local c=$d/channel/fedora/$rel
    mkdir -p "$c/x86_64" "$c/aarch64" "$c/noarch" "$c/SRPMS"
    mv "$(mkq omx-dsp-contract 0.32.0 noarch $rel '(omx-dsp-devel >= 0.32.0 with omx-dsp-devel < 0.33)')" "$c/noarch/"
    mv "$(mkq omx-dsp-devel 0.32.0 x86_64 $rel)" "$c/x86_64/"
    mv "$(mkq omx-dsp-devel 0.32.0 aarch64 $rel)" "$c/aarch64/"
    mv "$(mkq omx-dsp-contract 0.32.1 noarch $rel '(omx-dsp-devel >= 0.32.1 with omx-dsp-devel < 0.33)')" "$d/new/"
    mv "$(mkq omx-dsp-devel 0.32.1 x86_64 $rel)" "$d/new/"
    for arch in x86_64 aarch64 noarch SRPMS; do createrepo_c -q "$c/$arch"; done
  done
  # the check, as a release run of the quick set runs it: the quick cells judged, every other one named and left out
  rc=0; MATRIX_SET=quick REPOSDIR=$d/empty "$run" rpm "$d/new" "$d/channel" > "$t/out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then ok 'rpm_quick: the check of a quick release is green'
  else bad "rpm_quick: the check of a quick release exits $rc"; sed 's/^/     /' "$t/out" | tail -15; fi
  for rel in 45; do
    grep -qF "fedora/$rel aarch64: outside the cells of the set, not judged" "$t/out" && ! grep -q "fedora/$rel aarch64: [0-9]* new" "$t/out" \
      && ok "rpm_quick: ... fedora/$rel aarch64 is named and not judged" || bad "rpm_quick: fedora/$rel aarch64 was judged or not named"
    grep -q "^fedora/$rel x86_64: 2 new" "$t/out" && ok "rpm_quick: ... fedora/$rel x86_64 is judged" || bad "rpm_quick: fedora/$rel x86_64 was not judged"
  done
  # the publish of the quick release, unsigned, on a copy of the channel
  cp -a "$d/channel" "$d/tree"
  (cd "$d/tree" && find fedora -name '*.rpm' ! -path '*/x86_64/*' | sort) > "$d/frozen.before"
  rc=0; MATRIX_SET=quick "$pub" "$d/tree" "$d/new" > "$t/out" 2>&1 || rc=$?
  [ "$rc" = 0 ] && ok 'rpm_quick: the publish of a quick release places its packages' || { bad "rpm_quick: the publish exits $rc"; sed 's/^/     /' "$t/out" | tail -15; return; }
  for rel in 45; do
    [ -f "$d/tree/fedora/$rel/x86_64/omx-dsp-contract-0.32.1-1.fc$rel.noarch.rpm" ] && [ ! -e "$d/tree/fedora/$rel/noarch/omx-dsp-contract-0.32.1-1.fc$rel.noarch.rpm" ] \
      && ok "rpm_quick: ... the noarch contract lands in fedora/$rel/x86_64 alone, never in fedora/$rel/noarch" \
      || bad "rpm_quick: the noarch contract of fc$rel is at $(cd "$d/tree" && find fedora -name "omx-dsp-contract-0.32.1-*fc$rel*")"
  done
  (cd "$d/tree" && find fedora -name '*.rpm' ! -path '*/x86_64/*' | sort) > "$d/frozen.after"
  cmp -s "$d/frozen.before" "$d/frozen.after" && ok 'rpm_quick: ... the aarch64 and noarch trees hold what they served' \
    || bad "rpm_quick: the trees outside the quick set changed: $(diff "$d/frozen.before" "$d/frozen.after" | grep '^[<>]' | tr '\n' ' ')"
  # what a machine of each architecture sees after the publish: every package installs, the newest contract on x86_64
  for rel in 45; do
    for arch in aarch64 x86_64; do
      rc=0
      dnf --setopt=reposdir="$d/empty" --releasever=$rel --forcearch=$arch --setopt='*.gpgcheck=0' \
        --repofrompath=a,"$d/tree/fedora/$rel/$arch" --repofrompath=n,"$d/tree/fedora/$rel/noarch" \
        repoclosure --newest --check=a,n --arch=$arch --arch=noarch > "$t/out" 2>&1 || rc=$?
      [ "$rc" = 0 ] && ok "rpm_quick: ... a fedora $rel $arch machine installs every package the channel serves it" \
        || { bad "rpm_quick: fedora $rel $arch does not install after the quick publish"; sed 's/^/     /' "$t/out" | tail -8; }
    done
  done
}

# A dry run builds x86_64 only (omx-plugins 0.19.2): its noarch contract 0.19.2 replaces 0.19.1 on aarch64 too, where the
# published plug 0.19.1 pins contract 0.19.1 and the dry run built no plug. Without --unbuilt-arch-pass that is red; with
# it, plug (built on x86_64) counts as released in the same pass on aarch64, and a real break on x86_64 stays red.
arm_rpm_unbuilt() {
  local d=$1/unbuilt; mkdir -p "$d/top" "$d/new" "$d/new-broken" "$d/empty"
  local c=$d/channel/fedora/44
  mkdir -p "$c/x86_64" "$c/aarch64" "$c/noarch"
  mka() { # name version arch requires... ; noarch, or an arch-specific package with no files
    local n=$1 v=$2 arch=$3; shift 3
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\n' "$n" "$v"
      [ "$arch" != noarch ] || printf 'BuildArch: noarch\n'
      for r in "$@"; do printf 'Requires: %s\n' "$r"; done
      printf '%%description\nt\n%%files\n'; } > "$d/top/$n-$v-$arch.spec"
    rpmbuild -bb --target "$arch" -D "_topdir $d/top" -D 'dist .fc44' -D 'debug_package %{nil}' "$d/top/$n-$v-$arch.spec" >/dev/null 2>&1 \
      || { echo "rpmbuild $n $v $arch failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc44.$arch.rpm"
  }
  mv "$(mka plug-contract 0.19.1 noarch)" "$c/noarch/"
  mv "$(mka plug 0.19.1 x86_64 'plug-contract = 0.19.1-1.fc44')" "$c/x86_64/"
  mv "$(mka plug 0.19.1 aarch64 'plug-contract = 0.19.1-1.fc44')" "$c/aarch64/"
  mv "$(mka plug-contract 0.19.2 noarch)" "$d/new/"
  mv "$(mka plug 0.19.2 x86_64 'plug-contract = 0.19.2-1.fc44')" "$d/new/"
  for r in x86_64 aarch64 noarch; do createrepo_c -q "$c/$r"; done
  local args=(rpm --channel "$d/channel" --fedora 44 --arch x86_64 --arch aarch64 --reposdir "$d/empty" --no-newest)
  expect 1 'fedora/44 aarch64: plug 0.19.1-1.fc44.aarch64 was installable and is not' \
    'rpm (dry run): a noarch contract bumped with aarch64 not built is red without --unbuilt-arch-pass' -- "${args[@]}" --new-dir "$d/new"
  expect 0 'counted in the same pass' 'rpm (dry run): ... and green with it, aarch64 still checked' -- \
    "${args[@]}" --new-dir "$d/new" --unbuilt-arch-pass
  grep -qF 'fedora/44 aarch64: plug 0.19.1-1.fc44.aarch64 is uninstallable until the rest of the pass (plug)' "$t/out" \
    && ok 'rpm (dry run): ... naming aarch64 plug as the rest of the pass' || bad 'rpm (dry run): aarch64 not reported'
  # the newest arm, the same dry run (openmixer 0.2.0, #161): a new noarch app pins plug at the release's version, built on
  # x86_64 only; on aarch64 `dnf install plug-app` cannot resolve until the rest of the pass is released, which names plug
  # only in dnf's problem, never as the package installed. With --unbuilt-arch-pass that is a note; with no plug built at
  # all, it is red
  mkdir -p "$d/new-app" "$d/new-app-alone"
  cp "$d/new/"*.rpm "$d/new-app/"
  mv "$(mka plug-app 0.19.2 noarch 'plug = 0.19.2-1.fc44')" "$d/new-app/"
  cp "$d/new-app/plug-app-"*.rpm "$d/new-app/plug-contract-"*.rpm "$d/new-app-alone/"
  expect 0 'until the rest of the pass is released: dnf install plug-app does not resolve' \
    'rpm (dry run, newest): a noarch app pinning an arch package built on x86_64 only is a note on aarch64' -- \
    rpm --channel "$d/channel" --fedora 44 --arch x86_64 --arch aarch64 --reposdir "$d/empty" --new-dir "$d/new-app" --unbuilt-arch-pass
  expect 1 'RED rpm: fedora/44 x86_64 newest: dnf install plug-app does not resolve' \
    'rpm (dry run, newest): ... and red where no plug of the release was built at all' -- \
    rpm --channel "$d/channel" --fedora 44 --arch x86_64 --arch aarch64 --reposdir "$d/empty" --new-dir "$d/new-app-alone" --unbuilt-arch-pass
  # a consumer on the built architecture that the release does not rebuild is still red
  # (a channel of its own: dnf keeps what it read of a repository by its address)
  cp -a "$d/channel" "$d/channel-other"
  mv "$(mka other 1.0 x86_64 'plug-contract = 0.19.1-1.fc44')" "$d/channel-other/fedora/44/x86_64/"
  createrepo_c -q --update "$d/channel-other/fedora/44/x86_64"
  expect 1 'fedora/44 x86_64: other 1.0-1.fc44.x86_64 was installable and is not' \
    'rpm (dry run): a break on the built architecture stays red with --unbuilt-arch-pass' -- \
    rpm --channel "$d/channel-other" --fedora 44 --arch x86_64 --arch aarch64 --reposdir "$d/empty" --no-newest --new-dir "$d/new" --unbuilt-arch-pass
}

# A release package of this channel Requires another channel's release package (openmixer-release requires freereac-release): the
# dependency lives only in the external channel, declared in the one file the gate is given. Undeclared, the release is refused
# (the channel alone cannot meet it); declared, it passes; the external channel's own packages are read, never judged; a malformed
# declaration is not a pass.
arm_external_deb() {
  command -v dose-debcheck >/dev/null || { bad 'external deb: dose-debcheck is not installed (apt-get install dose-distcheck)'; return; }
  local d=$t/extdeb; mkdir -p "$d/channel/debian/trixie" "$d/ext/deb/debian/trixie" "$d/ext-none/deb"
  { stanza libc6 2.41-12 amd64; } > "$d/bg"
  { stanza openmixer-release 1-5 all; } > "$d/channel/debian/trixie/Packages"
  # the external channel carries the dependency, and a package of its own that does not install (never judged here)
  # (a served index carries Filename, Size and SHA256, which apt wants even to simulate an install)
  { stanza freereac-release 1-1 all; stanza ext-broken 1.0 all 'nothing-provides-this'; } |
    awk -v h="$(printf '0%.0s' $(seq 64))" '/^$/ {print "Filename: ./x.deb\nSize: 1\nSHA256: " h} {print}' > "$d/ext/deb/debian/trixie/Packages"
  stanza openmixer-release 1-6 all 'freereac-release' > "$d/new"
  printf '%s\n' '# test declaration' "freereac $d/ext" > "$d/declared"
  printf '%s\n' "freereac $d/ext-none" > "$d/declared-empty"
  printf '%s\n' 'not a declaration' > "$d/malformed"
  args=(deb --channel "$d/channel" --suite trixie --arch amd64 --bg "$d/bg" --new-index "$d/new")
  expect 1 'openmixer-release 1-6 is new and does not install' 'external deb: a dependency that lives only in an external channel is refused when none is declared' -- "${args[@]}"
  grep -qF 'freereac-release' "$t/out" && ok 'external deb: ... naming the dependency' || bad 'external deb: the dependency is not named'
  expect 0 - 'external deb: declared in the file, the same release passes' -- "${args[@]}" --external-channels "$d/declared"
  grep -qF 'ext-broken' "$t/out" && bad 'external deb: a package of the external channel was judged' || ok 'external deb: the external channel'"'"'s own broken package is never judged'
  expect 1 'external channel freereac' 'external deb: a declared channel that serves nothing is named, and the release stays refused' -- "${args[@]}" --external-channels "$d/declared-empty"
  expect 2 'is not' 'external deb: a malformed declaration is not a pass' -- "${args[@]}" --external-channels "$d/malformed"
}

arm_external_rpm() {
  for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || { bad "external rpm: $tool is not installed"; return; }; done
  dnf repoclosure --help >/dev/null 2>&1 || { bad 'external rpm: dnf repoclosure is not installed (dnf5-plugins)'; return; }
  local d=$t/extrpm; mkdir -p "$d/top" "$d/channel/fedora/44/x86_64" "$d/channel/fedora/44/noarch" "$d/new" "$d/empty" "$d/ext/rpm/fedora/44/x86_64" "$d/ext/rpm/fedora/44/noarch" "$d/ext-none/rpm"
  mk() { # name version requires... ; a noarch package with a .fc44 dist tag
    local n=$1 v=$2; shift 2
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\nBuildArch: noarch\n' "$n" "$v"
      for r in "$@"; do printf 'Requires: %s\n' "$r"; done
      printf '%%description\nt\n%%files\n'; } > "$d/top/$n-$v.spec"
    rpmbuild -bb -D "_topdir $d/top" -D 'dist .fc44' "$d/top/$n-$v.spec" >/dev/null 2>&1 || { echo "rpmbuild $n $v failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc44.noarch.rpm"
  }
  mv "$(mk openmixer-release 1)" "$d/channel/fedora/44/noarch/"
  # as the FreeREAC channel serves it: the release package is in its noarch tree, and the architecture tree holds other packages
  mv "$(mk freereac-release 1)" "$d/ext/rpm/fedora/44/noarch/"
  mv "$(mk ext-broken 1.0 'nothing-provides-this')" "$d/ext/rpm/fedora/44/x86_64/"
  mv "$(mk openmixer-release 2 'freereac-release')" "$d/new/"
  createrepo_c -q "$d/channel/fedora/44/x86_64"; createrepo_c -q "$d/channel/fedora/44/noarch"; createrepo_c -q "$d/ext/rpm/fedora/44/x86_64"; createrepo_c -q "$d/ext/rpm/fedora/44/noarch"
  printf '%s\n' '# test declaration' "freereac $d/ext" > "$d/declared"
  printf '%s\n' "freereac $d/ext-none" > "$d/declared-empty"
  printf '%s\n' 'not a declaration' > "$d/malformed"
  args=(rpm --channel "$d/channel" --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new")
  expect 1 'openmixer-release 2-1.fc44.noarch is new and does not install' 'external rpm: a dependency that lives only in an external channel is refused when none is declared' -- "${args[@]}"
  grep -qF 'freereac-release' "$t/out" && ok 'external rpm: ... naming the dependency' || bad 'external rpm: the dependency is not named'
  expect 0 - 'external rpm: declared in the file, the same release passes' -- "${args[@]}" --external-channels "$d/declared"
  grep -qF 'ext-broken' "$t/out" && bad 'external rpm: a package of the external channel was judged' || ok 'external rpm: the external channel'"'"'s own broken package is never judged'
  expect 1 'external channel freereac' 'external rpm: a declared channel that serves nothing is named, and the release stays refused' -- "${args[@]}" --external-channels "$d/declared-empty"
  expect 2 'is not' 'external rpm: a malformed declaration is not a pass' -- "${args[@]}" --external-channels "$d/malformed"
}

# The client path of openmixer-release Requiring freereac-release: an existing client has ONLY the OpenMixer channel enabled. The channel must
# serve freereac-release itself (mirror-freereac-release): without it the release is refused by the gate and a client's upgrade would break;
# with it, the gate passes with NO external channel declared, and on a clean root with the OpenMixer repositories alone `dnf upgrade
# openmixer-release` pulls freereac-release in (whose repository then serves reac-pw).
arm_mirror_client() {
  for tool in rpmbuild createrepo_c dnf; do command -v $tool >/dev/null || { bad "mirror client: $tool is not installed"; return; }; done
  dnf repoclosure --help >/dev/null 2>&1 || { bad 'mirror client: dnf repoclosure is not installed (dnf5-plugins)'; return; }
  local d=$t/mirror; mkdir -p "$d/top" "$d/with/fedora/44/x86_64" "$d/with/fedora/44/noarch" "$d/without/fedora/44/x86_64" "$d/without/fedora/44/noarch" "$d/new" "$d/empty"
  mk() { # name version requires... ; a noarch package with a .fc44 dist tag
    local n=$1 v=$2; shift 2
    { printf 'Name: %s\nVersion: %s\nRelease: 1%%{?dist}\nSummary: t\nLicense: MIT\nBuildArch: noarch\n' "$n" "$v"
      for r in "$@"; do printf 'Requires: %s\n' "$r"; done
      printf '%%description\nt\n%%files\n'; } > "$d/top/$n-$v.spec"
    rpmbuild -bb -D "_topdir $d/top" -D 'dist .fc44' "$d/top/$n-$v.spec" >/dev/null 2>&1 || { echo "rpmbuild $n $v failed" >&2; return 1; }
    find "$d/top/RPMS" -name "$n-$v-1.fc44.noarch.rpm"
  }
  local old; old=$(mk openmixer-release 7); cp "$old" "$d/with/fedora/44/noarch/"; cp "$old" "$d/without/fedora/44/noarch/"
  mv "$(mk freereac-release 1)" "$d/with/fedora/44/noarch/"
  mv "$(mk openmixer-release 8 'freereac-release >= 1')" "$d/new/"
  for c in with without; do createrepo_c -q "$d/$c/fedora/44/x86_64"; createrepo_c -q "$d/$c/fedora/44/noarch"; done
  local args=(rpm --fedora 44 --arch x86_64 --reposdir "$d/empty" --new-dir "$d/new")
  expect 1 'openmixer-release 8-1.fc44.noarch is new and does not install' 'mirror client: without freereac-release in the channel (and none declared) the release is refused' -- "${args[@]}" --channel "$d/without"
  expect 0 - 'mirror client: with freereac-release in the channel, the gate passes with no external channel declared' -- "${args[@]}" --channel "$d/with"
  # a clean root, only the OpenMixer repositories (the channel after the release): install the old release package, then upgrade it
  cp "$d/new/"*.rpm "$d/with/fedora/44/noarch/"; createrepo_c -q "$d/with/fedora/44/noarch"
  local root=$d/root; mkdir -p "$root"
  printf '[openmixer]\nname=openmixer\nbaseurl=file://%s/fedora/44/x86_64/\nenabled=1\ngpgcheck=0\n[openmixer-noarch]\nname=openmixer-noarch\nbaseurl=file://%s/fedora/44/noarch/\nenabled=1\ngpgcheck=0\n' "$d/with" "$d/with" > "$d/openmixer.repo"
  mkdir -p "$d/repos"; cp "$d/openmixer.repo" "$d/repos/"
  local dnfc=(dnf -y -q --installroot="$root" --setopt=reposdir="$d/repos" --releasever=44 --forcearch=x86_64 --setopt=install_weak_deps=False)
  "${dnfc[@]}" install openmixer-release-7 >/dev/null 2>&1 || { bad 'mirror client: the old openmixer-release does not install on the clean root'; return; }
  if rpm --root "$root" -q freereac-release >/dev/null 2>&1; then bad 'mirror client: freereac-release was on the clean root before the upgrade'; return; fi
  "${dnfc[@]}" upgrade openmixer-release >/dev/null 2>&1 || { bad 'mirror client: dnf upgrade openmixer-release failed with only the OpenMixer channel'; return; }
  rpm --root "$root" -q openmixer-release-8 freereac-release >/dev/null 2>&1 && ok 'mirror client: dnf upgrade openmixer-release pulls freereac-release from the OpenMixer channel alone' \
    || bad 'mirror client: the upgrade did not install openmixer-release 8 and freereac-release'
}

arm_deb_cells() {
  # a deb run whose cells leave NO suite judged (the cell names only suites this run neither serves nor built) reads no
  # metadata, so a same-pass name has nothing to match: it is not refused as unknown (a false red); a note says so
  local d=$t/cells; mkdir -p "$d/a/debian/bookworm"
  { stanza libc6 2.36-9 amd64; } > "$d/bg"
  { stanza libproto0 0.4.4 amd64; } > "$d/a/debian/bookworm/Packages"
  stanza libproto0 0.5.0 amd64 > "$d/lib"
  expect 0 'same-pass names not checked: no suite judged' \
    'deb cells: no suite judged, the same-pass names are not refused' -- \
    deb --channel "$d/a" --suite bookworm --arch amd64 --bg "$d/bg" --new-index "$d/lib" --cell trixie/amd64 --same-pass 'clap-core nosuch-repo'
  ! grep -q 'same-pass entry' "$t/out" && ok 'deb cells: ... and no entry is named' || bad 'deb cells: a same-pass entry is refused with no suite read'
}

arms=("$@")
if [ ${#arms[@]} = 0 ]; then
  arms=(ceiling deb_cells)
  command -v dose-debcheck >/dev/null && arms+=(deb deb_unbuilt deb_dryrun_version external_deb)
  command -v createrepo_c >/dev/null && command -v rpmbuild >/dev/null && arms+=(rpm external_rpm mirror_client)
fi
for arm in "${arms[@]}"; do "arm_$arm"; done
[ "$fail" = 0 ] && echo "channel-installability (${arms[*]}): ok" || echo "channel-installability (${arms[*]}): FAILED"
exit "$fail"
