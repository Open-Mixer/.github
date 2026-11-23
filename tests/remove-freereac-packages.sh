#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# tools/remove-freereac-packages.sh on a stub channel built by the publish's own tree scripts, holding FreeREAC packages as
# the real one does (freereac-release, libreac, reac-pw, reac-stageboxes) beside OpenMixer's (openmixer-release 1-9 that
# requires freereac-release, omx-lib), and a listing of what FreeREAC's channel serves. Proves:
#   - a FreeREAC package FreeREAC's channel serves for the same cell, at the same version or newer, leaves the tree and the
#     metadata (rpm: a noarch package FreeREAC serves in each architecture tree; reac-pw 1.0.43 covered by 1.0.44), and the
#     metadata is made again and signed by the channel's key; a deb source's changelog goes with its last package;
#   - a FreeREAC package FreeREAC does not serve there (a gap) is kept, named as a gap, and stays in the metadata, and so
#     does its changelog;
#   - every OpenMixer package is byte-identical and still in the metadata;
#   - a second run finds nothing to remove and changes nothing;
#   - a file named like a FreeREAC package whose source is not FreeREAC's, or whose home is not FreeREAC, is refused and
#     nothing is removed; a run without FREEREAC_LISTING and a checkout with changes are refused;
#   - the audit refuses tree scripts that change anything else (a sabotaged copy of publish-tree.sh writing a site file).
# Needs the publish tools (rpm: rpm-build rpm-sign createrepo_c gnupg2 git python3-rpm zstd; deb: dpkg-dev apt-utils gnupg
# gpgv git); writes nothing outside a scratch directory, as any user.
#
#   remove-freereac-packages.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
kind=${1:?usage: remove-freereac-packages.sh rpm|deb}
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
tool=$root/tools/remove-freereac-packages.sh

export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Removal Test <removal@example.org>' ed25519 sign 1y
KEY=$(gpg --with-colons --fingerprint removal@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$KEY" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed
export CHANGELOGS_URL=https://www.openmixer.org/deb/changelogs
# the stub channel is built as the real one was, before the organisation guard: as a channel of neither house organisation
export CHANNEL_REPO=Test/stub-channel
unset GITHUB_REPOSITORY_OWNER

ch=$work/channel
mkdir -p "$ch/rpm" "$ch/deb" "$work/src"
echo '<html>site</html>' > "$ch/index.html"
git -C "$ch" init -q
commit() { (cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm "$1"); }
FR=https://github.com/FreeREAC
export FREEREAC_LISTING=$work/freereac-listing.txt

case $kind in
rpm)
    mkpkg() { # <name> <version> <release> <url> [requires]
        local d=$work/rb-$1-$2-$3
        mkdir -p "$d"
        { printf '%s\n' "Name: $1" "Version: $2" "Release: $3" 'Summary: t' 'License: MIT' "URL: $4" 'BuildArch: noarch'
          [ -z "${5:-}" ] || echo "Requires: $5"
          printf '%s\n' '%description' 't' '%files'; } > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2"
        find "$d/RPMS" -name '*.rpm'
    }
    cp "$(mkpkg freereac-release 1 2.fc45 https://freereac.github.io)" "$(mkpkg libreac 1.11.0 1.fc45 "$FR/libreac")" \
        "$(mkpkg reac-pw 1.0.43 1.fc45 "$FR/reac-pw")" "$(mkpkg reac-stageboxes 0.1.0 1.fc45 "$FR/reac-stageboxes")" \
        "$(mkpkg openmixer-release 1 9.fc45 https://www.openmixer.org 'freereac-release >= 1-2')" \
        "$(mkpkg omx-lib 3.14.1 1.fc45 https://www.openmixer.org)" "$work/src/"
    "$root/.github/actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/src" "$KEY" >/dev/null
    # FreeREAC serves freereac-release in noarch, libreac in each architecture tree, reac-pw newer; reac-stageboxes not at all
    printf '%s\n' rpm/fedora/45/noarch/freereac-release-1-2.fc45.noarch.rpm \
        rpm/fedora/45/x86_64/libreac-1.11.0-1.fc45.noarch.rpm rpm/fedora/45/aarch64/libreac-1.11.0-1.fc45.noarch.rpm \
        rpm/fedora/45/x86_64/libreac-devel-9.9.9-1.fc45.x86_64.rpm \
        rpm/fedora/45/noarch/reac-pw-1.0.44-1.fc45.noarch.rpm > "$FREEREAC_LISTING"
    want_gone="freereac-release libreac reac-pw"; want_kept="reac-stageboxes openmixer-release omx-lib"
    listed() {
        local d p
        for d in "$ch"/rpm/fedora/*/*/; do
            p=$(sed -n 's/.*<location href="\(repodata\/[^"]*primary\.xml[^"]*\)".*/\1/p' "$d/repodata/repomd.xml")
            case $p in *.zst) zstdcat "$d$p" ;; *.gz) zcat "$d$p" ;; *.xz) xzcat "$d$p" ;; *) cat "$d$p" ;; esac
        done | sed -n 's/.*<name>\(.*\)<\/name>.*/\1/p' | sort -u
    }
    signed_meta() { local d; for d in "$ch"/rpm/fedora/*/*/; do gpg --batch -q --verify "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml" 2>/dev/null || return 1; done; }
    impostor() { cp "$(mkpkg omx-evil 1 1.fc45 https://www.openmixer.org)" "$ch/rpm/fedora/45/noarch/reac-evil-1-1.fc45.noarch.rpm"; }
    homeless() { cp "$(mkpkg libreac 0.1 1.fc45 https://www.openmixer.org)" "$ch/rpm/fedora/45/noarch/libreac-0.1-1.fc45.noarch.rpm"; }
    ;;
