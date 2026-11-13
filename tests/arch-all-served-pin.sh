#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# An Architecture: all package is also never published over an arch package the suite ALREADY SERVES that pins the all
# package's current version exactly (Open-Mixer/.github#61, beside #59/#60 which judge the pinners of the run). A run that
# publishes the all package alone, or without the pinner's architecture, would make it apt's candidate there and leave the
# served pinner uninstallable. The pinners are read from the pulled tree's .deb files (an ordinary channel pull drops the
# metadata).
#
# The fixture is published by the real tree script with a throwaway key:
#   trixie amd64 and arm64 plugin-hostd 0.20.4-1, Depends plugin-hostd-contract (= 0.20.4-1); trixie all contract 0.20.4-1.
# Proves:
#   - a run holding only plugin-hostd-contract 0.20.6-1 (all) is refused before anything is placed or signed, naming the
#     all package, the suite, the served pinner and the architectures (amd64 arm64); the tree is byte-identical after;
#   - a run building the pinner for amd64 alone is refused for arm64 (the served pinner, with the run's own), and one
#     building both architectures publishes;
#   - a served pinner that pins another package (a >= pin) does not stop the all package;
#   - the catch-up of arm64 0.20.6 on a channel serving amd64 0.20.6 and arm64 0.20.4 drops the served all package and
#     places arm64: the refusal never stands in the way of the repair.
# Sabotage: ARCH_ALL_ACTIONS names a copy of the actions with the served-pinner block taken out; the first arm goes red.
#
#   arch-all-served-pin.sh       in a Debian container with apt-utils gnupg gpgv dpkg-dev
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

# ---- the channel: both architectures at 0.20.4, the contract 0.20.4
hostd "$work/r0" 0.20.4-1 amd64
hostd "$work/r0" 0.20.4-1 arm64
contract "$work/r0" 0.20.4-1
SET=full publish "$work/r0" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture channel could not be published"; }
cp -a "$tree" "$work/tree0"

# ---- 1. the all package alone: refused, the served pinners named, nothing placed or signed
contract "$work/r1" 0.20.6-1
snapshot "$work/before"
if publish "$work/r1" > "$work/log" 2>&1; then cat "$work/log"; fail "plugin-hostd-contract 0.20.6-1 (all) alone was published over the served plugin-hostd 0.20.4-1"; fi
grep -q '^refused plugin-hostd-contract_0.20.6-1_all.deb in debian/trixie: ' "$work/log" ||
    { cat "$work/log"; fail "the refusal does not name the all package and the suite"; }
grep -q 'serves plugin-hostd pinning plugin-hostd-contract exactly (= 0.20.4-1)' "$work/log" || { cat "$work/log"; fail "the refusal does not name the served pinner and its pin"; }
grep -q 'for amd64 arm64 and this run builds no plugin-hostd' "$work/log" || { cat "$work/log"; fail "the refusal does not name the architectures left behind"; }
grep -q 'nothing was placed or signed' "$work/log" || { cat "$work/log"; fail "the refusal does not say nothing was placed or signed"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused run changed the tree"
ok "the all package alone is refused: the served plugin-hostd 0.20.4 of amd64 and arm64 would no longer install"

# ---- 2. the pinner built for amd64 alone: arm64's served pinner is left behind (refused); both built: published
hostd "$work/r2" 0.20.6-1 amd64
contract "$work/r2" 0.20.6-1
snapshot "$work/before"
if publish "$work/r2" > "$work/log" 2>&1; then cat "$work/log"; fail "a run built for amd64 alone published the contract over arm64's served pinner"; fi
grep -q 'not built for arm64' "$work/log" || { cat "$work/log"; fail "the refusal does not name arm64"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused run changed the tree"
hostd "$work/r2" 0.20.6-1 arm64
publish "$work/r2" > "$work/log" 2>&1 || { cat "$work/log"; fail "a run built for every architecture was refused"; }
indexed all/plugin-hostd-contract_0.20.6-1_all.deb || fail "plugin-hostd-contract 0.20.6-1 is not indexed"
ok "a run building the pinner for amd64 alone is refused for arm64; built for both it publishes"

# ---- 3. a served package that pins another package, or loosely, does not stop an all package
rm -rf "$tree"; cp -a "$work/tree0" "$tree"
mkdeb "$work/r3a" plugin-hostd 0.20.5-1 amd64 "plugin-hostd-l10n (>= 0.20.5-1)"
mkdeb "$work/r3a" plugin-hostd-l10n 0.20.5-1 all
SET=full publish "$work/r3a" > "$work/log" 2>&1 || { cat "$work/log"; fail "an all package nothing pins exactly was refused"; }
mkdeb "$work/r3b" plugin-hostd-l10n 0.20.6-1 all
publish "$work/r3b" > "$work/log" 2>&1 || { cat "$work/log"; fail "an all package loosely pinned by the served package was refused"; }
indexed all/plugin-hostd-l10n_0.20.6-1_all.deb || fail "plugin-hostd-l10n 0.20.6-1 is not indexed"
ok "an all package the served packages pin loosely is published alone"

# ---- 4. the catch-up of arm64 0.20.6: the served contract is dropped, arm64 placed
rm -rf "$tree"
hostd "$work/r4a" 0.20.6-1 amd64
contract "$work/r4a" 0.20.6-1
SET=quick publish "$work/r4a" > "$work/log" 2>&1 || { cat "$work/log"; fail "amd64 alone, into a suite with no other plugin-hostd, was refused"; }
hostd "$work/r4b" 0.20.4-1 arm64
contract "$work/r4b" 0.20.4-1
SET=full publish "$work/r4b" > "$work/log" 2>&1 || { cat "$work/log"; fail "an all package below the suite's newest was refused"; }
hostd "$work/r4c" 0.20.6-1 arm64
contract "$work/r4c" 0.20.6-1
CU=true publish "$work/r4c" > "$work/log" 2>&1 || { cat "$work/log"; fail "the catch-up of arm64 was refused"; }
grep -q '^dropped plugin-hostd-contract_0.20.6-1_all.deb ' "$work/log" || { cat "$work/log"; fail "the catch-up did not drop the served contract"; }
indexed arm64/plugin-hostd_0.20.6-1_arm64.deb || fail "the catch-up's arm64 package is not indexed"
ok "the catch-up of the missing architecture publishes: the served-pinner refusal does not stand in its way"
echo "arch-all-served-pin: all passed"
