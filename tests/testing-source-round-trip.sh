#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The testing source's round trip, on a throwaway Debian trixie container (it writes /etc/apt): openmixer-release
# built from this checkout and installed; a staged package published into a signed staging tree by the publish's own
# tree script (label OpenMixer-Staging, skeleton arm64), served over HTTP. Proves, by apt's candidate:
#   - with the testing source as installed (Enabled: no) the staged package is invisible;
#   - Enabled: yes, the staged index loads and the package installs from it, at priority 500 (no pin);
#   - Enabled: no again, apt offers nothing from the staging tree.
# The one stub: the testing source's host and key are this proof's channel's, in place of www.openmixer.org's.
#
#   testing-source-round-trip.sh       as root, in debian:trixie with apt-utils gnupg dpkg-dev build-essential debhelper lintian
#                                      python3 curl ca-certificates; reads the channel's deb/openmixer.asc to build
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo "testing-source-round-trip.sh writes /etc/apt of a throwaway container: run it as root there" >&2; exit 2; }
w=$(mktemp -d); chmod 755 "$w"
fail() { echo "FAIL: $*" >&2; exit 1; }
curl -fsSL --retry 5 -o "$w/channel.asc" https://www.openmixer.org/deb/openmixer.asc
"$here/packaging/openmixer-release/build.sh" deb "$w/channel.asc" "$w/out" > "$w/build.log" 2>&1 || { cat "$w/build.log"; fail "openmixer-release did not build"; }
deb=$(ls "$w"/out/openmixer-release_*_all.deb)
export GNUPGHOME=$w/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Staging Test <staging@example.org>' ed25519 sign 1y
ID=$(gpg --with-colons --fingerprint staging@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$w/pinned.txt SERVED_KEYS_DIR=$w/none; mkdir "$SERVED_KEYS_DIR"
printf '%s packages throwaway\n' "$ID" > "$PINNED_FINGERPRINTS"
d=$w/pkg; mkdir -p "$d/DEBIAN" "$d/usr/share/doc/omx-probe" "$w/staged/trixie"
printf '%s\n' 'Package: omx-probe' 'Version: 1.0+git1794480000.99c23a5' 'Architecture: all' 'Maintainer: t <t@example.org>' 'Description: staged probe' > "$d/DEBIAN/control"
dpkg-deb --root-owner-group -b "$d" "$w/staged/trixie/omx-probe_1.0+git1794480000.99c23a5_all.deb" >/dev/null
ch=$w/channel; mkdir -p "$ch/staging/deb"
LABEL=OpenMixer-Staging SKELETON=trixie SKELETON_ARCHES=arm64 \
    "$here"/.github/actions/publish-debs/publish-tree.sh "$ch/staging/deb" "$w/staged" "$ID" > "$w/publish.log" 2>&1 || { cat "$w/publish.log"; exit 1; }
echo "== the staging tree"; (cd "$ch/staging/deb/debian/trixie" && find . -type f | sort && grep -E '^(Label|Architectures):' Release && gpg --verify InRelease 2>&1 | grep -E 'Good signature')
(cd "$ch" && exec python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1) &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$w"' EXIT
sleep 2
apt-get install -y -qq "$deb" >/dev/null 2>&1
t=/etc/apt/sources.list.d/openmixer-testing.sources
gpg --armor --export "$ID" > /usr/share/keyrings/staging-test.asc
# the one stub: the host and key of this proof's channel in place of www.openmixer.org's
sed -i -e 's|https://www.openmixer.org/staging/deb/|http://127.0.0.1:8080/staging/deb/|' -e 's|openmixer-archive-keyring.asc|staging-test.asc|' "$t"
cand() { apt-cache policy omx-probe | awk '/Candidate:/ {print $2}'; }
echo "== disabled (as installed)"; grep -qx 'Enabled: no' "$t" || fail "the testing source is not installed disabled: $(grep '^Enabled' "$t")"
apt-get update 2>&1 | grep -E '127.0.0.1|^[WE]:' || true
echo "candidate: '$(cand)'"; [ -z "$(cand)" ] || [ "$(cand)" = "(none)" ] || fail "the staged package is visible with the testing source disabled"
echo "== enabled"; sed -i 's/^Enabled: no$/Enabled: yes/' "$t"
apt-get update 2>&1 | grep -E '127.0.0.1|^[WE]:' || true
echo "candidate: '$(cand)'"; [ "$(cand)" = 1.0+git1794480000.99c23a5 ] || fail "the staged package is not the candidate with the testing source enabled"
apt-get install -y omx-probe >/dev/null 2>&1; dpkg-query -W omx-probe
apt-cache policy omx-probe | sed -n '1,8p'
echo "== disabled again"; sed -i 's/^Enabled: yes$/Enabled: no/' "$t"
apt-get update 2>&1 | grep -E '127.0.0.1|^[WE]:' || true
apt-cache policy omx-probe | sed -n '1,8p'
apt-cache policy omx-probe | grep -q '127.0.0.1' && fail "the staging tree is still offered with the testing source disabled again"
echo "ROUND TRIP PASS"
