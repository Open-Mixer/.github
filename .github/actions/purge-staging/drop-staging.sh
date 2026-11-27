#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Take named package versions out of the staging channel and leave everything else in it as it was: the selective form
# of purge-staging.sh. Only <channel>/staging/<kind> is written; the real trees, <channel>/rpm and <channel>/deb, are
# never read for writing.
#
#   drop-staging.sh check <channel> <drop>              every entry matches a file of staging/rpm or staging/deb, or
#                                                       each one that does not is named and the run fails; writes nothing
#   drop-staging.sh rpm|deb <channel> <drop> [<key>]    removes the matching files of staging/<kind>, printing each path,
#                                                       and makes again (signed, with a key) only the metadata of what it
#                                                       removed from, with the publish's own tree scripts
#
# <drop> is name@version[,name@version...] (commas or white space between entries): the package name a file carries and
# its upstream version, the two columns of cells.tsv (an rpm's Release, a deb's epoch, revision and +git / ~git suffix
# are not part of it). An entry takes every file that is exactly that package at that version, in every
# fedora/<release>/<arch> directory (noarch and SRPMS included) or every debian/<suite>/<arch> directory, and nothing
# else: the name and the version are compared whole, never as a prefix or a pattern, and the file's own header must say
# the same as its name, or the run refuses it by name before anything is removed.
#
# A kind none of the entries matches is left untouched (nothing removed, no metadata made again). The rpm directories
# (fedora/<release>/<arch>) and Debian releases (debian/<suite>) a file left get their metadata made again from what they
# still hold (publish-tree.sh REINDEX); every other directory keeps its metadata and its signature byte for byte, so the
# tree must be pulled with its metadata (channel-pull strip: none). cells.tsv is written again by the tree script.
set -euo pipefail
usage='usage: drop-staging.sh check|rpm|deb <channel> <name@version[,...]> [<gpg key id>]'
mode=${1:?$usage}
channel=$(readlink -m "${2:?$usage}")
spec=${3:?$usage}
key=${4:-}
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=SCRIPTDIR/../release-matrix/name-version.sh
. "$here/../release-matrix/name-version.sh"
case $mode in check | rpm | deb) ;; *) echo "drop-staging.sh: check, rpm or deb, not '$mode'" >&2; exit 2 ;; esac
[ -d "$channel" ] || { echo "no channel at $channel" >&2; exit 1; }

# the entries, each one name@version: a name or a version of another shape (a pattern among them) stops the run
declare -A want=()
entries=()
bad=0
# split on commas and white space, never glob-expanded: an entry is compared as written
IFS=$', \t\n' read -r -d '' -a raw <<< "$spec" || true
for e in ${raw[@]+"${raw[@]}"}; do
    n=${e%@*} v=${e##*@}
    if [[ $e != *@* || $n == *@* || ! $n =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ || ! $v =~ ^[A-Za-z0-9][A-Za-z0-9.+~_]*$ ]]; then
        echo "refused '$e': not name@version (a package name and its upstream version, no pattern)" >&2
        bad=1
        continue
    fi
    [ -n "${want[$n $v]:-}" ] || entries+=("$n $v")
    want[$n $v]=1
done
[ "$bad" = 0 ] || { echo "the drop list is malformed: nothing was removed" >&2; exit 1; }
[ "${#entries[@]}" -gt 0 ] || { echo "the drop list names no package" >&2; exit 1; }

# matches <kind>: the files of staging/<kind> whose name is a package and version of the list, "<name> <version>\t<path>"
matches() {
    local k=$1 top nv f
    case $k in rpm) top=fedora ;; deb) top=debian ;; esac
    [ -d "$channel/staging/$k/$top" ] || return 0
    while IFS= read -r f; do
        nv=$(file_name_version "$k" "$f")
        [ -n "$nv" ] && [ -n "${want[$nv]:-}" ] || continue
        printf '%s\t%s\n' "$nv" "$f"
    done < <(find "$channel/staging/$k/$top" -mindepth 3 -maxdepth 3 -type f -name "*.$k" | LC_ALL=C sort)
}

if [ "$mode" = check ]; then
    found=$( { matches rpm; matches deb; } | cut -f1 | LC_ALL=C sort | uniq -c)
    missing=0
    for nv in "${entries[@]}"; do
        c=$(awk -v n="${nv% *}" -v v="${nv#* }" '$2 == n && $3 == v {print $1}' <<< "$found")
        if [ -z "$c" ]; then
            echo "refused ${nv% *}@${nv#* }: no file of staging/rpm or staging/deb is that package at that version" >&2
            missing=1
        else
            echo "${nv% *}@${nv#* }: $c file(s)"
        fi
    done
    [ "$missing" = 0 ] || { echo "the drop names versions staging does not hold: nothing was removed" >&2; exit 1; }
    exit 0
fi

kind=$mode
tree=$channel/staging/$kind
mapfile -t hits < <(matches "$kind" | cut -f2)
if [ "${#hits[@]}" = 0 ]; then
    echo "nothing of the drop is in staging/$kind: nothing was removed, no metadata made again"
    exit 0
fi
# the header of every file must name the package and version its file name does: a file named one way and built
# another is refused, and nothing is removed
refused=0
for f in "${hits[@]}"; do
    if [ "$kind" = rpm ]; then
        head=$(rpm -qp --qf '%{NAME} %{VERSION}' "$f" 2>/dev/null) || head=
    else
        head="$(dpkg-deb -f "$f" Package 2>/dev/null) $(dpkg-deb -f "$f" Version 2>/dev/null)" || head=
        v=${head#* } v=${v#*:} v=${v%%[+~]git*} v=${v%-*}
        head="${head%% *} $v"
    fi
    [ "$head" = "$(file_name_version "$kind" "$f")" ] && continue
    echo "refused ${f#"$channel"/}: its header says '$head', not what its name says" >&2
    refused=1
done
[ "$refused" = 0 ] || { echo "a file to drop is not what its name says: nothing was removed" >&2; exit 1; }

declare -A dirs=()
for f in "${hits[@]}"; do
    rm -f "$f"
    echo "removed ${f#"$channel"/}"
    d=${f%/*} d=${d#"$tree"/}
    [ "$kind" = rpm ] || d=${d%/*}
    dirs[$d]=1
done
reindex=$(printf '%s\n' "${!dirs[@]}" | LC_ALL=C sort | tr '\n' ' ')
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
case $kind in
rpm)
    REINDEX=$reindex REPO_FILE=$here/../../../packaging/staging/openmixer-staging.repo EMPTY_OK=true \
        "$here/../publish-rpms/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
deb)
    # the index keeps the Changelogs field it had: the staging tree's changelogs stay where they are served
    first=${reindex%% *}
    url=$(sed -n 's|^Changelogs: \(.*\)/@CHANGEPATH@_changelog$|\1|p' "$tree/$first/Release" 2>/dev/null | head -1)
    REINDEX=$reindex CHANGELOGS_URL=$url LABEL=OpenMixer-Staging EMPTY_OK=true \
        "$here/../publish-debs/publish-tree.sh" "$tree" "$empty" ${key:+"$key"}
    ;;
esac
echo "dropped from staging/$kind: ${#hits[@]} file(s); metadata made again for $reindex"