deb)
    mkdeb() { # <name> <version> <homepage> [source] [depends]
        local d=$work/db-$1-$2
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: all' 'Maintainer: t <t@example.org>' "Homepage: $3" 'Description: t' > "$d/DEBIAN/control"
        [ -z "${4:-}" ] || echo "Source: $4" >> "$d/DEBIAN/control"
        [ -z "${5:-}" ] || echo "Depends: $5" >> "$d/DEBIAN/control"
        printf '%s (%s) unstable; urgency=medium\n\n  * t\n\n -- t <t@example.org>  Mon, 23 Nov 2026 12:00:00 +0100\n' "${4:-$1}" "$2" |
            gzip -9n > "$d/usr/share/doc/$1/changelog.Debian.gz"
        dpkg-deb --root-owner-group -b "$d" "$work/$1_$2_all.deb" >/dev/null
        echo "$work/$1_$2_all.deb"
    }
    mkdir -p "$work/src/trixie"
    cp "$(mkdeb freereac-release 1-2 https://freereac.github.io)" "$(mkdeb libreac7 1.11.0 "$FR/libreac" libreac)" \
        "$(mkdeb reac-pw 1.0.43 "$FR/reac-pw")" "$(mkdeb openmixer-release 1-9 https://www.openmixer.org '' 'freereac-release (>= 1-2)')" \
        "$(mkdeb omx-lib 3.14.1 https://www.openmixer.org)" "$work/src/trixie/"
    "$root/.github/actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/src" "$KEY" >/dev/null
    # FreeREAC serves freereac-release and libreac7 there; reac-pw only for another suite
    printf '%s\n' deb/debian/trixie/all/freereac-release_1-2_all.deb deb/debian/trixie/all/libreac7_1.11.0_all.deb \
        deb/debian/bookworm/all/reac-pw_1.0.43_all.deb > "$FREEREAC_LISTING"
    want_gone="freereac-release libreac7"; want_kept="reac-pw openmixer-release omx-lib"
    for c in f/freereac-release libr/libreac r/reac-pw; do [ -d "$ch/deb/changelogs/$c" ] || fail "the stub channel has no changelogs/$c"; done
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
    impostor() { cp "$(mkdeb omx-evil 1 https://www.openmixer.org)" "$ch/deb/debian/trixie/all/reac-evil_1_all.deb"; }
    homeless() { cp "$(mkdeb libreac7 0.1 https://www.openmixer.org libreac)" "$ch/deb/debian/trixie/all/libreac7_0.1_all.deb"; }
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
commit channel
for p in $want_gone $want_kept; do listed | grep -qx "$p" || fail "the stub channel's metadata does not list $p"; done
others() { (cd "$ch" && find "$kind" -type f \( -name 'openmixer-*' -o -name 'omx-*' \) \( -name '*.rpm' -o -name '*.deb' \) -print0 | sort -z | xargs -0 sha256sum); }
others > "$work/others.before"
ok "$kind: a stub channel serving FreeREAC's packages beside OpenMixer's"

