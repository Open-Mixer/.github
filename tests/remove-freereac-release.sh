#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# tools/remove-freereac-release.sh on a stub channel built by the publish's own tree scripts, holding what the real one
# holds: freereac-release 1-2 (the mirror's), openmixer-release 1-9 that requires it, and another package. Proves:
#   - freereac-release leaves the tree (rpm: every fedora/<release>/<arch>; deb: the pool file, the index entry and its
#     changelog directory), and the metadata is made again and signed by the key the channel serves;
#   - every other package of the tree is byte-identical, and still in the metadata; another package's changelog stays;
#   - a second run finds nothing and changes nothing;
#   - a file named like freereac-release that is another package is refused, and nothing is removed;
#   - a checkout with changes before the run is refused;
#   - the audit refuses a run whose tree scripts change anything but freereac-release and metadata (a sabotaged copy of
#     publish-tree.sh that also writes a site file).
# Needs the publish tools (rpm: rpm-build rpm-sign createrepo_c gnupg2 git python3-rpm zstd; deb: dpkg-dev apt-utils gnupg
# gpgv git); writes nothing outside a scratch directory, as any user.
#
#   remove-freereac-release.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
kind=${1:?usage: remove-freereac-release.sh rpm|deb}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Removal Test <removal@example.org>' ed25519 sign 1y
KEY=$(gpg --with-colons --fingerprint removal@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$KEY" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed
export CHANGELOGS_URL=https://www.openmixer.org/deb/changelogs

ch=$work/channel
mkdir -p "$ch/rpm" "$ch/deb" "$ch/docs" "$work/src"
echo '<html>site</html>' > "$ch/index.html"
git -C "$ch" init -q
commit() { (cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm "$1"); }

case $kind in
rpm)
    mkpkg() { # <name> <version> <release> [requires]
        local d=$work/rb-$1-$2-$3
        mkdir -p "$d"
        { printf '%s\n' "Name: $1" "Version: $2" "Release: $3" 'Summary: t' 'License: MIT' 'BuildArch: noarch'
          [ -z "${4:-}" ] || echo "Requires: $4"
          printf '%s\n' '%description' 't' '%files'; } > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2"
        find "$d/RPMS" -name '*.rpm'
    }
    cp "$(mkpkg freereac-release 1 2.fc45)" "$(mkpkg openmixer-release 1 9.fc45 'freereac-release >= 1-2')" \
        "$(mkpkg omx-lib 3.14.1 1.fc45)" "$work/src/"
    "$root/.github/actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/src" "$KEY" >/dev/null
    gone=rpm/fedora/45/noarch/freereac-release-1-2.fc45.noarch.rpm
    # the names a dnf client reads from the metadata of every directory, one per line
    listed() {
        local d p
        for d in "$ch"/rpm/fedora/*/*/; do
            p=$(sed -n 's/.*<location href="\(repodata\/[^"]*primary\.xml[^"]*\)".*/\1/p' "$d/repodata/repomd.xml")
            case $p in *.zst) zstdcat "$d$p" ;; *.gz) zcat "$d$p" ;; *.xz) xzcat "$d$p" ;; *) cat "$d$p" ;; esac
        done | sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' | sort -u
    }
    signed_meta() { local d; for d in "$ch"/rpm/fedora/*/*/; do gpg --batch -q --verify "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml" 2>/dev/null || return 1; done; }
    impostor() { cp "$(mkpkg omx-evil 1 1.fc45)" "$ch/rpm/fedora/45/noarch/freereac-release-9-9.fc45.noarch.rpm"; }
    ;;
deb)
    mkdeb() { # <name> <version> [depends]
        local d=$work/db-$1-$2
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: all' 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
        [ -z "${3:-}" ] || echo "Depends: $3" >> "$d/DEBIAN/control"
        printf '%s (%s) unstable; urgency=medium\n\n  * t\n\n -- t <t@example.org>  Mon, 23 Nov 2026 12:00:00 +0100\n' "$1" "$2" |
            gzip -9n > "$d/usr/share/doc/$1/changelog.Debian.gz"
        dpkg-deb --root-owner-group -b "$d" "$work/$1_$2_all.deb" >/dev/null
        echo "$work/$1_$2_all.deb"
    }
    mkdir -p "$work/src/trixie"
    cp "$(mkdeb freereac-release 1-2)" "$(mkdeb openmixer-release 1-9 'freereac-release (>= 1-2)')" "$(mkdeb omx-lib 3.14.1)" "$work/src/trixie/"
    "$root/.github/actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/src" "$KEY" >/dev/null
    gone=deb/debian/trixie/all/freereac-release_1-2_all.deb
    [ -d "$ch/deb/changelogs/f/freereac-release" ] || fail "the stub channel has no changelog directory for freereac-release"
    listed() { sed -n 's/^Package: //p' "$ch"/deb/debian/*/Packages | sort -u; }
    signed_meta() {
        local s
        gpg --batch --export "$KEY" > "$work/keyring.gpg"
        for s in "$ch"/deb/debian/*/; do
            gpgv --keyring "$work/keyring.gpg" "$s/InRelease" >/dev/null 2>&1 || return 1
            gpgv --keyring "$work/keyring.gpg" "$s/Release.gpg" "$s/Release" >/dev/null 2>&1 || return 1
            grep -q "$(sha256sum < "$s/Packages" | cut -d' ' -f1)" "$s/Release" || return 1
        done
    }
    impostor() { cp "$(mkdeb omx-evil 1)" "$ch/deb/debian/trixie/all/freereac-release_9-9_all.deb"; }
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
commit channel
[ -f "$ch/$gone" ] || fail "the stub channel does not serve $gone"
listed | grep -qx freereac-release || fail "the stub channel's metadata does not list freereac-release"
pkgsum() { (cd "$ch" && find "$kind" -type f \( -name '*.rpm' -o -name '*.deb' \) ! -name 'freereac-release[-_]*' -print0 | sort -z | xargs -0 sha256sum); }
pkgsum > "$work/others.before"
ok "$kind: a stub channel serving freereac-release 1-2 and openmixer-release 1-9 that requires it"

