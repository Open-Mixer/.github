#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Add RPMs to a dnf tree laid out as <tree>/fedora/<releasever>/<arch>/ (sources in SRPMS), sign the ones
# this run placed, regenerate the metadata of every directory that holds packages (with an updateinfo.xml of one
# advisory per release, made from the packages' %changelog) and sign it.
#
#   publish-tree.sh <tree> <rpm dir> [<gpg key id>]     no key id: an unsigned tree, for inspection only
#
# A package the tree already holds under the same file name is kept whatever the new build's bytes: a
# published NEVRA is immutable and a rebuild that wants in bumps its Release. The tree is shared with
# other projects, so nothing already in it is ever removed.
#
# ONLY WHAT THIS RUN PLACED IS SIGNED. The tree is pulled from the channel, and anyone who can write to the
# channel can leave a package there; signing every unsigned file would turn a channel write into a package
# signed by the release key. So a package this run did not place must already carry a good signature by a
# key the channel serves (or this run's key), checked by rpmkeys, and an unsigned or badly signed one makes
# the run refuse before anything is signed or indexed, naming the file.
#
# The environment, for the staging channel (docs/release-operations.md) and its purge:
#   REPO_FILE   the repository file served at the top of the tree, under its own name; default
#               packaging/openmixer-release/openmixer.repo (the staging tree serves packaging/staging/openmixer-staging.repo)
#   SKELETON    Fedora releases, space separated, whose fedora/<release>/ directories get metadata even with nothing in
#               them: a machine that adds the staging channel must find an index for its release, never a 404
#   EMPTY_OK    'true' lets <rpm dir> hold no package (the purge, which only regenerates the metadata)
#   MATRIX_SET  quick or full: the set this run builds, recorded for its packages in <tree>/cells.tsv; empty records none
#   NEWEST_ONLY 'true' (staging) keeps one staged build of a version: every other <version>-<release>.git... build of a
#               package this run publishes leaves its directory, so the metadata never offers the build of an earlier
#               commit beside this one. The real tree never sets it: nothing published there is ever removed.
set -euo pipefail

tree=$(readlink -m "${1:?usage: publish-tree.sh <tree> <rpm dir> [<gpg key id>]}")
src=${2:?usage: publish-tree.sh <tree> <rpm dir> [<gpg key id>]}
key=${3:-}

signed() {
    local sigs
    sigs=$(rpm -qp --qf '%{SIGPGP:pgpsig}|%{SIGGPG:pgpsig}|%{RSAHEADER:pgpsig}|%{DSAHEADER:pgpsig}' "$1" 2>/dev/null) || return 1
    sigs=$(printf '%s' "$sigs" | sed -e 's/(none)//g' -e 's/|//g' -e 's/[[:space:]]//g')
    [ -n "$sigs" ]
}

here=$(dirname "$(readlink -f "$0")")
repo_file=${REPO_FILE:-$here/../../../packaging/openmixer-release/openmixer.repo}
[ -f "$repo_file" ] || { echo "no repository file $repo_file" >&2; exit 1; }

mapfile -t found < <(find "$src" -name '*.rpm' | sort)
[ "${#found[@]}" -gt 0 ] || [ "${EMPTY_OK:-}" = true ] || { echo "no rpm under $src" >&2; exit 1; }
mkdir -p "$tree"
for rel in ${SKELETON:-}; do
    [[ $rel =~ ^[0-9]+$ ]] || { echo "SKELETON names '$rel', not a Fedora release" >&2; exit 1; }
    mkdir -p "$tree/fedora/$rel"
done

declare -A dirs=()
placed=()
for f in ${found[@]+"${found[@]}"}; do
    IFS='|' read -r is_src arch rel pkg ver < <(rpm -qp --qf '%{SOURCEPACKAGE}|%{ARCH}|%{RELEASE}|%{NAME}|%{VERSION}\n' "$f")
    [ "$is_src" = 1 ] && archdir=SRPMS || archdir=$arch
    releasever=$(printf '%s\n' "$rel" | sed -n 's/.*\.fc\([0-9][0-9]*\).*/\1/p')
    [ -n "$releasever" ] || { echo "$f has no .fcNN dist tag" >&2; exit 1; }
    dest=$tree/fedora/$releasever/$archdir
    mkdir -p "$dest"
    dirs[$dest]=1
    if [ -f "$dest/$(basename "$f")" ]; then
        echo "kept   $(basename "$f") (already published; a changed build needs a new Release)"
    else
        install -m 0644 "$f" "$dest/"
        placed+=("$dest/$(basename "$f")")
        echo "placed $(basename "$f") in fedora/$releasever/$archdir"
    fi
    [ "${NEWEST_ONLY:-}" = true ] || continue
    case $rel in *.git*) ;; *) continue ;; esac
    for old in "$dest/$pkg-$ver-"*.git*.rpm; do
        [ -f "$old" ] && [ "$(basename "$old")" != "$(basename "$f")" ] || continue
        # omx-lib-3.14.0-* is also how a package named omx-lib-3.14.0 would start: ask the file
        [ "$(rpm -qp --qf '%{NAME}|%{VERSION}' "$old")" = "$pkg|$ver" ] || continue
        rm -f "$old"
        echo "dropped $(basename "$old") from fedora/$releasever/$archdir (an earlier staged build of $ver)"
    done
done

