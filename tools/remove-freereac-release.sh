#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Take FreeREAC's freereac-release out of the OpenMixer channel, and nothing else. The mirror (mirror-freereac-release,
# removed by .github#224) published it into this channel, signed with this channel's key, while openmixer-release 1-7 to
# 1-9 required it; the OpenMixer and FreeREAC channels are independent (owner ruling 2026-11-23) and this channel serves
# none of FreeREAC's release packages.
#
#   remove-freereac-release.sh rpm|deb <channel checkout> [<gpg key id>]     no key id: unsigned metadata, a dry run
#
# THE ONE PACKAGE IS A CONSTANT, NOT AN ARGUMENT. Every file removed is found under <channel>/<kind> by name and is
# freereac-release by its own header (rpm -qp NAME, dpkg-deb Package), else the run refuses before removing anything;
# with deb its changelog directory, changelogs/f/freereac-release, goes too. The metadata is then made again and signed
# by the tree scripts of a publish (publish-rpms or publish-debs publish-tree.sh, EMPTY_OK: nothing is added), with
# every guard of a publish: each package left in the tree must already carry this channel's signature (rpm) or be in
# its suite's signed index (deb).
#
# THE CHANGE IS AUDITED AGAINST GIT. <channel> is a git checkout (channel-pull's build/channel). Afterwards every path
# that changed must be inside <kind>/, and either a removed freereac-release file or metadata the tree scripts write
# (repodata/, Packages, Packages.gz, Release, InRelease, Release.gpg, cells.tsv, the key file, openmixer.repo, and with deb
# a NEW changelog file publish-debs writes for a served package that lacked one, as any publish does); anything else
# refuses the run, naming the path. A tree that serves no freereac-release is left exactly as it is (exit 0):
# a re-run, or the rebuild after a lost race on a tip that already lost it, changes nothing.
#
# CHANGELOGS_URL (deb) is the Changelogs field of the Release files, as publish-debs sets it; default
# https://www.openmixer.org/deb/changelogs.
set -euo pipefail
usage='usage: remove-freereac-release.sh rpm|deb <channel checkout> [<gpg key id>]'
pkg=freereac-release
kind=${1:?$usage}
channel=$(readlink -m "${2:?$usage}")
key=${3:-}
here=$(dirname "$(readlink -f "$0")")
actions=$here/../.github/actions
fail() { echo "FAIL: $*" >&2; exit 1; }
case $kind in rpm | deb) ;; *) fail "rpm or deb, not '$kind'" ;; esac
[ -d "$channel/$kind" ] || fail "no $kind tree at $channel/$kind"
git -C "$channel" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$channel is not a git checkout: the change could not be audited"
[ -z "$(git -C "$channel" status --porcelain --untracked-files=all)" ] || fail "$channel has changes before the removal: $(git -C "$channel" status --short | head -5)"
tree=$channel/$kind

# what goes: found by name, proved by header
gone=()
case $kind in
rpm)
    while IFS= read -r f; do
        name=$(rpm -qp --nosignature --qf '%{NAME}' "$f" 2>/dev/null) || fail "${f#"$channel"/} is not a readable rpm"
        [ "$name" = "$pkg" ] || fail "${f#"$channel"/} is named like $pkg but is the package '$name': nothing was removed"
        gone+=("$f")
    done < <(find "$tree" -type f -name "$pkg-*.rpm" | sort)
    ;;
deb)
    while IFS= read -r f; do
        name=$(dpkg-deb -f "$f" Package 2>/dev/null) || fail "${f#"$channel"/} is not a readable deb"
        [ "$name" = "$pkg" ] || fail "${f#"$channel"/} is named like $pkg but is the package '$name': nothing was removed"
        gone+=("$f")
    done < <(find "$tree" -type f \( -name "${pkg}_*.deb" -o -name "$pkg.deb" \) | sort)
    ;;
esac
cl=$tree/changelogs/${pkg:0:1}/$pkg
if [ "${#gone[@]}" = 0 ] && { [ "$kind" = rpm ] || [ ! -e "$cl" ]; }; then
    echo "the $kind tree serves no $pkg: nothing to remove, the tree is left as it is"
    exit 0
fi

for f in ${gone[@]+"${gone[@]}"}; do rm -f -- "$f"; echo "removed ${f#"$channel"/}"; done
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
case $kind in
rpm)
    # the metadata is made from the bytes the tree holds, as channel-pull leaves it for a publish (strip: rpm)
    find "$tree" -type d -name repodata -prune -exec rm -rf {} +
    EMPTY_OK=true "$actions/publish-rpms/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    left=$(find "$tree" -type f -name "$pkg-*.rpm")
    ;;
deb)
    [ ! -e "$cl" ] || { rm -rf -- "$cl"; echo "removed ${cl#"$channel"/}"; }
    CHANGELOGS_URL=${CHANGELOGS_URL-https://www.openmixer.org/deb/changelogs} EMPTY_OK=true \
        "$actions/publish-debs/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    left=$(find "$tree" \( -name "${pkg}_*.deb" -o -name "$pkg.deb" -o -path "$cl" \))
    if grep -rlx "Package: $pkg" --include=Packages "$tree/debian" >/dev/null 2>&1; then left+=" an index entry"; fi
    ;;
esac
[ -z "$left" ] || fail "the $kind tree still serves $pkg: $left"

# the audit: only freereac-release left, only metadata changed
declare -A removed=()
for f in ${gone[@]+"${gone[@]}"}; do removed[${f#"$channel"/}]=1; done
bad=0
while IFS= read -r -d '' entry; do
    st=${entry:0:2} path=${entry:3}
    case $path in
    "$kind"/*) ;;
    *) echo "refused: $path changed, outside $kind/" >&2; bad=1; continue ;;
    esac
    # a removed file is one of the packages proved above, its changelog, or metadata the tree scripts make again
    if [ "$st" = ' D' ]; then
        [ -z "${removed[$path]:-}" ] || continue
        case $path in "deb/changelogs/${pkg:0:1}/$pkg/"*) continue ;; esac
    fi
    case ${path#"$kind"/} in
    repodata/* | */repodata/* | */Packages | */Packages.gz | */Release | */InRelease | */Release.gpg | cells.tsv | \
        RPM-GPG-KEY-openmixer | openmixer.asc | openmixer.repo) ;;
    # publish-debs writes the changelog of a served package that has none yet; a publish adds it, never rewrites one
    changelogs/*_changelog) [ "$kind" = deb ] && [ "$st" = '??' ] || { echo "refused: $path changed ($st): a served changelog is never rewritten" >&2; bad=1; } ;;
    *) echo "refused: $path changed ($st), and it is neither $pkg nor metadata" >&2; bad=1 ;;
    esac
done < <(git -C "$channel" status --porcelain=v1 -z --untracked-files=all)
[ "$bad" = 0 ] || fail "the removal changed more than $pkg and its metadata: nothing may be pushed"
echo "removed $pkg from $kind/: ${#gone[@]} package(s), metadata regenerated${key:+ and signed}"
