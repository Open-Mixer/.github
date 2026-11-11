#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Put the packages of a staged run on the prerelease staged-v<version> of the repository, for install-staged.
#
#   stage-release.sh <rpm|deb> <version> <dir>
#   stage-release.sh remove <version|v<version>>
#
# rpm: every binary RPM under <dir> (never a source RPM). deb: <dir>/<suite>/*.deb, named <name>_<version>_<suite>_<arch>.deb
# as the tag release names them. Every file must be <version> (a snapshot suffix .git<sha> or +git<sha> is the build's).
# The prerelease is created at GITHUB_SHA when absent (never marked latest; the RPM and DEB jobs race to create it, and
# the loser uploads), the files are uploaded over the ones of the same name, and only then the files of this kind that
# the new set does not carry (an earlier build's) are removed: the other kind's files are the other job's. A prerelease
# that was already there is an earlier commit's: its tag and its notes are then moved to GITHUB_SHA, the commit the
# files now on it were built at. A staged tag that names a real release is refused.
#
# remove: the release of v<version> deletes the prerelease staged-v<version> and its tag. Its files sort above the
# release's (0.20.3-1.git<sha>.fc44 > 0.20.3-1.fc44, 0.20.3+git<sha> > 0.20.3), so while they stay a consumer that
# still names them builds against the snapshot. No staged release is not an error (the RPM and DEB release jobs both
# remove); one that is not a prerelease, or that cannot be read, is.
#
# Needs GH_TOKEN with contents: write, GITHUB_REPOSITORY and, to stage, GITHUB_SHA.
set -euo pipefail
kind=${1:?usage: stage-release.sh <rpm|deb> <version> <dir> | remove <version>} version=${2:?version}
repo=${GITHUB_REPOSITORY:?}
die() { echo "::error::stage-release: $*" >&2; exit 1; }
[ "$kind" != remove ] || version=${version#v}
tag=staged-v$version
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "'$version' is not a release version"
names() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("true" if d.get("isPrerelease") else "false"); [print(a["name"]) for a in d.get("assets", [])]'; }

if [ "$kind" = remove ]; then
    err=$(mktemp)
    if ! view=$(gh release view "$tag" --repo "$repo" --json isPrerelease,assets 2>"$err"); then
        grep -qi 'not found' "$err" || die "$tag of $repo could not be read, so it is not known to be gone: $(tr '\n' ' ' < "$err")"
        echo "no $tag on $repo: nothing is staged for $version"; exit 0
    fi
    [ "$(names <<<"$view" | head -1)" = true ] || die "$tag of $repo is not a prerelease: a staged tag never names a real release, not removed"
    if ! gh release delete "$tag" --cleanup-tag --yes --repo "$repo" 2>"$err"; then
        # the other kind's release job removed it first
        grep -qi 'not found' "$err" || die "$tag of $repo could not be removed: $(tr '\n' ' ' < "$err")"
    fi
    echo "removed $tag from $repo: v$version is released"; exit 0
fi
dir=${3:?dir} sha=${GITHUB_SHA:?}
out=${STAGED_OUT:-${RUNNER_TEMP:-/tmp}/staged-assets-$kind}

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

notes="Packages of $repo $version built at $sha for the next layer of the release chain (install-staged). Not a release: the channel does not carry them, and the v$version tag publishes the real ones."
created=0
if view=$(gh release view "$tag" --repo "$repo" --json isPrerelease,assets 2>/dev/null); then
    :
elif gh release create "$tag" --repo "$repo" --prerelease --latest=false --target "$sha" \
        --title "$tag (staged, not in the channel)" \
        --notes "$notes"; then
    view='{"isPrerelease": true, "assets": []}'; created=1
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
# a prerelease that was there before this run says another commit: the tag and the notes follow the files
if [ "$created" = 0 ]; then
    gh api -X PATCH "repos/$repo/git/refs/tags/$tag" -f sha="$sha" -F force=true >/dev/null ||
        die "$tag of $repo holds the files built at $sha, and its tag could not be moved there"
    gh release edit "$tag" --repo "$repo" --notes "$notes" >/dev/null
fi
echo "staged on $repo $tag at $sha: ${new[*]}"
