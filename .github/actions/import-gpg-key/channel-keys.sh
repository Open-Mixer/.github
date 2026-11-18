#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The public key files a channel serves (rpm/RPM-GPG-KEY-openmixer, deb/openmixer.asc).
#
#   channel-keys.sh check <key file> <fingerprint>...   every fingerprint is a primary the file serves
#   channel-keys.sh serve <key file> <key id>...        the file becomes what it served plus these keys
#   channel-keys.sh pinned <key file> [<key id>...]     every primary the file serves, and every key named, is pinned
#   channel-keys.sh emit <key file>                     the armored keys of the file plus the committed keys, on stdout
#   channel-keys.sh ship <ignored>                      the ONE key openmixer-release ships (the committed signing key), on stdout
#   channel-keys.sh single <key file>                   the file holds exactly ONE key, whose uids are all packages@openmixer.org
#
# THE TRUST ROOT IS NOT THE CHANNEL. pinned-fingerprints.txt (committed beside this script, in the repository the
# action is checked out from) lists the primaries OpenMixer signs with. A served key file holding any other
# primary is refused by every reader (check, pinned), and check and serve refuse a signing key that is not
# pinned: a channel writer who swaps or adds a key to the file cannot make a publish or a release vouch for
# what that key signed. PINNED_FINGERPRINTS names another list (the tests' throwaway keys).
#
# A served key file is a UNION and only grows: a client that imported an earlier key keeps verifying what
# that key signed, and a new signing key is served next to the old one, never in its place. dnf imports
# from the gpgkey URL the key a package or repomd.xml names; apt reads the signed-by copy the user saved,
# so for apt the index is co-signed while the old key is still in users' keyrings (publish-debs). A key
# leaves the file only by a hand commit to the channel, when its retirement is decided.
#
# SIGNING KEYS COMMITTED HERE. served-keys/*.asc (beside this script; SERVED_KEYS_DIR names another directory)
# holds the public half of every key OpenMixer signs with that is not only in the channel: each is served by
# every publish next to what the channel served (serve), is trusted by the publishers' keystore and keyring and
# shipped by openmixer-release (emit), and is accepted by check before the channel has ever served it, so the
# first release signed by a new key is not refused for a key file that does not hold it yet. Each must be
# pinned; the old key's public half is not here, it stays in the file the channel serves.
#
# check with no file (the first publish into an empty channel) warns and passes: there is nothing yet a
# client could have imported.
set -euo pipefail

primaries() { gpg --batch --with-colons --import-options show-only --import 2>/dev/null |
    awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}'; }

pinned_list=${PINNED_FINGERPRINTS:-$(dirname "$(readlink -f "$0")")/pinned-fingerprints.txt}
committed_dir=${SERVED_KEYS_DIR:-$(dirname "$(readlink -f "$0")")/served-keys}

