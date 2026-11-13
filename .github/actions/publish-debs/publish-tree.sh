#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Add DEBs to an apt tree of flat repositories laid out as <tree>/debian/<suite>/<arch>/, regenerate the
# index of every suite and sign it.
#
#   publish-tree.sh <tree> <deb dir> [<gpg key id>]     no key id: an unsigned tree, for inspection only
#
# <deb dir> holds <suite>/<package>.deb, the suite being the Debian release the package was built on. A
# package the tree already holds under the same file name is kept whatever the new build's bytes: a
# published version is immutable and a rebuild that wants in bumps its version. The tree is shared with
# other projects, so nothing already in it is ever removed. REQUIRES names packages that must be in the tree
# for every suite and architecture this run places a package into, so a package is never published without
# a dependency of it that no repository serves.
#
# COSIGN names a second key that also signs Release.gpg and InRelease (apt verifies with any key of the
# signed-by file, and one good signature from it is enough). It carries a key change: apt users hold the
# key file they saved at install time, so while it holds only the old key the index keeps a signature by
# that key. Only the apt index is co-signed; packages and the dnf metadata carry the signing key alone.
#
# THE SIGNED INDEX VOUCHES ONLY FOR WHAT IS ALREADY VOUCHED FOR. A .deb carries no signature of its own: the
# signed Release covers every package through Packages. The tree is pulled from the channel, and anyone who
# can write to the channel can leave a .deb there, so before any index is regenerated every package this run
# did not place must be listed, with the same SHA256, in its suite's previous Packages, whose InRelease
# verifies against the keys the channel serves or this run signs with. Anything else makes the run refuse
# before anything is signed, naming the file.
#
# The environment, for the staging channel (docs/release-operations.md) and its purge:
#   LABEL           the Origin and Label of every Release file; default OpenMixer (staging: OpenMixer-Staging, which
#                   the staging pin names)
#   REQUIRES_TREE   another apt tree a REQUIRES package may be served from: the real deb/ tree, for a staging publish
#                   whose packages depend on what only the real channel carries
#   SKELETON        Debian releases, space separated, that get an index even with nothing in them (with
#                   SKELETON_ARCHES, default "amd64 arm64"): a machine that adds the staging channel must find an
#                   index for its release, never a 404
#   EMPTY_OK        'true' lets <deb dir> hold no package (the purge, which only regenerates the indexes)
#   MATRIX_SET      quick or full: the set this run builds, recorded for its packages in <tree>/cells.tsv; empty
#                   records none
#   NEWEST_ONLY     'true' (staging) keeps one staged build of a version: every other <version>+git... build of a package
#                   this run publishes leaves its directory, so the index never offers the build of an earlier commit
#                   beside this one. The real tree never sets it: nothing published there is ever removed.
set -euo pipefail

tree=$(readlink -m "${1:?usage: publish-tree.sh <tree> <deb dir> [<gpg key id>]}")
src=${2:?usage: publish-tree.sh <tree> <deb dir> [<gpg key id>]}
key=${3:-}
requires=${REQUIRES:-}
cosign=${COSIGN:-}
# CHANGELOGS_URL is where the tree's changelogs/ directory is served; empty leaves the Release file without a Changelogs field
changelogs=${CHANGELOGS_URL:+${CHANGELOGS_URL%/}/@CHANGEPATH@_changelog}
[ -z "$cosign" ] || [ -n "$key" ] || { echo "COSIGN needs a signing key" >&2; exit 1; }
signers=()
for k in $key $cosign; do signers+=(--local-user "$k"); done

