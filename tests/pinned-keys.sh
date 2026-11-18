#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The fingerprints the channel's key files are held to (.github/actions/import-gpg-key/pinned-fingerprints.txt).
# The committed list is well formed; every reader of a served key file (channel-keys.sh pinned and check, and
# openmixer-release's build.sh through it) refuses a file holding a key the list does not pin and passes one that
# holds only pinned keys; and a list stripped of the key, empty or missing refuses the same file. Throwaway keys.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
keys=$here/../.github/actions/import-gpg-key/channel-keys.sh
committed=$here/../.github/actions/import-gpg-key/pinned-fingerprints.txt
work=$(mktemp -d)
GNUPGHOME=$work/gnupg
export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
fail() { echo "FAIL: $*" >&2; exit 1; }

# the committed list: 40 hex digits, a known role, no key twice, at least one packages key and the site key
awk '$1 !~ /^#/ && NF' "$committed" > "$work/lines"
[ -s "$work/lines" ] || fail "the committed list holds no key"
while read -r fpr role _; do
    [[ $fpr =~ ^[0-9A-F]{40}$ ]] || fail "not an upper-case 40 hex fingerprint: $fpr"
    case $role in packages | site) ;; *) fail "unknown role $role for $fpr" ;; esac
done < "$work/lines"
[ "$(cut -d' ' -f1 "$work/lines" | sort | uniq -d | wc -l)" = 0 ] || fail "a fingerprint is listed twice"
grep -q ' packages ' "$work/lines" || fail "no packages key is pinned"
grep -q ' site ' "$work/lines" || fail "the site key is not pinned"

mk() { gpg --batch --quiet --passphrase '' --quick-gen-key "$1 <$1@example.org>" ed25519 sign 1y
    gpg --batch --with-colons --fingerprint "$1@example.org" | awk -F: '/^fpr:/ {print $10; exit}'; }
real=$(mk real)
other=$(mk other)
gpg --batch --armor --export real@example.org > "$work/real.asc"
gpg --batch --armor --export other@example.org > "$work/other.asc"
cat "$work/real.asc" "$work/other.asc" > "$work/both.asc"
export PINNED_FINGERPRINTS=$work/list
mkdir "$work/none"
export SERVED_KEYS_DIR=$work/none # throwaway lists see no committed key until the committed-keys section
pin() { : > "$PINNED_FINGERPRINTS"; for f in "$@"; do printf '%s packages test\n' "$f" >> "$PINNED_FINGERPRINTS"; done; }
refuse() { local what=$1; shift; if "$@" >/dev/null 2>&1; then fail "accepted $what"; fi; }

pin "$real"
"$keys" pinned "$work/real.asc" "$real" >/dev/null || fail "refused a key file of the pinned key"
"$keys" check "$work/real.asc" "$real" >/dev/null || fail "check refused a key file of the pinned key"
refuse "a file with a second, unpinned key" "$keys" pinned "$work/both.asc"
refuse "a file of an unpinned key" "$keys" pinned "$work/other.asc"
refuse "an unpinned signing key" "$keys" pinned "$work/real.asc" "$other"
refuse "check on a file with an unpinned key" "$keys" check "$work/both.asc" "$real"
refuse "serve of an unpinned signing key" "$keys" serve "$work/real.asc" "$other"
pin "$real" "$other"
"$keys" pinned "$work/both.asc" "$real" "$other" >/dev/null || fail "refused a file whose keys are all pinned"

# sabotage the list: the file that passed is refused when the list lacks the key, is empty or is not there
pin "$other"
refuse "a list without the key" "$keys" pinned "$work/real.asc"
pin
refuse "an empty list" "$keys" pinned "$work/real.asc"
rm -f "$PINNED_FINGERPRINTS"
refuse "a missing list" "$keys" pinned "$work/real.asc"

# the committed list stands against a key it does not carry
refuse "a throwaway key against the committed list" env -u PINNED_FINGERPRINTS "$keys" pinned "$work/real.asc"

# keys committed to this repository (served-keys/) are served by every publish beside what the channel served,
# so a new signing key is accepted by the honesty check before the channel has ever served it
mkdir "$work/committed"
cp "$work/other.asc" "$work/committed/other.asc"
export SERVED_KEYS_DIR=$work/committed
primaries() { gpg --batch --with-colons --import-options show-only --import 2>/dev/null |
    awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}' | sort | tr '\n' ' '; }
