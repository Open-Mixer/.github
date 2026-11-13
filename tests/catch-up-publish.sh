#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The publish of a catch-up writes no file the channel serves (docs/release-operations.md, "Catching a served version
# up"), on a fixture channel published by the real tree script with a throwaway key:
#   deb  plugin-qualify 0.20.4 served for trixie arm64 with its language pack (all), and a bookworm package beside it;
#        the catch-up brings trixie amd64 and a rebuilt language pack of other bytes
#   rpm  plugin-qualify 0.20.4 served for fc44 x86_64 with its source and a noarch language pack, and an fc45 package;
#        the catch-up brings fc44 aarch64 and a rebuilt source and language pack of other bytes
# Proves: the new cell's package is placed and indexed; the rebuilt arch-independent package (and source rpm) is
# dropped by path, saying so, and the served one is byte-identical after; every file the channel held is byte-identical
# after except the index of the one release (deb) or directory (rpm) that received the package and cells.tsv; cells.tsv
# records the new cell beside the old ones and keeps the version's set. Then a catch-up that would write a file the
# channel holds, byte-identical or not, is refused naming it, and the tree is unchanged by it. Sabotage: the tree script
# with its refusal taken out lets that run through, and this test goes red.
#
#   catch-up-publish.sh rpm|deb     rpm: rpm-build rpm-sign createrepo_c python3-rpm gnupg2; deb: apt-utils gnupg gpgv dpkg-dev
set -euo pipefail
kind=${1:?usage: catch-up-publish.sh rpm|deb}
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${CATCH_UP_ACTIONS:-$here/.github/actions}
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

