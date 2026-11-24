#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A noarch package that a package of its own source pins exactly is never published ahead of an architecture the run did
# not build (Open-Mixer/.github#62, the rpm face of #59). The channel serves one noarch directory per Fedora release to
# every architecture, and dnf offers the newest noarch build; the arch binary left behind on an architecture the run did
# not build pins the older one (Requires: name = %{version}-%{release}) and no longer installs.
#
# The fixture is omx-clap-libs 0.32.4 on fc45, published by the real tree script with a throwaway key:
#   fc45 x86_64 and aarch64 omx-clap-libs 0.32.3, Requires omx-clap-contract = 0.32.3-1.fc45; noarch contract 0.32.3.
#   A release then brings x86_64 omx-clap-libs 0.32.4 and noarch omx-clap-contract 0.32.4.
# Proves:
#   - outside the quick set (MATRIX_SET full or unset) that release is refused before anything is placed or signed, naming the noarch package, the Fedora release, the
#     pinning package and the architecture it was not built for (aarch64); the tree is byte-identical after;
#   - as a release of the quick set it publishes, the contract into fedora/45/x86_64 alone: fedora/45/noarch and
#     fedora/45/aarch64 keep what they served, so aarch64 keeps omx-clap-libs 0.32.3 with its contract 0.32.3;
#   - the same release built for x86_64 and aarch64 publishes;
#   - a noarch placed BELOW the newest one of the release is not dnf's candidate and is not refused;
#   - on a channel with x86_64 0.32.4 and contract 0.32.4 served and aarch64 0.32.3 (older contract), the catch-up of
#     aarch64 0.32.4 (its rebuilt contract dropped as served) publishes, and aarch64 gets the served contract's bytes:
#     the refusal never stands in the way of the repair;
#   - a noarch nothing of its source pins exactly (a language pack) is published by a run of one architecture.
# Sabotage: NOARCH_PIN_ACTIONS names a copy of the actions with the refusal taken out; the first arm then goes red.
#
#   noarch-pin.sh     in a Fedora container with rpm-build rpm-sign createrepo_c python3-rpm gnupg2 pinentry findutils zstd diffutils
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${NOARCH_PIN_ACTIONS:-$here/.github/actions}
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

