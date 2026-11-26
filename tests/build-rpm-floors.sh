#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Generated lower-layer floors (.github#312): floors.sh apply gives every bare Requires of an installed OpenMixer
# package (from an openmixer* repository or a local file) ">= <installed version>" and leaves a third-party package, a
# versioned name, a macro, a capability, a rich dependency and an uninstalled name as they are; floors.sh check fails a
# built package requiring an OpenMixer package with no version and passes one with its floor. rpm and dnf are fakes.
# Sabotage: apply that writes no floor turns the omx-contract arm red.
#
#   tests/build-rpm-floors.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
F=$here/.github/actions/build-rpm/floors.sh
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; cat "$work/spec" >&2 2>/dev/null || true; exit 1; }
cat > "$work/rpm" <<'X'
#!/bin/bash
# installed: omx-contract 0.23.2 and omx-dsp-wasm 0.34.2 (openmixer), boot-contract 0.1.0 (@commandline), python3 3.14 (fedora)
if [ "$1" = -qp ]; then cat "${3}.requires"; exit 0; fi
case ${@: -1} in
  omx-contract) echo 0.23.2 ;; omx-dsp-wasm) echo 0.34.2 ;; boot-contract) echo 0.1.0 ;; python3) echo 3.14.0 ;;
  *) echo "package ${@: -1} is not installed"; exit 1 ;;
esac
X
cat > "$work/dnf" <<'X'
#!/bin/bash
case ${@: -1} in omx-contract|omx-dsp-wasm) echo openmixer-testing-noarch ;; boot-contract) echo @commandline ;; *) echo fedora ;; esac
X
chmod +x "$work/rpm" "$work/dnf"
export FLOORS_RPM=$work/rpm FLOORS_DNF=$work/dnf
cat > "$work/spec" <<'X'
Name: demo
Requires: omx-contract
Requires: omx-dsp-wasm, python3
Requires: boot-contract
Requires: omx-contract-data = %{version}-%{release}
Requires: pkgconfig(omx-contract)
Requires: (omx-contract or omx-dsp-wasm)
Requires: not-installed
BuildRequires: omx-contract
X
cp "$work/spec" "$work/spec.orig"
bash "$F" apply "$work/spec" > "$work/out"
grep -qx 'Requires: omx-contract >= 0.23.2' "$work/spec" || fail "the OpenMixer package got no floor"
grep -qx 'Requires: omx-dsp-wasm >= 0.34.2, python3' "$work/spec" || fail "a list: the OpenMixer name floored, the Fedora one left"
grep -qx 'Requires: boot-contract >= 0.1.0' "$work/spec" || fail "a local-file sibling (@commandline) got no floor"
for keep in 'Requires: omx-contract-data = %{version}-%{release}' 'Requires: pkgconfig(omx-contract)' \
    'Requires: (omx-contract or omx-dsp-wasm)' 'Requires: not-installed' 'BuildRequires: omx-contract'; do
    grep -qxF "$keep" "$work/spec" || fail "changed what it must leave: $keep"
done
grep -q 'floors: 3 generated' "$work/out" || fail "count line: $(cat "$work/out")"
echo "ok   apply: OpenMixer names floored at the installed version; the rest left as it is"

printf '%s\n' 'omx-contract' 'python3' 'libc.so.6()(64bit)' > "$work/bare.rpm.requires"
printf '%s\n' 'omx-contract >= 0.23.2' 'python3' > "$work/good.rpm.requires"
if bash "$F" check "$work/bare.rpm" > "$work/out" 2>&1; then fail "check passed a package requiring omx-contract bare"; fi
grep -q 'bare.rpm requires omx-contract with no version' "$work/out" || fail "check does not name it"
bash "$F" check "$work/good.rpm" > "$work/out" 2>&1 || fail "check refused a floored package: $(cat "$work/out")"
echo "ok   check: an unversioned OpenMixer requirement fails, a floored one passes"

# sabotage: an apply that floors nothing leaves omx-contract bare, and the arm above would go red
# shellcheck disable=SC2016 # the pattern is the script's own literal text
sed 's/rest+="${rest:+, }$w >= $v"/rest+="${rest:+, }$w"/' "$F" > "$work/sab.sh"
cp "$work/spec.orig" "$work/spec"; bash "$work/sab.sh" apply "$work/spec" >/dev/null
! grep -qx 'Requires: omx-contract >= 0.23.2' "$work/spec" || fail "the sabotage did not take"
echo "ok   sabotage: without the floor the apply arm goes red"
echo "build-rpm-floors.sh: all arms ok"