snapshot() { (cd "$tree" && find . -type f ! -path './.git/*' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$1"; }
# changed <before> <after>: the paths whose bytes changed, appeared or went
changed() { diff <(cat "$1") <(cat "$2") | sed -n 's/^[<>] [0-9a-f]*  \.\///p' | LC_ALL=C sort -u; }
row() { awk -F'\t' -v n="$1" -v v="$2" '$1 == n && $2 == v {print $3 "|" $4}' "$tree/cells.tsv"; }

case $kind in
deb)
    mkdeb() { # <package> <version> <arch> <suite> <description> <out dir>
        local d=$work/b-$1-$3-$5
        mkdir -p "$d/DEBIAN" "$6/$4"
        printf '%s\n' "Package: $1" "Version: $2" "Architecture: $3" 'Maintainer: t <t@example.org>' "Description: $5" > "$d/DEBIAN/control"
        dpkg-deb -b "$d" "$6/$4/${1}_${2}_$3.deb" >/dev/null
    }
    publish() { CATCH_UP=${CU:-} "$actions/publish-debs/publish-tree.sh" "$tree" "$1" "$key"; }
    mkdeb plugin-qualify 0.20.4-1 arm64 trixie first "$work/first"
    mkdeb plugin-qualify-l10n-ca 0.20.4-1 all trixie first "$work/first"
    mkdeb other 1.0-1 amd64 bookworm first "$work/first"
    MATRIX_SET=quick publish "$work/first" > /dev/null
    mkdeb plugin-qualify 0.20.4-1 amd64 trixie catchup "$work/catchup"
    mkdeb plugin-qualify-l10n-ca 0.20.4-1 all trixie rebuilt "$work/catchup"
    new=debian/trixie/amd64/plugin-qualify_0.20.4-1_amd64.deb
    indep=debian/trixie/all/plugin-qualify-l10n-ca_0.20.4-1_all.deb
    index='debian/trixie/(Packages|Packages\.gz|Release|InRelease|Release\.gpg)'
    served_cells='trixie/amd64 trixie/arm64'
    cmp -s "$work/catchup/trixie/plugin-qualify-l10n-ca_0.20.4-1_all.deb" "$tree/$indep" && fail "the fixture's rebuilt language pack has the served bytes"
    clash=$work/catchup/trixie/plugin-qualify_0.20.4-1_amd64.deb
    same() { mkdir -p "$work/same/trixie"; cp "$tree/debian/trixie/arm64/plugin-qualify_0.20.4-1_arm64.deb" "$work/same/trixie/"; echo debian/trixie/arm64/plugin-qualify_0.20.4-1_arm64.deb; }
    indexed() { grep -qx 'Filename: ./amd64/plugin-qualify_0.20.4-1_amd64.deb' "$tree/debian/trixie/Packages"; }
    ;;
rpm)
    mkrpm() { # <name> <arch> <release> <description> <out dir> [sources]
        local spec=$work/$1-$2-$3-$4.spec
        printf '%s\n' "Name: $1" 'Version: 0.20.4' "Release: 1.fc$3" 'Summary: t' 'License: MIT' \
            "$([ "$2" = noarch ] && echo 'BuildArch: noarch')" '%description' "$4" '%files' > "$spec"
        rpmbuild "-b${6:-b}" --quiet --define "_topdir $work/rb-$1-$2-$3-$4" --define 'dist %{nil}' --define 'debug_package %{nil}' \
            $([ "$2" = noarch ] || echo "--target $2") "$spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2 fc$3"
        mkdir -p "$5"
        find "$work/rb-$1-$2-$3-$4" -name '*.rpm' -exec cp {} "$5/" \;
    }
    publish() { CATCH_UP=${CU:-} "$actions/publish-rpms/publish-tree.sh" "$tree" "$1" "$key"; }
    mkrpm plugin-qualify x86_64 44 first "$work/first" a
    mkrpm plugin-qualify-langpack-ca noarch 44 first "$work/first"
    mkrpm other x86_64 45 first "$work/first"
    MATRIX_SET=quick publish "$work/first" > /dev/null
    sleep 1 # another build time: the rebuilt source and language pack get other bytes
    mkrpm plugin-qualify aarch64 44 catchup "$work/catchup" a
    mkrpm plugin-qualify-langpack-ca noarch 44 rebuilt "$work/catchup"
    new=fedora/44/aarch64/plugin-qualify-0.20.4-1.fc44.aarch64.rpm
    indep=fedora/44/noarch/plugin-qualify-langpack-ca-0.20.4-1.fc44.noarch.rpm
    srpm=fedora/44/SRPMS/plugin-qualify-0.20.4-1.fc44.src.rpm
    [ -f "$tree/$srpm" ] && [ -f "$work/catchup/$(basename "$srpm")" ] || fail "the fixture has no source rpm on both sides"
    cmp -s "$work/catchup/$(basename "$srpm")" "$tree/$srpm" && fail "the fixture's rebuilt source rpm has the served bytes"
    index='fedora/44/aarch64/repodata/.*'
    served_cells='fc44/aarch64 fc44/x86_64'
    clash=$work/catchup/plugin-qualify-0.20.4-1.fc44.aarch64.rpm
    same() { mkdir -p "$work/same"; cp "$tree/fedora/44/x86_64/plugin-qualify-0.20.4-1.fc44.x86_64.rpm" "$work/same/"; echo fedora/44/x86_64/plugin-qualify-0.20.4-1.fc44.x86_64.rpm; }
    indexed() { find "$tree/fedora/44/aarch64/repodata" -name '*primary.xml*' -exec zcat -f {} + 2>/dev/null | grep -q 'plugin-qualify-0.20.4-1.fc44.aarch64.rpm'; }
    ;;
*) fail "usage: catch-up-publish.sh rpm|deb" ;;
esac
[ "$(row plugin-qualify 0.20.4)" = "quick|${served_cells#* }" ] || fail "the fixture channel records $(row plugin-qualify 0.20.4)"
cmp -s "$work/catchup/"*"/$(basename "$indep")" "$tree/$indep" 2>/dev/null || cmp -s "$work/catchup/$(basename "$indep")" "$tree/$indep" &&
    fail "the fixture's rebuilt arch-independent package has the served bytes"
cp "$tree/cells.tsv" "$work/cells.before"

# ---- the catch-up: the missing cell placed, the arch-independent rebuild dropped, everything else as it was
snapshot "$work/before"
CU=true publish "$work/catchup" > "$work/log" 2>&1 || { cat "$work/log"; fail "the catch-up publish failed"; }
snapshot "$work/after"
[ -f "$tree/$new" ] || fail "the catch-up did not place $new"
indexed || fail "the new cell's package is not in its index"
grep -q "^dropped $(basename "$indep") (catch-up: the channel serves $indep already" "$work/log" || { cat "$work/log"; fail "the rebuilt $(basename "$indep") was not dropped by path, saying so"; }
if [ "$kind" = rpm ]; then
    grep -q "^dropped $(basename "$srpm") " "$work/log" || { cat "$work/log"; fail "the rebuilt source rpm was not dropped"; }
