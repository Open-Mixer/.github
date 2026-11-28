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
#   - one line of a wave (PROMOTE_PACKAGES) moves its packages, record and cells row alone, and a later whole-wave
#     promotion keeps those bytes; a selection of nothing is refused;
#   - a version built twice (PROMOTE_KEEP_STAGING <name>=<version>) keeps staging's build and reports the wave's copy
#     superseded; keeping a version staging does not hold, or a token matching nothing, is refused;
#   - a keep token names a SOURCE and version (run 46176982537, devel-wave-2026-11-28-n4): it keeps the files built from
#     that source under another binary name (omx-src=1.0 keeps omx-src-tools 1.0); a kind holding no package of the source
#     (n4's deb tree held no libdiginet at all) is named "no <kind> of <name> in the wave" and promotes the rest, when the
#     other kind's tree holds the version (its build record, a package file of that name and version, or a deb index's
#     Source); a token on no kind, or a version the kind does not hold of a source it holds, stays refused.
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
    mk() { mkpkg "$@"; }
    mksrc() { # <source> <binary> <version> <out dir> [description]: a binary package of another name than its source
        local d=$work/rs-$1-$3-${5:-t}
        mkdir -p "$d" "$4"
        printf '%s\n' "Name: $1" "Version: $3" 'Release: 1.fc45' 'Summary: t' 'License: MIT' 'BuildArch: noarch' '%description' t \
            "%package -n $2" 'Summary: t' "%description -n $2" "${5:-t}" "%files -n $2" > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 ($2) $3"
        find "$d/RPMS" -name '*.rpm' -exec cp {} "$4/" \;
    }
    other=deb
    other_file() { echo "debian/trixie/amd64/$1_$2-1_amd64.deb"; }
    pubw() { local w=$1 d=$2; shift 2; publish "devel/$w/rpm" "$d" "devel/$w" "$@"; }
    at() { echo "fedora/45/noarch/$1-$2-1.fc45.noarch.rpm"; }
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
    mk() { mkdeb "$@"; }
    mksrc() { # <source> <binary> <version> <out dir> [description]: a binary package of another name than its source
        local d=$work/ds-$2-$3-${5:-t}
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$2" "$4/trixie"
        printf '%s\n' "Package: $2" "Source: $1" "Version: $3" 'Architecture: all' 'Maintainer: t <t@example.org>' "Description: ${5:-t}" > "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$4/trixie/$2_$3_all.deb" >/dev/null
    }
    other=rpm
    other_file() { echo "fedora/45/SRPMS/$1-$2-1.fc45.src.rpm"; }
    pubw() { local w=$1 d=$2; shift 2; publish "devel/$w/deb" "$d" LABEL=OpenMixer-Devel "$@"; }
    at() { echo "debian/trixie/all/$1_$2_all.deb"; }
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
    # a container an earlier test of the job used: what it installed or added is gone first
    for p in omx-lib omx-app omx-new; do rpm -e --nodeps "$p" >/dev/null 2>&1 || true; done
    rm -f /etc/yum.repos.d/openmixer-staging.repo /etc/yum.repos.d/openmixer-devel.repo
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    BASE_URL=$base "$actions/add-openmixer/add-staging.sh" >/dev/null
    dnf -q -y --disablerepo='*' --enablerepo='openmixer*' --disablerepo='openmixer-testing*' install omx-lib omx-new >/dev/null
    [ "$(rpm -q --qf '%{VERSION}' omx-lib)" = 3.15.0 ] || fail "a client of staging took omx-lib $(rpm -q --qf '%{VERSION}' omx-lib), not the promoted 3.15.0"
