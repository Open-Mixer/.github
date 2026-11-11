#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Put the packages of a staged run on the prerelease staged-v<version> of the repository, for install-staged.
#
#   stage-release.sh <rpm|deb> <version> <dir>
#
# rpm: every binary RPM under <dir> (never a source RPM). deb: <dir>/<suite>/*.deb, named <name>_<version>_<suite>_<arch>.deb
# as the tag release names them. Every file must be <version> (a snapshot suffix .git<sha> or +git<sha> is the build's).
# The prerelease is created at GITHUB_SHA when absent (never marked latest; the RPM and DEB jobs race to create it, and
# the loser uploads), the files are uploaded over the ones of the same name, and only then the files of this kind that
# the new set does not carry (an earlier build's) are removed: the other kind's files are the other job's. A staged tag
# that names a real release is refused. Needs GH_TOKEN with contents: write, GITHUB_REPOSITORY and GITHUB_SHA.
set -euo pipefail
kind=${1:?usage: stage-release.sh <rpm|deb> <version> <dir>} version=${2:?version} dir=${3:?dir}
repo=${GITHUB_REPOSITORY:?} sha=${GITHUB_SHA:?}
out=${STAGED_OUT:-${RUNNER_TEMP:-/tmp}/staged-assets-$kind}
tag=staged-v$version
die() { echo "::error::stage-release: $*" >&2; exit 1; }
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "'$version' is not a release version"

rm -rf "$out"; mkdir -p "$out"
bad=()
case $kind in
    rpm)
        while IFS= read -r f; do
            b=$(basename "$f"); nvr=${b%.*.rpm}; nv=${nvr%-*}
            [ "${nv##*-}" = "$version" ] || { bad+=("$b"); continue; }
            cp "$f" "$out/$b"
        done < <(find "$dir" -name '*.rpm' ! -name '*.src.rpm' | sort)
        ;;
    deb)
        for f in "$dir"/*/*.deb; do
            [ -f "$f" ] || continue
            suite=$(basename "$(dirname "$f")"); b=$(basename "$f" .deb); arch=${b##*_}; nv=${b%_*}; v=${nv#*_}
            up=${v#*:}; [ "${up%-*}" = "$up" ] || up=${up%-*}; up=${up%[+~]git*}
            [ "$up" = "$version" ] || { bad+=("$b.deb"); continue; }
            cp "$f" "$out/${nv}_${suite}_${arch}.deb"
        done
        ;;
    *) die "kind is rpm or deb, not '$kind'" ;;
esac
[ "${#bad[@]}" -eq 0 ] || die "not version $version: ${bad[*]}"
mapfile -t new < <(cd "$out" && ls)
[ "${#new[@]}" -gt 0 ] || die "no $kind to stage under $dir"

names() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("true" if d.get("isPrerelease") else "false"); [print(a["name"]) for a in d.get("assets", [])]'; }
if view=$(gh release view "$tag" --repo "$repo" --json isPrerelease,assets 2>/dev/null); then
    :
elif gh release create "$tag" --repo "$repo" --prerelease --latest=false --target "$sha" \
        --title "$tag (staged, not in the channel)" \
        --notes "Packages of $repo $version built at $sha for the next layer of the release chain (install-staged). Not a release: the channel does not carry them, and the v$version tag publishes the real ones."; then
    view='{"isPrerelease": true, "assets": []}'
else
    # lost the race to the other kind's job
    view=$(gh release view "$tag" --repo "$repo" --json isPrerelease,assets) || die "could not create or read $tag"
fi
mapfile -t have < <(names <<<"$view")
[ "${have[0]}" = true ] || die "$tag of $repo exists and is not a prerelease: a staged tag never names a real release"

gh release upload "$tag" "${new[@]/#/$out/}" --clobber --repo "$repo"
for a in "${have[@]:1}"; do
    case $a in *."$kind") ;; *) continue ;; esac
    printf '%s\n' "${new[@]}" | grep -qxF -- "$a" && continue
    gh release delete-asset "$tag" "$a" --yes --repo "$repo"
done
echo "staged on $repo $tag: ${new[*]}"
