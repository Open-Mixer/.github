#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# An Architecture: all package that a package of its own source pins exactly is never published ahead of an
# architecture the run did not build (Open-Mixer/.github#59). A Debian suite is one flat index for every architecture:
# the all package is served to all of them, and apt takes the newest version as its candidate and never an older one to
# meet an exact dependency. So the arch package left behind on an architecture the run did not build is uninstallable.
#
# The fixture is the channel of the issue, published by the real tree script with a throwaway key:
#   trixie amd64 plugin-hostd 0.20.4-1, Depends plugin-hostd-contract (= 0.20.4-1); trixie all plugin-hostd-contract
#   0.20.4-1. A quick-set release then brings arm64 plugin-hostd 0.20.6-1 and plugin-hostd-contract 0.20.6-1 (all).
# Proves:
#   - that release is refused before anything is placed or signed, naming the all package, the suite, the pinning
#     package and the architecture it was not built for (amd64); the tree is byte-identical after;
#   - the same release built for every architecture of the suite that serves the pinning package (amd64 and arm64)
#     publishes, and the new all package is indexed;
#   - an all package placed BELOW the newest one of the suite is not apt's candidate and is not refused, so the
#     issue's real channel (amd64 0.20.4, arm64 0.20.6, contract 0.20.4 and 0.20.6) can be built here;
#   - on that channel, the catch-up of the missing architecture (amd64 0.20.6, its rebuilt contract dropped as served)
#     publishes: the refusal never stands in the way of the repair;
#   - an all package nothing of its source pins exactly (a language pack) is published by a run of one architecture.
# Sabotage: ARCH_ALL_ACTIONS names a copy of the actions with the refusal taken out; the first arm then goes red.
#
#   arch-all-pin.sh       in a Debian container with apt-utils gnupg gpgv dpkg-dev
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${ARCH_ALL_ACTIONS:-$here/.github/actions}
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
mkdeb() { # <out dir> <package> <version> <arch> [<Depends>]
    local d=$work/b/$2-$3-$4
    mkdir -p "$d/DEBIAN" "$1/trixie"
    {
        printf '%s\n' "Package: $2" "Source: plugin-hostd" "Version: $3" "Architecture: $4" 'Maintainer: t <t@example.org>'
        [ -z "${5:-}" ] || printf 'Depends: %s\n' "$5"
        printf 'Description: %s\n' "$2 $3 $4"
    } > "$d/DEBIAN/control"
    dpkg-deb -b "$d" "$1/trixie/${2}_${3}_$4.deb" >/dev/null
}
hostd() { mkdeb "$1" plugin-hostd "$2" "$3" "libc6 (>= 2.36), plugin-hostd-contract (= $2)"; }
contract() { mkdeb "$1" plugin-hostd-contract "$2" all; }
publish() { CATCH_UP=${CU:-} MATRIX_SET=${SET:-quick} "$actions/publish-debs/publish-tree.sh" "$tree" "$1" "$key"; }
indexed() { grep -qx "Filename: ./$1" "$tree/debian/trixie/Packages"; }

# ---- the channel of the issue, before the quick release
hostd "$work/r0" 0.20.4-1 amd64
contract "$work/r0" 0.20.4-1
SET=full publish "$work/r0" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture channel could not be published"; }
cp -a "$tree" "$work/tree0"

# ---- 1. a quick release of arm64 alone: refused, nothing placed or signed
hostd "$work/r1" 0.20.6-1 arm64
contract "$work/r1" 0.20.6-1
snapshot "$work/before"
if publish "$work/r1" > "$work/log" 2>&1; then cat "$work/log"; fail "a release built for arm64 alone published plugin-hostd-contract 0.20.6-1 (all) over amd64's plugin-hostd 0.20.4-1"; fi
grep -q '^refused plugin-hostd-contract_0.20.6-1_all.deb in debian/trixie: ' "$work/log" ||
    { cat "$work/log"; fail "the refusal does not name the all package and the suite"; }
grep -q 'plugin-hostd pins it exactly (= 0.20.6-1)' "$work/log" || { cat "$work/log"; fail "the refusal does not name the pinning package"; }
grep -q 'not built for amd64' "$work/log" || { cat "$work/log"; fail "the refusal does not name the architecture left behind (amd64)"; }
grep -q 'nothing was placed or signed' "$work/log" || { cat "$work/log"; fail "the refusal does not say nothing was placed or signed"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused release changed the tree"
ok "a quick release of arm64 alone is refused: plugin-hostd-contract 0.20.6-1 (all) would leave amd64's plugin-hostd uninstallable"

# ---- 2. the same release built for amd64 and arm64: published
hostd "$work/r1" 0.20.6-1 amd64
publish "$work/r1" > "$work/log" 2>&1 || { cat "$work/log"; fail "a release built for every architecture of the suite was refused"; }
indexed all/plugin-hostd-contract_0.20.6-1_all.deb || fail "plugin-hostd-contract 0.20.6-1 is not indexed"
indexed amd64/plugin-hostd_0.20.6-1_amd64.deb && indexed arm64/plugin-hostd_0.20.6-1_arm64.deb || fail "plugin-hostd 0.20.6-1 is not indexed on both architectures"
ok "the same release built for amd64 and arm64 publishes, and the index carries it"

# ---- 3. the issue's real channel: arm64 0.20.6 published first, then amd64 0.20.4 with its older contract
rm -rf "$tree"
hostd "$work/r3a" 0.20.6-1 arm64
contract "$work/r3a" 0.20.6-1
SET=quick publish "$work/r3a" > "$work/log" 2>&1 || { cat "$work/log"; fail "arm64 alone, into a suite with no other plugin-hostd, was refused"; }
hostd "$work/r3b" 0.20.4-1 amd64
contract "$work/r3b" 0.20.4-1
SET=full publish "$work/r3b" > "$work/log" 2>&1 || { cat "$work/log"; fail "an all package below the suite's newest (not apt's candidate) was refused"; }
ok "an all package below the suite's newest is not apt's candidate and is published"

# ---- 4. the catch-up of amd64 0.20.6 on that channel: the rebuilt contract is dropped, amd64 is placed
hostd "$work/r4" 0.20.6-1 amd64
contract "$work/r4" 0.20.6-1
CU=true publish "$work/r4" > "$work/log" 2>&1 || { cat "$work/log"; fail "the catch-up of amd64 was refused"; }
grep -q '^dropped plugin-hostd-contract_0.20.6-1_all.deb ' "$work/log" || { cat "$work/log"; fail "the catch-up did not drop the served contract"; }
indexed amd64/plugin-hostd_0.20.6-1_amd64.deb || fail "the catch-up's amd64 package is not indexed"
ok "the catch-up of the missing architecture publishes on the issue's channel"

# ---- 5. an all package nothing of its source pins exactly: a run of one architecture publishes it
rm -rf "$tree"; cp -a "$work/tree0" "$tree"
mkdeb "$work/r5" plugin-hostd 0.20.6-1 arm64 "plugin-hostd-l10n (>= 0.20.6-1)"
mkdeb "$work/r5" plugin-hostd-l10n 0.20.6-1 all
publish "$work/r5" > "$work/log" 2>&1 || { cat "$work/log"; fail "an all package nothing pins exactly was refused"; }
indexed all/plugin-hostd-l10n_0.20.6-1_all.deb || fail "plugin-hostd-l10n 0.20.6-1 is not indexed"
ok "an all package no package of its source pins exactly is published by a run of one architecture"
echo "arch-all-pin: all passed"
