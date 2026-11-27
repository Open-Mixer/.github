#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A DONE wave's devel channel promoted into staging (actions/promote-wave, docs/release-operations.md "The three channel
# levels"), on a fixture channel published by the real tree scripts with a throwaway key: a real tree, staging with
# omx-lib 3.14.0, wave-a's devel channel with omx-lib 3.15.0 and omx-new 2.0 (and omx-lib's build record), wave-b's with
# a rebuilt omx-lib 3.14.0 of other bytes. Proves:
#   - every package and build record of devel/wave-a/<kind> is in staging/<kind> at the same path, byte for byte;
#     staging's own packages stay; staging's index lists the promoted packages and is signed; staging's cells.tsv carries
#     the wave's rows with the wave's set and keeps its own rows; a client of staging installs the promoted build;
#   - nothing outside staging/<kind> changes: the wave's tree, the other wave's, the real tree and the site are
#     byte-identical;
#   - promoting again copies nothing and keeps every byte of the packages (idempotent);
#   - a wave holding a path staging holds with other bytes is refused, naming the path, and staging is byte-identical
#     after; a package planted in a devel tree that its signature (rpm) or signed index (deb) does not vouch for is refused
#     the same way; a wave name outside [a-z0-9-] is refused before anything is read.
# Sabotage: promote-wave.sh with its other-bytes refusal taken out lets wave-b through, and this test goes red.
# Runs as root in a throwaway Fedora (rpm) or Debian (deb) container: the client arm writes /etc.
#
#   promote-wave.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
actions=${PROMOTE_WAVE_ACTIONS:-$root/.github/actions}
kind=${1:?usage: promote-wave.sh rpm|deb}
[ "$(id -u)" = 0 ] || { echo "promote-wave.sh writes /etc of a throwaway container: run it as root there" >&2; exit 2; }
work=$(mktemp -d)
chmod 755 "$work"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Promote Test <promote@example.org>' ed25519 sign 1y
key=$(gpg --with-colons --fingerprint promote@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$key" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed
ch=$work/channel
mkdir -p "$ch/docs"; echo '<html>site</html>' > "$ch/index.html"; echo manual > "$ch/docs/index.html"
sums() { # <path>...: the sums of every file under them, relative to the channel
    (cd "$ch" && find "$@" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}
outside_sum() { (cd "$ch" && find . \( -path "./staging/$kind" -o -path ./.git \) -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }
commit=0123456789abcdef0123456789abcdef01234567

case $kind in
rpm)
    mkpkg() { # <name> <version> <out dir> [description]
        local d=$work/rb-$1-$2-${4:-t}
        mkdir -p "$d" "$3"
        printf '%s\n' "Name: $1" "Version: $2" 'Release: 1.fc45' 'Summary: t' 'License: MIT' 'BuildArch: noarch' '%description' "${4:-t}" '%files' > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2"
        find "$d/RPMS" -name '*.rpm' -exec cp {} "$3/" \;
    }
    pt=$actions/publish-rpms/publish-tree.sh
    publish() { # <tree> <dir> <level> [env...]
        local t=$1 d=$2 l=$3; shift 3
        env REPO_FILE="$("$actions/publish-rpms/channel-level.sh" repo-file "$l" "$work/repo-${l//\//-}")" "$@" "$pt" "$ch/$t" "$d" "$key" >/dev/null
    }
    mkpkg omx-lib 3.13.0 "$work/real"; "$pt" "$ch/rpm" "$work/real" "$key" >/dev/null
    mkpkg omx-lib 3.14.0 "$work/staged"; publish staging/rpm "$work/staged" staging MATRIX_SET=quick
    mkpkg omx-lib 3.15.0 "$work/wave-a"; mkpkg omx-new 2.0 "$work/wave-a"
    publish devel/wave-a/rpm "$work/wave-a" devel/wave-a MATRIX_SET=full BUILT_COMMIT=$commit BUILT_NAME=omx-lib
    sleep 1 # another build time: wave-b's 3.14.0 has other bytes than staging's
    mkpkg omx-lib 3.14.0 "$work/wave-b" rebuilt; publish devel/wave-b/rpm "$work/wave-b" devel/wave-b MATRIX_SET=quick
    promoted=(fedora/45/noarch/omx-lib-3.15.0-1.fc45.noarch.rpm fedora/45/noarch/omx-new-2.0-1.fc45.noarch.rpm)
    clash=fedora/45/noarch/omx-lib-3.14.0-1.fc45.noarch.rpm
    indexed() { # <file name>: in staging's primary metadata, whatever createrepo_c compressed it with
        local f x=
        for f in "$ch"/staging/rpm/fedora/45/noarch/repodata/*primary.xml*; do
            case $f in *.zst) x+=$(zstd -dcq "$f") ;; *.xz) x+=$(xz -dc "$f") ;; *.gz) x+=$(gzip -dc "$f") ;; *) x+=$(cat "$f") ;; esac
        done
        grep -qF "$1" <<< "$x"
    }
    signed_index() { [ -s "$ch/staging/rpm/fedora/45/noarch/repodata/repomd.xml.asc" ]; }
    plant() { # an unsigned package in wave-c's devel tree, beside a signed one
        mkpkg omx-lib 3.17.0 "$work/wave-c"; publish devel/wave-c/rpm "$work/wave-c" devel/wave-c
        mkpkg omx-plant 1.0 "$work/plant"; cp "$work/plant/"*.rpm "$ch/devel/wave-c/rpm/fedora/45/noarch/"
    }
    ;;
deb)
    mkdeb() { # <name> <version> <out dir> [description]
        local d=$work/db-$1-$2-${4:-t}
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1" "$3/trixie"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: all' 'Maintainer: t <t@example.org>' "Description: ${4:-t}" > "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$3/trixie/$1_$2_all.deb" >/dev/null
    }
    pt=$actions/publish-debs/publish-tree.sh
    publish() { local t=$1 d=$2; shift 2; env "$@" "$pt" "$ch/$t" "$d" "$key" >/dev/null; }
    mkdeb omx-lib 3.13.0 "$work/real"; "$pt" "$ch/deb" "$work/real" "$key" >/dev/null
    mkdeb omx-lib 3.14.0 "$work/staged"; publish staging/deb "$work/staged" LABEL=OpenMixer-Staging MATRIX_SET=quick
    mkdeb omx-lib 3.15.0 "$work/wave-a"; mkdeb omx-new 2.0 "$work/wave-a"
    publish devel/wave-a/deb "$work/wave-a" LABEL=OpenMixer-Devel MATRIX_SET=full BUILT_COMMIT=$commit BUILT_NAME=omx-lib
    mkdeb omx-lib 3.14.0 "$work/wave-b" rebuilt; publish devel/wave-b/deb "$work/wave-b" LABEL=OpenMixer-Devel MATRIX_SET=quick
    promoted=(debian/trixie/all/omx-lib_3.15.0_all.deb debian/trixie/all/omx-new_2.0_all.deb)
    clash=debian/trixie/all/omx-lib_3.14.0_all.deb
    indexed() { grep -qx "Filename: ./all/$1" "$ch/staging/deb/debian/trixie/Packages"; }
    signed_index() { grep -qx 'Label: OpenMixer-Staging' "$ch/staging/deb/debian/trixie/InRelease"; }
    plant() { # a deb in wave-c's devel tree that its signed index does not list
        mkdeb omx-lib 3.17.0 "$work/wave-c"; publish devel/wave-c/deb "$work/wave-c" LABEL=OpenMixer-Devel
        mkdeb omx-plant 1.0 "$work/plant"; cp "$work/plant/trixie/"*.deb "$ch/devel/wave-c/deb/debian/trixie/all/"
    }
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
rec=built/omx-lib/3.15.0.commit
[ -f "$ch/devel/wave-a/$kind/$rec" ] || fail "the fixture's wave records no build of omx-lib 3.15.0"
cmp -s "$ch/staging/$kind/$clash" "$ch/devel/wave-b/$kind/$clash" && fail "the fixture's wave-b 3.14.0 has staging's bytes"
(cd "$ch" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm fixture)
outside_sum > "$work/outside.before"
n=$(( ${#promoted[@]} + $(find "$ch/devel/wave-a/$kind/built" -type f | wc -l) ))
ok "$kind: staging with omx-lib 3.14.0, wave-a with 3.15.0 and omx-new 2.0, wave-b with a rebuilt 3.14.0"

# ---- the promotion of wave-a
"$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-a "$key" > "$work/promote.log" 2>&1 || { cat "$work/promote.log"; fail "the promotion of wave-a failed"; }
for f in "${promoted[@]}" "$rec"; do
    [ -f "$ch/staging/$kind/$f" ] || fail "staging/$kind/$f is not there after the promotion"
    [ "$(sha256sum < "$ch/staging/$kind/$f")" = "$(sha256sum < "$ch/devel/wave-a/$kind/$f")" ] || fail "staging/$kind/$f is not the bytes of devel/wave-a/$kind/$f"
done
[ -f "$ch/staging/$kind/$clash" ] || fail "staging lost its own omx-lib 3.14.0"
for f in "${promoted[@]}"; do indexed "$(basename "$f")" || fail "staging's index does not list $(basename "$f")"; done
indexed "$(basename "$clash")" || fail "staging's index lost its own $(basename "$clash")"
signed_index || fail "staging's index is not signed and labelled after the promotion"
row() { awk -F'\t' -v n="$1" -v v="$2" '$1 == n && $2 == v {print $3}' "$ch/staging/$kind/cells.tsv"; }
[ "$(row omx-lib 3.15.0)" = full ] && [ "$(row omx-new 2.0)" = full ] || fail "staging's cells.tsv does not carry the wave's rows with its set: $(cat "$ch/staging/$kind/cells.tsv")"
[ "$(row omx-lib 3.14.0)" = quick ] || fail "staging's cells.tsv lost its own row: $(cat "$ch/staging/$kind/cells.tsv")"
outside_sum | cmp -s - "$work/outside.before" || fail "the promotion changed files outside staging/$kind: $(outside_sum | diff "$work/outside.before" - | head)"
grep -q "^promoted devel/wave-a/$kind -> staging/$kind: $n file(s) copied" "$work/promote.log" || fail "the promotion does not say what it copied: $(cat "$work/promote.log")"
ok "$kind: wave-a's packages and build record are in staging at the same paths, byte for byte, indexed and signed, cells.tsv merged; nothing else changed"

# a client of staging installs the promoted build
base=file://$ch
if [ "$kind" = rpm ]; then
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    BASE_URL=$base "$actions/add-openmixer/add-staging.sh" >/dev/null
    dnf -q -y --disablerepo='*' --enablerepo='openmixer*' --disablerepo='openmixer-testing*' install omx-lib omx-new >/dev/null
    [ "$(rpm -q --qf '%{VERSION}' omx-lib)" = 3.15.0 ] || fail "a client of staging took omx-lib $(rpm -q --qf '%{VERSION}' omx-lib), not the promoted 3.15.0"
else
    install -D -m 644 "$ch/deb/openmixer.asc" /usr/share/keyrings/openmixer-archive-keyring.asc
    sed -e 's|@SUITE@|trixie|' -e "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/debian/openmixer.sources.in" > /etc/apt/sources.list.d/openmixer.sources
    BASE_URL=$base SUITE=trixie "$actions/add-openmixer/add-staging.sh" >/dev/null
    apt-get update -qq -o APT::Update::Error-Mode=any
    [ "$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')" = 3.15.0 ] || fail "a client of staging is offered $(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}'), not the promoted 3.15.0"
fi
ok "$kind: a client of staging takes the promoted omx-lib 3.15.0"

# ---- again: nothing copied, every package byte kept
sums "staging/$kind" | grep -E "\.$kind\$" > "$work/pk.before"
"$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-a "$key" > "$work/again.log" 2>&1 || { cat "$work/again.log"; fail "promoting wave-a again failed"; }
grep -q ": 0 file(s) copied, $n already there" "$work/again.log" || fail "promoting again copied something: $(cat "$work/again.log")"
sums "staging/$kind" | grep -E "\.$kind\$" | cmp -s - "$work/pk.before" || fail "promoting again changed a package of staging"
ok "$kind: promoting wave-a again copies nothing and keeps every package's bytes"

# ---- refusals: other bytes at a path staging holds; a planted package; a name that is no wave's
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm promoted)
sums staging > "$work/staging.before"
if "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-b "$key" > "$work/b.log" 2>&1; then fail "wave-b, holding $clash with other bytes than staging's, was promoted"; fi
grep -q "^refused staging/$kind/$clash: staging holds it with other bytes" "$work/b.log" || fail "the refusal does not name $clash: $(cat "$work/b.log")"
sums staging | cmp -s - "$work/staging.before" || fail "the refused promotion of wave-b changed staging"
plant
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm planted)
if "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-c "$key" > "$work/c.log" 2>&1; then fail "a wave holding a planted package was promoted"; fi
grep -qE 'not vouch for: nothing was promoted' "$work/c.log" || fail "the planted package's refusal does not say so: $(cat "$work/c.log")"
sums staging | cmp -s - "$work/staging.before" || fail "the refused promotion of wave-c changed staging"
for bad in ../rpm 'Wave A' ''; do
    if "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" "$bad" "$key" > "$work/bad.log" 2>&1; then fail "the wave '$bad' was taken"; fi
done
sums staging | cmp -s - "$work/staging.before" || fail "a refused wave name changed staging"
ok "$kind: other bytes at a path staging holds, a planted package and a name that is no wave's are refused, staging unchanged"
rm -rf "$work"
echo "promote-wave $kind: all passed"