# A private rpm keystore holding the keys the channel serves, the keys committed here and this run's key: what a package already in the
# tree must verify against. rpmkeys takes one key per file, so the union is split by fingerprint first.
trusted_keystore() {
    local root=$1 home fpr
    home=$(mktemp -d)
    { "$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh" emit "$tree/RPM-GPG-KEY-openmixer"; gpg --batch --armor --export "$key"; } |
        GNUPGHOME=$home gpg --batch --quiet --import 2>/dev/null
    while IFS= read -r fpr; do
        GNUPGHOME=$home gpg --batch --armor --export "$fpr" > "$home/k.asc"
        rpmkeys --root "$root" --import "$home/k.asc"
    done < <(GNUPGHOME=$home gpg --batch --with-colons --fingerprint | awk -F: '/^pub:/ {p = 1; next} /^fpr:/ && p {print $10; p = 0}')
    rm -rf "$home"
}

if [ -n "$key" ]; then
    declare -A mine=()
    for f in ${placed[@]+"${placed[@]}"}; do mine[$f]=1; done
    # the key file is the channel's to write: it is read only if every primary in it, and the key this run signs
    # with, is on the list committed in this repository (channel-keys.sh)
    "$(dirname "$(readlink -f "$0")")/../import-gpg-key/channel-keys.sh" pinned "$tree/RPM-GPG-KEY-openmixer" "$key" ||
        { echo "the channel's key file is not one this repository pins: nothing was signed" >&2; exit 1; }
    keystore=$(mktemp -d)
    trusted_keystore "$keystore"
    refused=0
    while IFS= read -r f; do
        [ -z "${mine[$f]:-}" ] || continue
        out=$(rpmkeys --root "$keystore" --checksig "$f" 2>&1) || true
        case $out in
            *": digests signatures OK") ;;
            *) echo "refused ${f#"$tree"/}: in the channel, not placed by this run, and not signed by a served key ($out)" >&2; refused=1 ;;
        esac
    done < <(find "$tree" -name '*.rpm' | sort)
    [ "$refused" = 0 ] || { rm -rf "$keystore"; echo "the channel holds packages this run did not place and cannot vouch for: nothing was signed" >&2; exit 1; }
    for f in ${placed[@]+"${placed[@]}"}; do
        signed "$f" || rpmsign --define "_gpg_name $key" --addsign "$f" >/dev/null
        out=$(rpmkeys --root "$keystore" --checksig "$f" 2>&1) || true
        case $out in *": digests signatures OK") ;; *) echo "not verified after rpmsign: $f ($out)" >&2; exit 1 ;; esac
    done
    rm -rf "$keystore"
fi

# openmixer.repo asks for fedora/<release>/$basearch/ and fedora/<release>/noarch/: every release the tree holds gets all
# its arch directories, with metadata even when empty, or dnf stops on a 404 for the one nothing was published into
for rel in "$tree"/fedora/*/; do
    [ -d "$rel" ] || continue
    for arch in noarch x86_64 aarch64 SRPMS; do
        mkdir -p "$rel$arch"
        dirs[${rel}$arch]=1
    done
done
# every directory that holds packages, not only the ones this run placed into: the metadata of the
# pulled tree was discarded, and a directory another project filled would be left bare
while IFS= read -r d; do dirs[$d]=1; done < <(find "$tree" -name '*.rpm' -printf '%h\n' | sort -u)
for dest in "${!dirs[@]}"; do
    if [ -d "$dest/repodata" ]; then createrepo_c --update --quiet "$dest"; else createrepo_c --quiet "$dest"; fi
    # the advisories of the releases this directory holds, from the packages' own changelogs, so that
    # `dnf updateinfo` and `dnf check-update --changelogs` tell a user what an update brings
    if find "$dest" -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm' -print -quit | grep -q .; then
        # createrepo_c --update keeps the record of the last publish: drop it, the new one replaces it
        if grep -q 'type="updateinfo"' "$dest/repodata/repomd.xml"; then
            modifyrepo_c --remove updateinfo "$dest/repodata" >/dev/null
        fi
        updateinfo=$(mktemp -d)
        "$(dirname "$(readlink -f "$0")")/updateinfo.py" "$dest" "$updateinfo/updateinfo.xml"
        modifyrepo_c --mdtype=updateinfo "$updateinfo/updateinfo.xml" "$dest/repodata" >/dev/null
        rm -rf "$updateinfo"
    fi
    rm -f "$dest/repodata/repomd.xml.asc"
    if [ -n "$key" ]; then
        gpg --batch --yes --armor --detach-sign --local-user "$key" \
            --output "$dest/repodata/repomd.xml.asc" "$dest/repodata/repomd.xml"
    fi
    echo "repodata ${dest#"$tree"/}"
done

# the key file is what the channel served plus the signing key, never the signing key alone (channel-keys.sh);
# openmixer.repo is the file openmixer-release installs, the same bytes (REPO_FILE: openmixer-staging.repo for staging)
if [ -n "$key" ]; then
    "$here/../import-gpg-key/channel-keys.sh" serve "$tree/RPM-GPG-KEY-openmixer" "$key"
    install -m 0644 "$repo_file" "$tree/$(basename "$repo_file")"
fi

# which cells every package and version of the tree has, and the set (quick or full) this run published: the channel
# page and a final release's dependency check read it (release-matrix/cells.sh)
"$here/../release-matrix/cells.sh" rpm "$tree" "$src"