fi
unexpected=$(changed "$work/before" "$work/after" | grep -vxE "$new|cells\.tsv|$index" || true)
[ -z "$unexpected" ] || { cat "$work/log"; fail "the catch-up changed served files: $unexpected"; }
changed "$work/before" "$work/after" | grep -qxF "$new" || fail "the snapshot does not see the new file"
ok "$kind: the missing cell placed and indexed; the rebuilt arch-independent package dropped; every other file byte-identical"
[ "$(row plugin-qualify 0.20.4)" = "quick|$served_cells" ] || fail "cells.tsv records $(row plugin-qualify 0.20.4) for 0.20.4, not quick|$served_cells"
diff <(grep -v '^plugin-qualify	0.20.4	' "$work/cells.before") <(grep -v '^plugin-qualify	0.20.4	' "$tree/cells.tsv") > /dev/null ||
    fail "cells.tsv changed other lines: $(diff "$work/cells.before" "$tree/cells.tsv")"
ok "$kind: cells.tsv records the new cell beside the served one, keeps the version's set and every other line"

# ---- a catch-up that would write a served file is refused, and the tree is not touched
refused() { # <what> <dir> <served path>
    snapshot "$work/before"
    if CU=true publish "$2" > "$work/log" 2>&1; then cat "$work/log"; fail "a catch-up wrote over $1"; fi
    grep -q "^refused $3: the channel serves it" "$work/log" || { cat "$work/log"; fail "the refusal of $1 does not name $3"; }
    grep -q 'nothing was placed or signed' "$work/log" || fail "the refusal of $1 does not say nothing was placed or signed"
    snapshot "$work/after"
    cmp -s "$work/before" "$work/after" || fail "the refused catch-up changed the tree: $(changed "$work/before" "$work/after")"
}
refused "the cell it has just filled" "$work/catchup" "$new"
path=$(same)
refused "a byte-identical served package" "$work/same" "$path"
ok "$kind: a catch-up of a file the channel serves, byte-identical or not, is refused by name and changes nothing"

# a run with only served arch-independent packages left places nothing and is refused
rm -rf "$work/only"; mkdir -p "$work/only"
if [ "$kind" = deb ]; then mkdir -p "$work/only/trixie"; cp "$work/catchup/trixie/$(basename "$indep")" "$work/only/trixie/"; else cp "$work/catchup/$(basename "$indep")" "$work/only/"; fi
snapshot "$work/before"
if CU=true publish "$work/only" > "$work/log" 2>&1; then cat "$work/log"; fail "a catch-up with nothing to place passed"; fi
grep -q 'nothing was left to place' "$work/log" || { cat "$work/log"; fail "an empty catch-up is not refused by name"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the empty catch-up changed the tree"
ok "$kind: a catch-up left with nothing to place is refused"

# ---- sabotage: the refusal taken out of the tree script
if [ -z "${CATCH_UP_ACTIONS:-}" ]; then
    sab=$work/sab
    mkdir -p "$sab"
    cp -a "$here/.github" "$here/packaging" "$sab/"
    script=$sab/.github/actions/publish-${kind}s/publish-tree.sh
    sed -i 's/^            clash=1$/            :/' "$script"
    ! cmp -s "$script" "$here/.github/actions/publish-${kind}s/publish-tree.sh" || fail "the sabotage did not change publish-tree.sh"
    if CATCH_UP_ACTIONS=$sab/.github/actions bash "$0" "$kind" > "$work/sab.log" 2>&1; then
        cat "$work/sab.log"; fail "with the refusal taken out, a catch-up wrote over a served file and this test stayed green"
    fi
    grep -q 'FAIL: a catch-up wrote over' "$work/sab.log" || { cat "$work/sab.log"; fail "the sabotage went red for another reason"; }
    ok "$kind: sabotage: without the refusal a catch-up writes over a served file, and this test goes red"
fi
echo "catch-up-publish $kind: the missing cell only, served files byte-identical, overwrites refused"