# ---- refusals, each leaving the tracked tree as it was
refuse() { # <label> <expected text> [VAR=value...]: the run fails, names it, and changes nothing tracked
    local label=$1 text=$2; shift 2
    if env "$@" "$tool" "$kind" "$ch" "$KEY" > "$work/r.log" 2>&1; then fail "$label was accepted"; fi
    grep -q -- "$text" "$work/r.log" || fail "$label is not named: $(tail -3 "$work/r.log")"
    [ -z "$(cd "$ch" && git status --porcelain -- "$kind" | grep -v '^??')" ] || fail "$label: the refused run changed the tree: $(cd "$ch" && git status --short | head)"
}
impostor; commit impostor
refuse 'a file named like a FreeREAC package whose source is not FreeREAC' "but its source is 'omx-evil': nothing was removed"
(cd "$ch" && git reset -q --hard HEAD~1)
homeless; commit homeless
refuse 'a FreeREAC-named package whose home is not FreeREAC' 'does not name FreeREAC as its home'
(cd "$ch" && git reset -q --hard HEAD~1)
refuse 'a run without FREEREAC_LISTING' 'FREEREAC_LISTING names no file' FREEREAC_LISTING=
echo x > "$ch/$kind/stray"
refuse 'a checkout with changes' 'has changes before the removal'
(cd "$ch" && git clean -qfdx)
ok "$kind: an impostor, a package whose home is not FreeREAC, a missing listing and a dirty checkout are refused, nothing removed"

# ---- the audit: tree scripts that write anything else are refused (a sabotaged copy of the repository)
mkdir -p "$work/sab" && cp -r "$root/.github" "$root/tools" "$root/packaging" "$work/sab/"
echo 'echo sabotage > "$(dirname "$1")/index.html"' >> "$work/sab/.github/actions/publish-${kind}s/publish-tree.sh"
if "$work/sab/tools/remove-freereac-packages.sh" "$kind" "$ch" "$KEY" > "$work/sab.log" 2>&1; then fail "the audit let a site file change through"; fi
grep -q 'refused: index.html changed, outside' "$work/sab.log" || fail "the audit does not name the site file: $(tail -5 "$work/sab.log")"
(cd "$ch" && git checkout -q -- . && git clean -qfdx)
ok "$kind: the audit refuses tree scripts that change anything but FreeREAC's packages and metadata"

# ---- the removal
"$tool" "$kind" "$ch" "$KEY" > "$work/run.log" 2>&1 || { cat "$work/run.log"; fail "the removal failed"; }
for p in $want_gone; do ! listed | grep -qx "$p" || fail "the metadata still lists $p"; done
for p in $want_kept; do listed | grep -qx "$p" || fail "the metadata lost $p"; done
[ "$(grep -cE '^removed .*\.(rpm|deb)$' "$work/run.log")" = "$(wc -w <<< "$want_gone")" ] || fail "removed other than $want_gone: $(grep '^removed' "$work/run.log")"
gap=${want_kept%% *}
grep -q "^kept (gap) .*$gap" "$work/run.log" || fail "the gap ($gap) is not named: $(cat "$work/run.log")"
others | cmp -s - "$work/others.before" || fail "an OpenMixer package changed: $(others | diff "$work/others.before" - | head)"
signed_meta || fail "the regenerated metadata is not signed by the channel's key"
if [ "$kind" = deb ]; then
    [ ! -e "$ch/deb/changelogs/f/freereac-release" ] && [ ! -e "$ch/deb/changelogs/libr/libreac" ] || fail "a removed source's changelog is still there"
    [ -d "$ch/deb/changelogs/r/reac-pw" ] || fail "the changelog of reac-pw, kept for its gap, went"
fi
[ -z "$(cd "$ch" && git status --porcelain -- . ":(exclude)$kind")" ] || fail "the removal wrote outside $kind/"
ok "$kind: the covered FreeREAC packages leave ($want_gone), the gap stays named ($gap), metadata signed again, OpenMixer's untouched"
commit removal

# ---- again: nothing to remove, nothing changes
"$tool" "$kind" "$ch" "$KEY" > "$work/again.log" 2>&1 || { cat "$work/again.log"; fail "the second run failed"; }
grep -q 'nothing to remove' "$work/again.log" || fail "the second run does not say there is nothing to remove: $(cat "$work/again.log")"
[ -z "$(cd "$ch" && git status --porcelain)" ] || fail "the second run changed the tree"
ok "$kind: a second run finds nothing and changes nothing"
echo "remove-freereac-packages $kind: ok"