snapshot() { (cd "$tree" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$1"; }
# one spec, the way omx-clap-libs is built: the binary package and a noarch subpackage of the same source rpm, one build per
# architecture (each build writes the noarch subpackage again, under the same file name)
build() { # <out dir> <version> <arch> <subpackage> <op>   the binary package Requires "<subpackage> <op> <version>-1.fc45"
    local id=$2-$3-$4 spec
    spec=$work/$id.spec
    {
        printf '%s\n' 'Name: omx-clap-libs' "Version: $2" 'Release: 1.fc45' 'Summary: t' 'License: MIT' "Requires: omx-clap-$4 $5 $2-1.fc45" \
            '%description' 'core' '%package -n omx-clap-'"$4" 'Summary: t' 'BuildArch: noarch' '%description -n omx-clap-'"$4" "$4" '%files' '%files -n omx-clap-'"$4"
    } > "$spec"
    rpmbuild -bb --quiet --define "_topdir $work/rb-$id" --define 'dist %{nil}' --define 'debug_package %{nil}' \
        --target "$3" "$spec" >/dev/null 2>&1 || fail "rpmbuild $id"
    mkdir -p "$1"
    find "$work/rb-$id" -name '*.rpm' -exec cp {} "$1/" \;
}
core() { build "$1" "$2" "$3" contract =; }
publish() { CATCH_UP=${CU:-} MATRIX_SET=${SET:-full} "$actions/publish-rpms/publish-tree.sh" "$tree" "$1" "$key"; }
served() { [ -f "$tree/fedora/45/$1" ]; }

# ---- the channel before the quick release
core "$work/r0" 0.32.3 x86_64
core "$work/r0" 0.32.3 aarch64
SET=full publish "$work/r0" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture channel could not be published"; }
cp -a "$tree" "$work/tree0"

# ---- 1. a release of x86_64 alone outside the quick set: refused, nothing placed or signed
core "$work/r1" 0.32.4 x86_64
snapshot "$work/before"
if publish "$work/r1" > "$work/log" 2>&1; then cat "$work/log"; fail "a release built for x86_64 alone published omx-clap-contract 0.32.4 over aarch64's omx-clap-libs 0.32.3"; fi
grep -q '^refused omx-clap-contract-0.32.4-1.fc45.noarch.rpm in fedora/45: ' "$work/log" ||
    { cat "$work/log"; fail "the refusal does not name the noarch package and the Fedora release"; }
grep -q 'omx-clap-libs pins it exactly (= 0.32.4-1.fc45)' "$work/log" || { cat "$work/log"; fail "the refusal does not name the pinning package"; }
grep -q 'not built for aarch64' "$work/log" || { cat "$work/log"; fail "the refusal does not name the architecture left behind (aarch64)"; }
grep -q 'nothing was placed or signed' "$work/log" || { cat "$work/log"; fail "the refusal does not say nothing was placed or signed"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused release changed the tree"
ok "a release of x86_64 alone outside the quick set is refused: omx-clap-contract 0.32.4 would leave aarch64's omx-clap-libs 0.32.3 uninstallable"

# ---- 1q. the same release of the quick set: published into the quick tree alone, the other trees as served
list() { (cd "$tree/fedora/45" && find noarch aarch64 -name '*.rpm' | LC_ALL=C sort); }
list > "$work/outside.before"
SET=quick publish "$work/r1" > "$work/log" 2>&1 || { cat "$work/log"; fail "a quick release of x86_64 alone was refused"; }
served x86_64/omx-clap-contract-0.32.4-1.fc45.noarch.rpm || { cat "$work/log"; fail "the quick release did not place its contract in fedora/45/x86_64"; }
served noarch/omx-clap-contract-0.32.4-1.fc45.noarch.rpm && fail "the quick release placed its contract in fedora/45/noarch, which aarch64 reads"
list | cmp -s "$work/outside.before" - || fail "the quick release changed fedora/45/noarch or fedora/45/aarch64: $(list | diff "$work/outside.before" - | grep '^[<>]' | tr '\n' ' ')"
ok "a quick release of x86_64 alone publishes its contract into fedora/45/x86_64 alone; noarch and aarch64 keep what they served"
rm -rf "$tree"; cp -a "$work/tree0" "$tree"

# ---- 2. the same release built for x86_64 and aarch64: published
core "$work/r1" 0.32.4 aarch64
publish "$work/r1" > "$work/log" 2>&1 || { cat "$work/log"; fail "a release built for every architecture of the release was refused"; }
served noarch/omx-clap-contract-0.32.4-1.fc45.noarch.rpm || fail "omx-clap-contract 0.32.4 is not placed"
served x86_64/omx-clap-libs-0.32.4-1.fc45.x86_64.rpm && served aarch64/omx-clap-libs-0.32.4-1.fc45.aarch64.rpm || fail "omx-clap-libs 0.32.4 is not placed on both architectures"
ok "the same release built for x86_64 and aarch64 publishes"

# ---- 3. an older noarch than the release's newest is not dnf's candidate: published
rm -rf "$tree"; cp -a "$work/tree0" "$tree"
core "$work/r3" 0.32.2 x86_64
publish "$work/r3" > "$work/log" 2>&1 || { cat "$work/log"; fail "a noarch below the release's newest (not dnf's candidate) was refused"; }
served noarch/omx-clap-contract-0.32.2-1.fc45.noarch.rpm || fail "omx-clap-contract 0.32.2 is not placed"
ok "a noarch below the release's newest is not dnf's candidate and is published"

# ---- 4. the catch-up of aarch64 0.32.4 on the issue's channel: x86_64 0.32.4 + contract 0.32.4 served, aarch64 0.32.3 served
rm -rf "$tree"
core "$work/r4a" 0.32.4 x86_64
SET=quick publish "$work/r4a" > "$work/log" 2>&1 || { cat "$work/log"; fail "x86_64 alone, into a release with no other omx-clap-libs, was refused"; }
core "$work/r4b" 0.32.3 aarch64
SET=full publish "$work/r4b" > "$work/log" 2>&1 || { cat "$work/log"; fail "a noarch below the release's newest was refused on the issue's channel"; }
core "$work/r4c" 0.32.4 aarch64
CU=true publish "$work/r4c" > "$work/log" 2>&1 || { cat "$work/log"; fail "the catch-up of aarch64 was refused"; }
grep -q '^dropped omx-clap-contract-0.32.4-1.fc45.noarch.rpm ' "$work/log" || { cat "$work/log"; fail "the catch-up did not drop the served contract"; }
served aarch64/omx-clap-libs-0.32.4-1.fc45.aarch64.rpm || fail "the catch-up's aarch64 package is not placed"
# the quick release found no aarch64 omx-clap-libs to leave behind, so its contract went into fedora/45/noarch and the
# aarch64 view has served it since (.github#267): the catch-up needs no copy of it
served noarch/omx-clap-contract-0.32.4-1.fc45.noarch.rpm ||
    { cat "$work/log"; fail "the quick release with no aarch64 omx-clap-libs to leave behind did not serve its contract from fedora/45/noarch"; }
[ ! -e "$tree/fedora/45/aarch64/omx-clap-contract-0.32.4-1.fc45.noarch.rpm" ] || fail "the catch-up copied a contract fedora/45/noarch already serves aarch64"
ok "the catch-up of the missing architecture publishes on the issue's channel"

# ---- 5. a noarch nothing of its source pins exactly: a run of one architecture publishes it
rm -rf "$tree"; cp -a "$work/tree0" "$tree"
build "$work/r5" 0.32.4 x86_64 langpack-ca '>='
publish "$work/r5" > "$work/log" 2>&1 || { cat "$work/log"; fail "a noarch nothing pins exactly was refused"; }
served noarch/omx-clap-langpack-ca-0.32.4-1.fc45.noarch.rpm || fail "omx-clap-langpack-ca 0.32.4 is not placed"
ok "a noarch no package of its source pins exactly is published by a run of one architecture"
echo "noarch-pin: all passed"
