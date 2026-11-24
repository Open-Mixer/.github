#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A quick release's noarch package that needs no architecture is served to every architecture (Open-Mixer/.github#267).
# Run 45459465038: the fc45 aarch64 cell installed omx-contract-devel 3.19.1 from 'openmixer-noarch' while x86_64 got
# 3.21.0 from 'openmixer' (jobs 138685304544, 138685304854): every quick release since 3.20.0 had placed its noarch
# packages in fedora/45/x86_64 alone, so the aarch64 view (fedora/45/aarch64 + fedora/45/noarch) never saw them.
#
# The fixture is that channel in small: fc45 with an aarch64 tree, omx-contract 3.19.1 (all noarch then) in noarch, then a
# quick run of 3.21.0 whose omx-contract is now x86_64 and whose -data and -devel stay noarch; beside it omx-dsp, whose
# noarch omx-dsp-contract requires the x86_64 omx-dsp-devel (the 2026-11-14 case that put noarch in the quick trees).
# Proves, with dnf's own answer for each architecture view (dnf5 repoquery --forcearch over the two directories):
#   - the quick run puts omx-contract-data and -devel 3.21.0 in fedora/45/noarch, and the aarch64 view's newest
#     omx-contract-devel is 3.21.0 (red before the fix: 3.19.1);
#   - omx-dsp-contract stays in fedora/45/x86_64 alone, and the aarch64 view does not offer it;
#   - the check: a publish whose placement leaves omx-contract-devel in the x86_64 tree alone (the old placement, forced
#     by a copy of the actions) is refused, naming the package and both views' newest builds, and nothing is signed;
#   - a full run (MATRIX_SET=full) of the same packages passes the check.
#
#   noarch-every-arch-view.sh   in a Fedora container with rpm-build rpm-sign createrepo_c python3-rpm gnupg2 pinentry findutils zstd dnf5
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${NOARCH_VIEW_ACTIONS:-$here/.github/actions}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Release <release@example.org>' ed25519 sign 1y
key=$(gpg --batch --with-colons --fingerprint release@example.org | awk -F: '/^fpr:/ {print $10; exit}')
printf '%s packages throwaway\n' "$key" > "$work/pinned.txt"
export PINNED_FINGERPRINTS=$work/pinned.txt
mkdir -p "$work/no-committed"
export SERVED_KEYS_DIR=$work/no-committed
tree=$work/tree

spec() { # <file> <lines...>
    local f=$1; shift
    printf '%s\n' "$@" > "$f"
}
build() { # <spec> <out dir> <arch>
    local id
    id=$(basename "$1" .spec)-$3
    rpmbuild -bb --quiet --define "_topdir $work/rb-$id" --define 'dist %{nil}' --define 'debug_package %{nil}' \
        --target "$3" "$1" >/dev/null 2>&1 || fail "rpmbuild $id"
    mkdir -p "$2"
    find "$work/rb-$id" -name '*.rpm' -exec cp {} "$2/" \;
}
# omx-contract <version> <arch of the main package>: -data noarch, -devel noarch requiring -data exactly
contract() {
    local main=()
    [ "$2" = noarch ] && main=('BuildArch: noarch')
    spec "$work/omx-contract-$1.spec" 'Name: omx-contract' "Version: $1" 'Release: 1.fc45' 'Summary: t' 'License: MIT' \
        ${main[@]+"${main[@]}"} "Requires: omx-contract-data = $1-1.fc45" '%description' 'c' \
        '%package data' 'Summary: t' 'BuildArch: noarch' '%description data' 'd' \
        '%package devel' 'Summary: t' 'BuildArch: noarch' "Requires: omx-contract-data = $1-1.fc45" '%description devel' 'd' \
        '%files' '%files data' '%files devel'
    echo "$work/omx-contract-$1.spec"
}
dsp() { # omx-dsp 0.34.0: omx-dsp-devel x86_64, omx-dsp-contract noarch requiring it exactly
    spec "$work/omx-dsp.spec" 'Name: omx-dsp' 'Version: 0.34.0' 'Release: 1.fc45' 'Summary: t' 'License: MIT' '%description' 'c' \
        '%package devel' 'Summary: t' '%description devel' 'd' \
        '%package -n omx-dsp-contract' 'Summary: t' 'BuildArch: noarch' 'Requires: omx-dsp-devel = 0.34.0-1.fc45' \
        '%description -n omx-dsp-contract' 'd' '%files' '%files devel' '%files -n omx-dsp-contract'
    echo "$work/omx-dsp.spec"
}
newest() { # <arch> <package>: the newest version-release dnf offers in that architecture's view, or none
    dnf5 repoquery -q --forcearch="$1" --disablerepo='*' --setopt=cachedir="$work/dnf-$1" --setopt=reposdir=/dev/null \
        --repofrompath="a,file://$tree/fedora/45/$1" --repofrompath="n,file://$tree/fedora/45/noarch" \
        --setopt=a.gpgcheck=0 --setopt=n.gpgcheck=0 --latest-limit=1 --qf '%{version}-%{release}\n' "$2" 2>/dev/null |
        sort -u | head -1
}
publish() { # <actions> <matrix set> <rpm dir>
    MATRIX_SET=$2 REPO_FILE=$here/packaging/openmixer-release/openmixer.repo "$1/publish-rpms/publish-tree.sh" "$tree" "$3" "$key"
}