# ---- a file named like freereac-release that is another package: refused, nothing removed
impostor; commit impostor
if "$root/tools/remove-freereac-release.sh" "$kind" "$ch" "$KEY" > "$work/imp.log" 2>&1; then fail "a file named like freereac-release that is another package was accepted"; fi
grep -q "is the package 'omx-evil': nothing was removed" "$work/imp.log" || fail "the impostor is not named: $(cat "$work/imp.log")"
[ -z "$(cd "$ch" && git status --porcelain)" ] || fail "the refused run changed the tree: $(cd "$ch" && git status --short | head)"
(cd "$ch" && git reset -q --hard HEAD~1)
ok "$kind: a file named like freereac-release that is another package is refused, and nothing is removed"

# ---- a checkout with changes before the run is refused
echo x > "$ch/$kind/stray"
if "$root/tools/remove-freereac-release.sh" "$kind" "$ch" "$KEY" > "$work/dirty.log" 2>&1; then fail "a checkout with changes was accepted"; fi
grep -q 'has changes before the removal' "$work/dirty.log" || fail "the dirty checkout is not named: $(cat "$work/dirty.log")"
rm "$ch/$kind/stray"
ok "$kind: a checkout with changes before the run is refused"

# ---- the audit: tree scripts that write anything else are refused (a sabotaged copy of the repository)
mkdir -p "$work/sab" && cp -r "$root/.github" "$root/tools" "$root/packaging" "$work/sab/"
echo 'echo sabotage > "$(dirname "$1")/index.html"' >> "$work/sab/.github/actions/publish-${kind}s/publish-tree.sh"
if "$work/sab/tools/remove-freereac-release.sh" "$kind" "$ch" "$KEY" > "$work/sab.log" 2>&1; then fail "the audit let a site file change through"; fi
grep -q 'refused: index.html changed, outside' "$work/sab.log" || fail "the audit does not name the site file: $(tail -5 "$work/sab.log")"
(cd "$ch" && git checkout -q -- . && git clean -qfdx)
ok "$kind: the audit refuses tree scripts that change anything but freereac-release and metadata"

# ---- the removal
"$root/tools/remove-freereac-release.sh" "$kind" "$ch" "$KEY" > "$work/run.log" 2>&1 || { cat "$work/run.log"; fail "the removal failed"; }
[ ! -e "$ch/$gone" ] || fail "$gone is still there"
[ -z "$(cd "$ch" && find "$kind" -name 'freereac-release[-_]*')" ] || fail "a freereac-release file is left: $(cd "$ch" && find "$kind" -name 'freereac-release*')"
! listed | grep -qx freereac-release || fail "the metadata still lists freereac-release"
listed | grep -qx openmixer-release && listed | grep -qx omx-lib || fail "the metadata lost another package: $(listed | tr '\n' ' ')"
pkgsum | cmp -s - "$work/others.before" || fail "another package changed: $(pkgsum | diff "$work/others.before" - | head)"
signed_meta || fail "the regenerated metadata is not signed by the channel's key"
if [ "$kind" = deb ]; then
    [ ! -e "$ch/deb/changelogs/f/freereac-release" ] || fail "the changelog directory of freereac-release is still there"
    [ -d "$ch/deb/changelogs/o/openmixer-release" ] || fail "another package's changelog went"
fi
[ -z "$(cd "$ch" && git status --porcelain -- . ":(exclude)$kind")" ] || fail "the removal wrote outside $kind/"
ok "$kind: freereac-release is gone from the tree and the metadata, signed again; every other package is untouched"
commit removal

# ---- again: nothing to remove, nothing changes
"$root/tools/remove-freereac-release.sh" "$kind" "$ch" "$KEY" > "$work/again.log" 2>&1 || { cat "$work/again.log"; fail "the second run failed"; }
grep -q 'nothing to remove' "$work/again.log" || fail "the second run does not say there is nothing to remove: $(cat "$work/again.log")"
[ -z "$(cd "$ch" && git status --porcelain)" ] || fail "the second run changed the tree"
ok "$kind: a second run finds nothing and changes nothing"
echo "remove-freereac-release $kind: ok"