else
    # a container an earlier test of the job used: what it installed or added is gone first
    for p in omx-lib omx-new; do dpkg -P "$p" >/dev/null 2>&1 || true; done
    rm -f /etc/apt/sources.list.d/openmixer-staging.sources /etc/apt/preferences.d/openmixer-staging.pref \
        /etc/apt/sources.list.d/openmixer-devel.sources /etc/apt/preferences.d/openmixer-devel.pref
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
# ---- ONE LINE of a wave (PROMOTE_PACKAGES, devel-chain.sh's continuous promotion): wave-d holds two lines' packages,
# omx-two 1.0 and omx-lib 3.16.0; promoting omx-two moves its file, its build record and its cells.tsv row alone, and the
# whole wave promoted afterwards keeps omx-two's bytes and adds omx-lib's
mk omx-two 1.0 "$work/wave-d"; pubw wave-d "$work/wave-d" MATRIX_SET=full BUILT_COMMIT=$commit BUILT_NAME=omx-two
mk omx-lib 3.16.0 "$work/wave-d2"; pubw wave-d "$work/wave-d2" MATRIX_SET=full
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-d)
two=$(at omx-two 1.0) lib16=$(at omx-lib 3.16.0)
PROMOTE_PACKAGES=omx-two "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-d "$key" > "$work/d.log" 2>&1 || { cat "$work/d.log"; fail "the promotion of wave-d's omx-two line failed"; }
cmp -s "$ch/staging/$kind/$two" "$ch/devel/wave-d/$kind/$two" || fail "staging/$kind/$two is not the bytes of the wave's after its line's promotion"
[ -f "$ch/staging/$kind/built/omx-two/1.0.commit" ] || fail "the line's build record built/omx-two/1.0.commit did not move"
[ ! -e "$ch/staging/$kind/$lib16" ] || fail "the promotion of the omx-two line moved $lib16, another line's package"
[ "$(row omx-two 1.0)" = full ] || fail "staging's cells.tsv lacks the line's row: $(cat "$ch/staging/$kind/cells.tsv")"
[ -z "$(row omx-lib 3.16.0)" ] || fail "staging's cells.tsv took another line's row: $(cat "$ch/staging/$kind/cells.tsv")"
indexed "$(basename "$two")" || fail "staging's index does not list the line's $(basename "$two")"
grep -q "^promoted devel/wave-d/$kind (omx-two) -> staging/$kind: 2 file(s) copied" "$work/d.log" || fail "the line's promotion does not say what it copied: $(cat "$work/d.log")"
sums "staging/$kind/$two" > "$work/two.sum"
"$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-d "$key" > "$work/d2.log" 2>&1 || { cat "$work/d2.log"; fail "the whole of wave-d after its line failed"; }
cmp -s "$ch/staging/$kind/$lib16" "$ch/devel/wave-d/$kind/$lib16" || fail "the whole wave did not bring $lib16"
sums "staging/$kind/$two" | cmp -s - "$work/two.sum" || fail "the whole wave changed the line's promoted $two"
grep -q ": 1 file(s) copied, 2 already there" "$work/d2.log" || fail "the whole wave after its line does not keep the line's files: $(cat "$work/d2.log")"
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-d-promoted)
sums staging > "$work/staging.before"
if PROMOTE_PACKAGES=omx-none "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-d "$key" > "$work/none.log" 2>&1; then fail "a line naming no package of the wave was promoted green"; fi
grep -q "omx-none matches no package of devel/wave-d/$kind: nothing was promoted" "$work/none.log" || fail "the empty selection is not refused by name: $(cat "$work/none.log")"
sums staging | cmp -s - "$work/staging.before" || fail "the refused empty selection changed staging"
ok "$kind: one line of a wave promotes its own packages, record and cells row alone; the whole wave after it keeps them; a selection of nothing is refused"

# ---- the reconciliation of a version built twice (PROMOTE_KEEP_STAGING): wave-e holds a rebuilt omx-lib 3.14.0 (other
# bytes than staging's, with a build record) and omx-e 1.0. Refused as before without the list; with omx-lib=3.14.0
# kept, omx-e is promoted, staging's 3.14.0 keeps every byte and its row, the wave's copy and record are reported
# superseded and never copied; a kept version staging does not hold, and a token matching nothing, are refused
sleep 1
mk omx-lib 3.14.0 "$work/wave-e" again; pubw wave-e "$work/wave-e" MATRIX_SET=full BUILT_COMMIT=$commit BUILT_NAME=omx-lib
mk omx-e 1.0 "$work/wave-e2"; pubw wave-e "$work/wave-e2" MATRIX_SET=full
cmp -s "$ch/staging/$kind/$clash" "$ch/devel/wave-e/$kind/$clash" && fail "the fixture's wave-e 3.14.0 has staging's bytes"
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-e)
sums staging > "$work/staging.before"
if "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-e "$key" > "$work/e0.log" 2>&1; then fail "wave-e, holding $clash with other bytes, was promoted with nothing kept"; fi
sums staging | cmp -s - "$work/staging.before" || fail "the refused promotion of wave-e changed staging"
for bad in omx-e=1.0 omx-zz=9.9; do
    if PROMOTE_KEEP_STAGING=$bad "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-e "$key" > "$work/ebad.log" 2>&1; then fail "keep-staging $bad was taken"; fi
    sums staging | cmp -s - "$work/staging.before" || fail "the refused keep-staging $bad changed staging"