# apt changelog for a version that is not installed yet asks the Changelogs: URL of the Release file for
# <source>_<version>_changelog under CHANGEPATH (prefix/source (a flat repository has no component)). The text is the package's own
# changelog, the one the .deb carries for apt-listchanges and for the installed version. A file already
# there is kept: a published version's changelog does not change.
place_changelog() {
    local deb=$1 pkg ver srcfield source srcver prefix dir member
    pkg=$(dpkg-deb -f "$deb" Package)
    ver=$(dpkg-deb -f "$deb" Version)
    srcfield=$(dpkg-deb -f "$deb" Source 2>/dev/null || true)
    source=${srcfield%% *}
    source=${source:-$pkg}
    case $srcfield in *"("*")"*) srcver=${srcfield#*(}; srcver=${srcver%)*} ;; *) srcver=$ver ;; esac
    srcver=${srcver#*:}
    case $source in lib*) prefix=${source:0:4} ;; *) prefix=${source:0:1} ;; esac
    dir=$tree/changelogs/$prefix/$source
    [ ! -f "$dir/${source}_${srcver}_changelog" ] || return 0
    member=$(dpkg-deb --fsys-tarfile "$deb" | tar -t | sed 's|^\./||' |
        grep -xE "usr/share/doc/$pkg/changelog(\.Debian)?\.gz" | sort | head -1 || true)
    # a package whose doc directory links to another package's carries no changelog of its own
    [ -n "$member" ] || return 0
    mkdir -p "$dir"
    dpkg-deb --fsys-tarfile "$deb" | tar -xO "./$member" | gzip -dc > "$dir/${source}_${srcver}_changelog"
    echo "changelog $source $srcver"
}

label=${LABEL:-OpenMixer}
[[ $label =~ ^[A-Za-z0-9.+-]+$ ]] || { echo "LABEL '$label' is not one word an apt pin can name" >&2; exit 1; }

mapfile -t found < <(find "$src" -name '*.deb' | sort)
[ "${#found[@]}" -gt 0 ] || [ "${EMPTY_OK:-}" = true ] || { echo "no deb under $src" >&2; exit 1; }
mkdir -p "$tree/debian"
for suite in ${SKELETON:-}; do
    [[ $suite =~ ^[a-z]+$ ]] || { echo "SKELETON names '$suite', not a Debian release" >&2; exit 1; }
    for arch in ${SKELETON_ARCHES:-amd64 arm64}; do mkdir -p "$tree/debian/$suite/$arch"; done
done

declare -A cells=()
declare -A mine=()
for f in ${found[@]+"${found[@]}"}; do
    [ "$(dirname "$(dirname "$f")")" = "${src%/}" ] || { echo "$f is not laid out <suite>/<package>.deb under $src" >&2; exit 1; }
    suite=$(basename "$(dirname "$f")")
    arch=$(dpkg-deb -f "$f" Architecture)
    dest=$tree/debian/$suite/$arch
    mkdir -p "$dest"
    cells[$suite/$arch]=1
    if [ -f "$dest/$(basename "$f")" ]; then
        echo "kept   $(basename "$f") (already published; a changed build needs a new version)"
    else
        install -m 0644 "$f" "$dest/"
        mine[$dest/$(basename "$f")]=1
        echo "placed $(basename "$f") in debian/$suite/$arch"
    fi
    [ "${NEWEST_ONLY:-}" = true ] || continue
    pkg=$(dpkg-deb -f "$f" Package)
    ver=$(dpkg-deb -f "$f" Version)
    case $ver in *+git*) ;; *) continue ;; esac
    for old in "$dest/${pkg}_${ver%%+git*}+git"*.deb; do
        [ -f "$old" ] && [ "$(basename "$old")" != "$(basename "$f")" ] || continue
        rm -f "$old"
        echo "dropped $(basename "$old") from debian/$suite/$arch (an earlier staged build of ${ver%%+git*})"
    done
done

