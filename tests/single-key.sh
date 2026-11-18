#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# `channel-keys.sh single <key file>`: a published key file holds EXACTLY ONE key, and its uid is the release
# identity packages@openmixer.org. A file with two keys, or with a key whose uid is anyone else's (a personal
# key must never sit in a release keyring), fails by name. Throwaway keys; the live channel is not read here.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
keys=$here/../.github/actions/import-gpg-key/channel-keys.sh
work=$(mktemp -d)
GNUPGHOME=$work/gnupg
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
fail() { echo "FAIL: $*" >&2; exit 1; }
mk() { gpg --batch --yes --quiet --passphrase '' --quick-gen-key "$1" ed25519 sign 1y
    gpg --batch --with-colons --fingerprint "$1" | awk -F: '/^fpr:/ {print $10; exit}'; }
rel1=$(mk 'OpenMixer Release Signing Key <packages@openmixer.org>')
mk 'OpenMixer Release Signing Key <packages@openmixer.org>' > /dev/null
personal=$(mk 'Someone <someone@example.org>')
gpg --batch --armor --export "$rel1" > "$work/one.asc"
gpg --batch --armor --export packages@openmixer.org > "$work/two-release.asc"
gpg --batch --armor --export "$personal" > "$work/personal.asc"
cat "$work/one.asc" "$work/personal.asc" > "$work/one-plus-personal.asc"
export PINNED_FINGERPRINTS=$work/list
: > "$PINNED_FINGERPRINTS"
for f in "$rel1" "$personal"; do printf '%s packages test\n' "$f" >> "$PINNED_FINGERPRINTS"; done
gpg --batch --with-colons --fingerprint packages@openmixer.org | awk -F: '/^fpr:/ {print $10}' |
    while read -r f; do grep -q "$f" "$PINNED_FINGERPRINTS" || printf '%s packages test\n' "$f" >> "$PINNED_FINGERPRINTS"; done
mkdir "$work/none"
export SERVED_KEYS_DIR=$work/none

"$keys" single "$work/one.asc" > "$work/ok.out" 2>&1 || fail "refused a file holding the one release key: $(cat "$work/ok.out")"
refuse() { # <what> <expected words> <file>
    local out
    if out=$("$keys" single "$3" 2>&1); then fail "accepted $1"; fi
    grep -q "$2" <<< "$out" || fail "refused $1 without naming it ($2): $out"
}
refuse "two release keys" "holds 2 keys" "$work/two-release.asc"
refuse "a release key plus a personal key" "holds 2 keys" "$work/one-plus-personal.asc"
refuse "a personal key alone" "$personal" "$work/personal.asc"
if "$keys" single "$work/missing.asc" > /dev/null 2>&1; then fail "accepted a missing file"; fi
# ship: only the committed key, whatever the served file holds
mkdir "$work/committed"
cp "$work/one.asc" "$work/committed/current.asc"
export SERVED_KEYS_DIR=$work/committed
shipped=$("$keys" ship "$work/one-plus-personal.asc") || fail "ship refused a served file holding an extra key"
listing=$(gpg --batch --with-colons --import-options show-only --import <<< "$shipped" 2>/dev/null)
[ "$(grep -c '^pub:' <<< "$listing")" = 1 ] || fail "ship wrote more than the one committed key"
if grep -q "$personal" <<< "$listing"; then fail "ship wrote the personal key"; fi
cp "$work/two-release.asc" "$work/committed/extra.asc"
if "$keys" ship "$work/one.asc" > /dev/null 2>&1; then fail "ship accepted two committed keys"; fi
echo "single-key: ok"