done
grep -q "keep-staging omx-e=1.0: staging/$kind/$(at omx-e 1.0) is not there" <(PROMOTE_KEEP_STAGING=omx-e=1.0 "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-e "$key" 2>&1) || fail "keeping a version staging does not hold is not refused by name"
sha_before=$(sha256sum < "$ch/staging/$kind/$clash")
PROMOTE_KEEP_STAGING=omx-lib=3.14.0 "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-e "$key" > "$work/e.log" 2>&1 || { cat "$work/e.log"; fail "wave-e with omx-lib=3.14.0 kept failed"; }
[ "$(sha256sum < "$ch/staging/$kind/$clash")" = "$sha_before" ] || fail "staging's own $clash changed: a published file was replaced"
cmp -s "$ch/staging/$kind/$(at omx-e 1.0)" "$ch/devel/wave-e/$kind/$(at omx-e 1.0)" || fail "wave-e's omx-e 1.0 did not move"
[ ! -e "$ch/staging/$kind/built/omx-lib/3.14.0.commit" ] || fail "the superseded build record built/omx-lib/3.14.0.commit was copied"
[ "$(row omx-lib 3.14.0)" = quick ] || fail "staging's row of its own omx-lib 3.14.0 was replaced by the wave's: $(cat "$ch/staging/$kind/cells.tsv")"
indexed "$(basename "$clash")" || fail "staging's index lost its own $(basename "$clash")"
grep -q "^superseded devel/wave-e/$kind/$clash (omx-lib=3.14.0): staging keeps its own build" "$work/e.log" || fail "the superseded copy is not reported by path: $(cat "$work/e.log")"
grep -q "^superseded devel/wave-e/$kind/built/omx-lib/3.14.0.commit (omx-lib=3.14.0)" "$work/e.log" || fail "the superseded record is not reported: $(cat "$work/e.log")"
grep -q ", 2 superseded by staging's own build$" "$work/e.log" || fail "the summary does not count the superseded files: $(cat "$work/e.log")"
ok "$kind: a version built twice keeps staging's build (bytes, row, no record copied), the wave's copy reported superseded; the rest promotes; bad keeps refused"

# ---- a keep token names a SOURCE (n4: libdiginet=0.1.11, whose packages are libdiginet, libdiginet-devel, diginet-tools):
# staging holds omx-src-tools 1.0 built from source omx-src, wave-f a rebuild of it with other bytes beside omx-f 1.0;
# omx-src=1.0 keeps staging's, by the source name the kind records, not the binary name
mksrc omx-src omx-src-tools 1.0 "$work/staged-f"
if [ "$kind" = rpm ]; then publish staging/rpm "$work/staged-f" staging MATRIX_SET=quick; else publish staging/deb "$work/staged-f" LABEL=OpenMixer-Staging MATRIX_SET=quick; fi
sleep 1
mksrc omx-src omx-src-tools 1.0 "$work/wave-f" rebuilt; pubw wave-f "$work/wave-f" MATRIX_SET=full BUILT_COMMIT=$commit BUILT_NAME=omx-src
mk omx-f 1.0 "$work/wave-f2"; pubw wave-f "$work/wave-f2" MATRIX_SET=full
tools=$(at omx-src-tools 1.0)
[ -f "$ch/staging/$kind/$tools" ] && ! cmp -s "$ch/staging/$kind/$tools" "$ch/devel/wave-f/$kind/$tools" || fail "the fixture's wave-f omx-src-tools 1.0 is not a rebuild of staging's"
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-f)
sha_before=$(sha256sum < "$ch/staging/$kind/$tools")
PROMOTE_KEEP_STAGING=omx-src=1.0 "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-f "$key" > "$work/f.log" 2>&1 || { cat "$work/f.log"; fail "wave-f with source omx-src=1.0 kept failed"; }
[ "$(sha256sum < "$ch/staging/$kind/$tools")" = "$sha_before" ] || fail "staging's own $tools changed"
grep -q "^superseded devel/wave-f/$kind/$tools (omx-src=1.0)" "$work/f.log" || fail "the binary of source omx-src is not superseded by path: $(cat "$work/f.log")"
cmp -s "$ch/staging/$kind/$(at omx-f 1.0)" "$ch/devel/wave-f/$kind/$(at omx-f 1.0)" || fail "wave-f's omx-f 1.0 did not move"
ok "$kind: keep-staging omx-src=1.0 keeps staging's omx-src-tools 1.0, built from that source under another binary name"