pin "$real" "$other"
"$keys" check "$work/real.asc" "$other" >/dev/null || fail "check refused a committed key the channel has not served yet"
"$keys" check "$work/real.asc" "$real" "$other" >/dev/null || fail "check refused the served key and the committed one"
[ "$("$keys" emit "$work/real.asc" | primaries)" = "$(printf '%s\n' "$real" "$other" | sort | tr '\n' ' ')" ] ||
    fail "emit is not the served file plus the committed keys"
cp "$work/real.asc" "$work/served.asc"
"$keys" serve "$work/served.asc" "$real"
[ "$(primaries < "$work/served.asc")" = "$(printf '%s\n' "$real" "$other" | sort | tr '\n' ' ')" ] ||
    fail "serve did not add the committed key to the served file"
pin "$real"
refuse "a committed key that is not pinned" "$keys" emit "$work/real.asc"
refuse "serve with a committed key that is not pinned" "$keys" serve "$work/served.asc" "$real"
refuse "check of an unpinned committed key" "$keys" check "$work/real.asc" "$other"
export SERVED_KEYS_DIR=$work/none
refuse "check of a key neither served nor committed" "$keys" check "$work/real.asc" "$other"

# the committed directory: every key in it is pinned in the committed list, and the 2026-11-01 key is both
unset PINNED_FINGERPRINTS SERVED_KEYS_DIR
newfpr=6AF1C62FF70BD10D5CA9DDE58A27655323BADDA6
oldfpr=5CB7E2D404C46D6A16F05D871B5B7D400616FA4D
grep -q "^$newfpr packages " "$committed" || fail "the 2026-11-01 key is not pinned"
grep -q "^$oldfpr packages " "$committed" || fail "the first release key is no longer pinned"
"$keys" emit "$work/no-such-file" | primaries | grep -q "$newfpr" || fail "the committed keys do not carry the 2026-11-01 key"
export PINNED_FINGERPRINTS=$work/list SERVED_KEYS_DIR=$work/none
pin "$real"

# openmixer-release ships one committed release key: build.sh stops at an unpinned served key, before it builds anything
gpg --batch --yes --quiet --passphrase '' --quick-gen-key "OpenMixer Release Signing Key <packages@openmixer.org>" ed25519 sign 1y
relfpr=$(gpg --batch --with-colons --fingerprint packages@openmixer.org | awk -F: '/^fpr:/ {print $10; exit}')
mkdir "$work/committed-release"
gpg --batch --armor --export "$relfpr" > "$work/committed-release/release.asc"
export SERVED_KEYS_DIR=$work/committed-release
pin "$real" "$relfpr"
refuse "build.sh on an unpinned key" "$here/../packaging/openmixer-release/build.sh" rpm "$work/both.asc" "$work/out"
out=$("$here/../packaging/openmixer-release/build.sh" rpm "$work/real.asc" "$work/out" 2>&1 || true)
grep -q 'ships' <<< "$out" || fail "build.sh did not get past the pin with a pinned key: $out"
# ... with a committed release key it ships that key ALONE: the served file's extra key is not in the package
out=$("$here/../packaging/openmixer-release/build.sh" rpm "$work/real.asc" "$work/out2" 2>&1 || true)
grep -q "ships $relfpr\$" <<< "$(grep ' ships ' <<< "$out" | sed 's/ *$//')" || fail "build.sh does not ship the committed key alone: $out"
if grep -q "ships .*$real" <<< "$out"; then fail "build.sh shipped the served file's key $real, not the committed key alone: $out"; fi
# the committed list read by whatever awk this machine has (Debian's is mawk, which has no {n} intervals): the
# committed served key is pinned by the committed list, and with the packages lines stripped it is refused by name
for f in "$here"/../.github/actions/import-gpg-key/served-keys/*.asc; do
    out=$(env -u PINNED_FINGERPRINTS -u SERVED_KEYS_DIR "$keys" pinned "$f" 2>&1) || fail "the committed list does not pin $f under $(readlink -f "$(command -v awk)"): $out"
    grep -v ' packages ' "$committed" > "$work/nopackages"
    out=$(env -u SERVED_KEYS_DIR PINNED_FINGERPRINTS="$work/nopackages" "$keys" pinned "$f" 2>&1) && fail "a list without packages lines pinned $f"
    grep -q 'no packages fingerprint' <<< "$out" || fail "a list without packages lines was not refused by name: $out"
done
echo "pinned-keys: the list is well formed; unpinned keys and a sabotaged list refused; pinned keys pass"