# the committed public key files, each refused unless every primary in it is pinned
committed_files() {
    local f fpr
    for f in "$committed_dir"/*.asc; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC2046 # the fingerprints are words
        require_pinned "the committed key file $f" $(primaries < "$f") || exit 1
        echo "$f"
    done
}

# the fingerprints of the packages lines of the list, upper case
pinned_fprs() {
    [ -s "$pinned_list" ] || { echo "::error::the pinned fingerprint list $pinned_list is missing or empty" >&2; return 1; }
    # no {40} interval: mawk, the awk of Debian, reads it as the text "{40}" and finds no fingerprint
    awk '$1 !~ /^#/ && $2 == "packages" && length($1) == 40 && $1 ~ /^[0-9A-Fa-f]+$/ {print toupper($1)}' "$pinned_list"
}

# <what> <fingerprint>...: refuse any that is not pinned
require_pinned() {
    local what=$1 pins fpr
    shift
    pins=$(pinned_fprs) || exit 1
    [ -n "$pins" ] || { echo "::error::no packages fingerprint in $pinned_list" >&2; exit 1; }
    for fpr in "$@"; do
        grep -qx "${fpr^^}" <<< "$pins" || {
            echo "::error::$what: $fpr is not a pinned signing key fingerprint ($pinned_list) -- refusing it" >&2
            exit 1
        }
    done
}

# a key id or fingerprint to the primary fingerprint of the key in the local keyring
primary_of() { gpg --batch --with-colons --fingerprint "$1" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}'; }

cmd=${1:?usage: channel-keys.sh check|serve|pinned <key file> <key>...}
file=${2:?usage: channel-keys.sh check|serve|pinned <key file> <key>...}
shift 2
[ "$#" -gt 0 ] || [ "$cmd" = pinned ] || [ "$cmd" = emit ] || [ "$cmd" = single ] || [ "$cmd" = ship ] || { echo "channel-keys.sh $cmd: no key named" >&2; exit 2; }

# a committed key that is not pinned stops the command here, in this shell, not in a substitution below
case "$cmd" in emit | check | serve) committed_files > /dev/null ;; esac

case "$cmd" in
ship)
    # What a machine imports from openmixer-release: the signing key committed in served-keys/, alone. The served
    # file may still hold older keys while the channel is being trimmed; they are not shipped. The result must
    # pass `single`. The argument is the served file by the same calling shape as emit; ship never reads it
    # (the second word is required only because every subcommand takes a file word).
    out=$(mktemp)
    trap 'rm -f "$out"' EXIT
    while IFS= read -r f; do cat "$f"; done < <(committed_files) > "$out"
    "$0" single "$out" > /dev/null || exit 1
    cat "$out"
    ;;
single)
    # The end state of every published key file: one release key, the release identity, nothing personal.
    # Not yet wired into a publish: the live files hold three keys until the re-sign and trim steps are done.
    [ -s "$file" ] || { echo "::error::$file is empty or missing: there is no key file to judge" >&2; exit 1; }
    listing=$(gpg --batch --with-colons --import-options show-only --import < "$file" 2>/dev/null) || true
    n=$(awk -F: '/^pub:/ {n++} END {print n + 0}' <<< "$listing")
    served=$(primaries < "$file")
    [ "$n" = 1 ] || {
        echo "::error::$file holds $n keys, not one: $(tr '\n' ' ' <<< "$served")" >&2
        exit 1
    }
    bad=$(awk -F: '/^uid:/ && $10 !~ /<packages@openmixer\.org>$/ {print $10}' <<< "$listing")
    [ -z "$bad" ] || {
        echo "::error::$file: the key $served has a uid that is not packages@openmixer.org: $bad" >&2
        exit 1
    }
    require_pinned "the key file $file" $served
    echo "$file holds the one release key $served"
    ;;
emit)
    if [ -s "$file" ]; then
        served=$(primaries < "$file")
        # shellcheck disable=SC2046 # the fingerprints are words
        require_pinned "the key file $file" $served
        cat "$file"
    fi
    while IFS= read -r f; do cat "$f"; done < <(committed_files)
    ;;
pinned)
    # no file yet (the first publish into an empty channel): only the named keys are checked
    served=
    if [ -s "$file" ]; then
        served=$(primaries < "$file")
        [ -n "$served" ] || { echo "::error::no fingerprint readable from $file" >&2; exit 1; }
        # shellcheck disable=SC2046 # the fingerprints are words
        require_pinned "the key file $file" $served
    elif [ "$#" -eq 0 ]; then
        echo "::error::$file is empty or missing: there is no key file to trust" >&2
        exit 1
    fi
    for k in "$@"; do
        fpr=$(primary_of "$k")
        [ -n "$fpr" ] || { echo "::error::no key $k to check against the pinned list" >&2; exit 1; }
        require_pinned "the signing key $k" "$fpr"
    done
    if [ -n "$served" ]; then echo "$file serves only pinned keys: $(tr '\n' ' ' <<< "$served")"
    else echo "no key file at $file yet; the named keys are pinned"; fi
    ;;
check)
    for k in "$@"; do require_pinned "the signing key $k" "$(primary_of "$k" || true)" || exit 1; done
    if [ ! -s "$file" ]; then
        echo "::warning::the channel serves no public key at $file yet: this publish sets it to $*"
        exit 0
    fi
    served=$(primaries < "$file")
    [ -n "$served" ] || { echo "::error::no fingerprint readable from $file"; exit 1; }
    # shellcheck disable=SC2046 # the fingerprints are words
    require_pinned "the key file $file" $served
    committed=$(while IFS= read -r f; do primaries < "$f"; done < <(committed_files))
    for fpr in "$@"; do
        grep -qx "$fpr" <<< "$served"$'\n'"$committed" || {
            echo "::error::the signing key $fpr is not one the channel serves at $file ($(tr '\n' ' ' <<< "$served")) -- refusing to sign with a key clients cannot verify"
            exit 1
        }
    done
    echo "$file serves $(tr '\n' ' ' <<< "$served")"
    ;;
serve)
    for k in "$@"; do require_pinned "the signing key $k" "$(primary_of "$k")" || exit 1; done
    home=$(mktemp -d)
    trap 'rm -rf "$home"' EXIT
    { if [ -s "$file" ]; then cat "$file"; fi; gpg --armor --export "$@"; while IFS= read -r f; do cat "$f"; done < <(committed_files); } |
        GNUPGHOME=$home gpg --batch --quiet --import 2>/dev/null
    GNUPGHOME=$home gpg --batch --armor --export > "$file.new"
    for k in "$@"; do
        fpr=$(gpg --batch --with-colons --fingerprint "$k" | awk -F: '/^fpr:/ {print $10; exit}')
        grep -qx "$fpr" < <(primaries < "$file.new") || { echo "exporting $k left it out of $file" >&2; rm -f "$file.new"; exit 1; }
    done
    mv "$file.new" "$file"
    ;;
*)
    echo "channel-keys.sh: unknown command $cmd" >&2
    exit 2
    ;;
esac