# ---- n4's shape: wave-g built omx-n4 0.1.11 on the other kind alone (its build record), omx-n4b 2.0 and omx-n4c 3.0
# there too (a package file; a deb index's Source); this kind holds omx-g 1.0 only
mk omx-g 1.0 "$work/wave-g"; pubw wave-g "$work/wave-g" MATRIX_SET=full
o=$ch/devel/wave-g/$other
mkdir -p "$o/built/omx-n4" "$(dirname "$o/$(other_file omx-n4b 2.0)")" "$o/debian/trixie"
echo "$commit" > "$o/built/omx-n4/0.1.11.commit"
: > "$o/$(other_file omx-n4b 2.0)"
printf '%s\n' 'Package: omx-n4c-bin' 'Source: omx-n4c (3.0-1)' 'Version: 3.0-1' 'Architecture: amd64' '' > "$o/debian/trixie/Packages"
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-g)
for t in omx-n4=0.1.11 omx-n4b=2.0 omx-n4c=3.0; do
    rm -f "$ch/staging/$kind/$(at omx-g 1.0)"
    PROMOTE_KEEP_STAGING=$t "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-g "$key" > "$work/g.log" 2>&1 || { cat "$work/g.log"; fail "wave-g with $t, held by the $other tree alone, was refused"; }
    grep -q "^promote-wave: no $kind of ${t%%=*} in the wave" "$work/g.log" || fail "the kind holding no ${t%%=*} is not named: $(cat "$work/g.log")"
    cmp -s "$ch/staging/$kind/$(at omx-g 1.0)" "$ch/devel/wave-g/$kind/$(at omx-g 1.0)" || fail "wave-g's omx-g 1.0 did not move with $t"
done
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm wave-g-promoted)
sums staging > "$work/staging.before"
for bad in omx-n5=1.0 omx-n4=0.1.12 omx-g=9.9; do
    if PROMOTE_KEEP_STAGING=$bad "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-g "$key" > "$work/gbad.log" 2>&1; then fail "keep-staging $bad was taken: $(cat "$work/gbad.log")"; fi
    sums staging | cmp -s - "$work/staging.before" || fail "the refused keep-staging $bad changed staging"
done
grep -q "omx-g=9.9: devel/wave-g/$kind holds omx-g, but no package of it at 9.9" "$work/gbad.log" || fail "a version the kind does not hold of a source it holds is not refused by name: $(cat "$work/gbad.log")"
grep -q "omx-n5=1.0 matches no package of devel/wave-g/$kind nor of devel/wave-g/$other, on no kind" \
    <(PROMOTE_KEEP_STAGING=omx-n5=1.0 "$actions/promote-wave/promote-wave.sh" "$kind" "$ch" wave-g "$key" 2>&1) || fail "a token on no kind is not refused by name"
ok "$kind: a kind holding no package of a kept source is named and promotes the rest; a token on no kind, or a version of no kind, is refused"
rm -rf "$work"
echo "promote-wave $kind: all passed"