# The previous index of <suite dir>, as "<sha256> ./<arch>/<file>" lines, when its InRelease carries a good
# signature by a key of <keyring> and the Packages beside it is the one that InRelease names. Nothing otherwise.
vouched() {
    local dir=$1 keyring=$2 release want got
    [ -f "$dir/InRelease" ] && [ -f "$dir/Packages" ] || return 0
    release=$(mktemp)
    # gpgv exits non-zero when one of the signatures is by a key it lacks (a co-signed index): read its status
    { gpgv --status-fd 3 --keyring "$keyring" --output "$release" "$dir/InRelease" 3>&1 1>/dev/null 2>/dev/null || true; } |
        awk '/BADSIG/ {b = 1} /VALIDSIG/ {g = 1} END {exit !(g && !b)}' || { rm -f "$release"; return 0; }
    want=$(awk '/^SHA256:/ {s = 1; next} /^[^ ]/ {s = 0} s && $3 == "Packages" {print $1}' "$release")
    rm -f "$release"
    got=$(sha256sum < "$dir/Packages" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$got" ] || return 0
    awk '/^Filename:/ {f = $2} /^SHA256:/ {h = $2} /^$/ {if (f != "" && h != "") print h, f; f = ""; h = ""}
        END {if (f != "" && h != "") print h, f}' "$dir/Packages"
}

if [ -n "$key" ]; then
    # vouched() reads the previous index with gpgv; without it every package of the channel would look unvouched
    command -v gpgv >/dev/null || { echo "gpgv is not installed: the channel's signed index cannot be read, so nothing can be vouched for and nothing was signed" >&2; exit 1; }
    # the key file is the channel's to write: it is read only if every primary in it, and every key this run signs
    # with, is on the list committed in this repository (channel-keys.sh)
    # shellcheck disable=SC2086 # cosign is one key id or empty
    "$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh" pinned "$tree/openmixer.asc" $key $cosign ||
        { echo "the channel's key file is not one this repository pins: nothing was signed" >&2; exit 1; }
    keyring=$(mktemp)
    # shellcheck disable=SC2086 # cosign is one key id or empty
    { "$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh" emit "$tree/openmixer.asc"; gpg --batch --armor --export $key $cosign; } |
        gpg --batch --yes --dearmor > "$keyring"
    refused=0
    for suitedir in "$tree"/debian/*/; do
        [ -d "$suitedir" ] || continue
        index=$(vouched "${suitedir%/}" "$keyring")
        while IFS= read -r f; do
            [ -z "${mine[$f]:-}" ] || continue
            rel=./${f#"${suitedir}"}
            if ! grep -qxF "$(sha256sum < "$f" | cut -d' ' -f1) $rel" <<< "$index"; then
                echo "refused ${f#"$tree"/}: in the channel, not placed by this run, and not in its suite's signed index" >&2
                refused=1
            fi
        done < <(find "$suitedir" -name '*.deb' | sort)
    done
    rm -f "$keyring"
    [ "$refused" = 0 ] || { echo "the channel holds packages this run did not place and cannot vouch for: nothing was signed" >&2; exit 1; }
fi

# every package of the tree, so a release published before the Changelogs field existed gets its file too
while IFS= read -r f; do place_changelog "$f"; done < <(find "$tree/debian" -name '*.deb' | sort)

for cell in "${!cells[@]}"; do
    # an Architecture: all package installs beside the arch cells, which hold the required libraries
    [ "${cell##*/}" = all ] && continue
    for pkg in $requires; do
        compgen -G "$tree/debian/$cell/${pkg}_*.deb" >/dev/null ||
            { [ -n "${REQUIRES_TREE:-}" ] && compgen -G "$REQUIRES_TREE/debian/$cell/${pkg}_*.deb" >/dev/null; } ||
            { echo "debian/$cell holds no $pkg: publish it first (workflow mod-host-protocol-deb of Open-Mixer/.github)" >&2; exit 1; }
    done
done

for suitedir in "$tree"/debian/*/; do
    suite=$(basename "$suitedir")
    (
        cd "$suitedir"
        rm -f Packages Packages.gz Release InRelease Release.gpg
        archs=$(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')
        apt-ftparchive packages . > Packages
        gzip -9nk Packages
        release=$(mktemp)
        apt-ftparchive \
            -o APT::FTPArchive::Release::Origin="$label" -o APT::FTPArchive::Release::Label="$label" \
            -o APT::FTPArchive::Release::Suite="$suite" -o APT::FTPArchive::Release::Codename="$suite" \
            -o APT::FTPArchive::Release::Architectures="${archs% }" \
            release . > "$release"
        # where apt changelog finds the changelog of a version it has not installed (place_changelog)
        if [ -n "$changelogs" ]; then
            sed -i "/^Architectures:/a Changelogs: $changelogs" "$release"
        fi
        cat "$release" > Release
        rm -f "$release"
        if [ -n "$key" ]; then
            gpg --batch --yes --armor --detach-sign "${signers[@]}" --output Release.gpg Release
            gpg --batch --yes --clearsign "${signers[@]}" --output InRelease Release
        fi
    )
    echo "index debian/$suite"
done

# the key file is what the channel served plus every key that signed the index (channel-keys.sh)
if [ -n "$key" ]; then
    # shellcheck disable=SC2086 # cosign is one key id or empty
    "$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh" serve "$tree/openmixer.asc" "$key" $cosign
fi

# which cells every package and version of the tree has, and the set (quick or full) this run published: the channel
# page and a final release's dependency check read it (release-matrix/cells.sh)
"$(dirname "$(readlink -f "$0")")/../release-matrix/cells.sh" deb "$tree" "$src"