# ---- the channel before the quick wave: 3.19.1 all noarch, and an aarch64 tree that serves something
build "$(contract 3.19.1 noarch)" "$work/r0" noarch
spec "$work/libfoo.spec" 'Name: libfoo' 'Version: 1' 'Release: 1.fc45' 'Summary: t' 'License: MIT' '%description' 'f' '%files'
build "$work/libfoo.spec" "$work/r0" x86_64
build "$work/libfoo.spec" "$work/r0" aarch64
publish "$actions" full "$work/r0" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture channel could not be published"; }
cp -a "$tree" "$work/tree0"
restore() { rm -rf "$tree" "$work"/dnf-*; cp -a "$work/tree0" "$tree"; }
[ "$(newest aarch64 omx-contract-devel)" = 3.19.1-1.fc45 ] || fail "the fixture's aarch64 view does not serve omx-contract-devel 3.19.1 (dnf: '$(newest aarch64 omx-contract-devel)')"
ok "self-test: dnf reads the fixture's aarch64 view (omx-contract-devel 3.19.1)"

# the quick run: omx-contract 3.21.0 (main package x86_64 now) and omx-dsp 0.34.0, built for x86_64 alone
build "$(contract 3.21.0 x86_64)" "$work/r1" x86_64
build "$(dsp)" "$work/r1" x86_64

# ---- 1. the quick run: what needs no architecture reaches every view, what needs one stays in the quick trees
restore
publish "$actions" quick "$work/r1" > "$work/log" 2>&1 || { cat "$work/log"; fail "the quick run of omx-contract 3.21.0 was refused"; }
for p in omx-contract-data omx-contract-devel; do
    [ -f "$tree/fedora/45/noarch/$p-3.21.0-1.fc45.noarch.rpm" ] || { cat "$work/log"; ls -R "$tree/fedora/45"; fail "$p 3.21.0 is not in fedora/45/noarch"; }
done
x86=$(newest x86_64 omx-contract-devel) arm=$(newest aarch64 omx-contract-devel)
[ "$arm" = 3.21.0-1.fc45 ] || fail "the aarch64 view offers omx-contract-devel '$arm', not 3.21.0 (x86_64: '$x86')"
[ "$x86" = 3.21.0-1.fc45 ] || fail "the x86_64 view offers omx-contract-devel '$x86', not 3.21.0"
ok "quick run: omx-contract-devel newest per view, dnf: x86_64 $x86, aarch64 $arm (fedora/45/noarch)"
[ -f "$tree/fedora/45/x86_64/omx-dsp-contract-0.34.0-1.fc45.noarch.rpm" ] || fail "omx-dsp-contract is not in the x86_64 tree"
[ ! -e "$tree/fedora/45/noarch/omx-dsp-contract-0.34.0-1.fc45.noarch.rpm" ] || fail "omx-dsp-contract, which needs the x86_64 omx-dsp-devel, went into fedora/45/noarch"
[ -z "$(newest aarch64 omx-dsp-contract)" ] || fail "the aarch64 view offers omx-dsp-contract, which no aarch64 omx-dsp-devel can satisfy"
grep -q 'quick trees alone for omx-dsp-contract-0.34.0-1.fc45.noarch.rpm: it needs an architecture' "$work/log" || { cat "$work/log"; fail "the log does not say why omx-dsp-contract stays in the quick trees"; }
ok "quick run: omx-dsp-contract (needs omx-dsp-devel, x86_64) stays in fedora/45/x86_64 alone, and the log says why"

# ---- 2. the check: the old placement (every noarch package in the quick trees) is refused, nothing signed
restore
cp -a "$actions" "$work/old-actions"
python3 -I - "$work/old-actions/publish-rpms/noarch-views.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    if len(argv) == 3 and argv[0] == "place":\n        return place(argv[1], argv[2])\n'
assert old in s
new = ('    if len(argv) == 3 and argv[0] == "place":\n'
       '        for root, _d, files in os.walk(argv[2]):\n'
       '            for f in files:\n'
       '                if f.endswith(".noarch.rpm"):\n'
       '                    print(f"{os.path.join(root, f)}\\tarch\\tthe old placement")\n'
       '        return 0\n')
open(p, "w").write(s.replace(old, new))
PY
if publish "$work/old-actions" quick "$work/r1" > "$work/log" 2>&1; then cat "$work/log"; fail "a publish that left omx-contract-devel 3.21.0 in the x86_64 tree alone passed"; fi
grep -q 'refused fedora/45: omx-contract-devel 3.21.0-1.fc45 is in fedora/45/x86_64 alone, and aarch64' "$work/log" || { cat "$work/log"; fail "the refusal does not name omx-contract-devel and aarch64"; }
grep -q 'aarch64 3.19.1-1.fc45, x86_64 3.21.0-1.fc45' "$work/log" || { cat "$work/log"; fail "the refusal does not give each view's newest build"; }
! grep -q '^refused .*omx-dsp-contract' "$work/log" || { cat "$work/log"; fail "omx-dsp-contract, which needs an architecture, was refused"; }
grep -q 'nothing was signed' "$work/log" || { cat "$work/log"; fail "the refusal does not say nothing was signed"; }
for f in "$tree"/fedora/45/x86_64/omx-contract-*3.21.0*.rpm; do
    [ "$(rpm -qp --qf '%{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}' "$f" 2>/dev/null | sed 's/(none)//g')" = "" ] || fail "the refused run signed $(basename "$f")"
done
ok "check: the old placement is refused, naming omx-contract-devel and each view (aarch64 3.19.1, x86_64 3.21.0); nothing signed"

# ---- 3. a full run of the same packages passes the check (every noarch package in fedora/45/noarch)
restore
build "$(dsp)" "$work/r3" aarch64
cp "$work/r1"/*.rpm "$work/r3/"
build "$(contract 3.21.0 aarch64)" "$work/r3a" aarch64
cp "$work/r3a"/omx-contract-3.21.0-1.fc45.aarch64.rpm "$work/r3/"
publish "$actions" full "$work/r3" > "$work/log" 2>&1 || { cat "$work/log"; fail "a full run of the same packages was refused"; }
[ "$(newest aarch64 omx-dsp-contract)" = 0.34.0-1.fc45 ] || fail "the full run did not serve omx-dsp-contract to aarch64"
ok "full run: every view serves the same newest builds, the check passes"
echo "noarch-every-arch-view: all passed"
