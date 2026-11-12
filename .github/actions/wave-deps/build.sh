#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Build the packages of a wave's siblings from their wave branch into a local repository, and add that repository to
# this system, so what the caller then builds and installs (dnf builddep, apt-get build-dep, dnf/apt install) takes the
# siblings' fresh builds and not the channel's releases.
#
#   build.sh <prefix> <branch> <owner> <repo>...     build each repo (in this order) unless <prefix> holds them already
#   build.sh --tools                                 install what the builds and the cache need (git, rpm-build or
#                                                    dpkg-dev, tar, zstd, python3 for the changelog, ...)
#   build.sh --bump <tree>                           the version bump alone, on a checkout (the self-test's entry)
#
# <prefix> holds rpm/ (a dnf repository) or deb/ (a flat apt repository) and a stamp naming what built it. Each sibling
# is cloned from https://github.com/<owner>/<repo> at <branch>, given the version the wave releases it as (below), built
# with the build-rpm or build-deb script of this checkout of Open-Mixer/.github with its tests skipped (its own CI runs
# them) and put in the repository before the next one builds, so a sibling builds on the ones listed before it.
#
# The version: a wave branch holds the next release's code at the last release's version, and the repositories that
# build on it already require the next one (omx-plugins on omx-contract >= 3.9.0 while omx-contract's dedupe/all still
# says 3.8.0). One wave releases one minor per repository, so a sibling whose version is its last v<version> tag's and
# whose branch is ahead of that tag is built as the next minor, <major>.<minor+1>.0; one already moved past its tag
# keeps its own. The version is rewritten where these repositories write it (the spec, debian/changelog, VERSION, the
# top-level "version" of a tracked JSON file, a Makefile's VERSION, a C header's *_VERSION_MAJOR/MINOR/PATCH) and
# committed in the clone alone; nothing is pushed. A DEB snapshot is <version>+git<commit time>.<sha> (sorts above <version>),
# an RPM one <version>-<release>.git<commit time>.<sha>.
#
# The local repository is preferred over the channel: dnf priority=1, an apt pin of 600 on the local origin.
# Runs as root in a Fedora or Debian container.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
actions=$(dirname "$here")

# the version the wave releases the tree as, written where the tree writes it and committed; prints it
bump() {
    local tree=$1 spec old tag tagv new ma mi pa f
    spec=$(ls "$tree"/packaging/*.spec 2>/dev/null | head -1)
    if [ -n "$spec" ]; then
        old=$(sed -n 's/^Version:[[:space:]]*//p' "$spec" | head -1)
    else
        old=$(sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$tree/debian/changelog")
    fi
    [ -n "$old" ] || { echo "wave-deps: $tree names no version" >&2; return 1; }
    tag=$(git -C "$tree" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
    tagv=${tag#v}
    if [ -z "$tag" ] || [ "$old" != "$tagv" ] || [ "$(git -C "$tree" rev-list --count "$tag..HEAD")" = 0 ]; then
        echo "$old"
        return 0
    fi
    IFS=. read -r ma mi pa <<<"$old"
    new=$ma.$((mi + 1)).0
    local e_old=${old//./\\.}
    (
        cd "$tree" || exit 1
        [ -z "$spec" ] || sed -i "s/^\(Version:[[:space:]]*\)$e_old\$/\1$new/" packaging/*.spec
        [ ! -f debian/changelog ] || sed -i "1s/ ($e_old)/ ($new)/" debian/changelog
        [ ! -f VERSION ] || [ "$(tr -d '[:space:]' < VERSION)" != "$old" ] || echo "$new" > VERSION
        git ls-files -z '*.json' | while IFS= read -r -d '' f; do
            sed -i "s/^\(  \"version\": \"\)$e_old\"/\1$new\"/" "$f"
            case $f in
                *package-lock.json) sed -i "1,15s/^\(      \"version\": \"\)$e_old\"/\1$new\"/" "$f" ;;
            esac
        done
        for f in $(git ls-files Makefile '*/Makefile' GNUmakefile); do
            sed -i "s/^\(VERSION[[:space:]]*[:?]\{0,1\}=[[:space:]]*\)$e_old[[:space:]]*\$/\1$new/" "$f"
        done
        for f in $(git grep -l -E '^#define [A-Z0-9_]+_VERSION_MINOR [0-9]+' -- '*.h' || true); do
            if [ "$(sed -n 's/^#define [A-Z0-9_]*_VERSION_\(MAJOR\|MINOR\|PATCH\) \([0-9]*\)$/\2/p' "$f" | paste -sd.)" = "$old" ]; then
                sed -i -e "s/^\(#define [A-Z0-9_]*_VERSION_MINOR \)[0-9]*\$/\1$((mi + 1))/" \
                    -e "s/^\(#define [A-Z0-9_]*_VERSION_PATCH \)[0-9]*\$/\10/" "$f"
            fi
        done
        git -c user.name=wave-deps -c user.email=wave-deps@localhost -c commit.gpgsign=false \
            commit -q -a -m "wave-deps: $(git rev-parse --short HEAD) built as $new, the minor this wave releases"
    ) >&2
    echo "$new"
}

tools() {
    if command -v dnf >/dev/null; then
        dnf install -y -q --setopt=install_weak_deps=False git rpm-build dnf5-plugins createrepo_c tar gzip zstd findutils \
            python3
    else
        apt-get update -qq
        apt-get install -y -q --no-install-recommends ca-certificates git dpkg-dev debhelper build-essential tar zstd \
            python3
    fi
}

if [ "${1:-}" = --tools ]; then
    tools
    exit
fi
if [ "${1:-}" = --bump ]; then
    bump "${2:?usage: build.sh --bump <tree>}"
    exit
fi

prefix=$(readlink -m "${1:?usage: build.sh <prefix> <branch> <owner> <repo>...}")
branch=${2:?}
owner=${3:?}
shift 3
[ $# -gt 0 ] || { echo "wave-deps: no repository named" >&2; exit 1; }

if command -v dnf >/dev/null; then kind=rpm; else kind=deb; fi
repo=$prefix/$kind
mkdir -p "$repo"

# the repository, added to the system: what is in it so far is what the next build and the caller install from
publish() {
    if [ "$kind" = rpm ]; then
        createrepo_c -q "$repo"
        cat > /etc/yum.repos.d/wave-deps.repo <<EOF
[wave-deps]
name=wave siblings built from $branch
baseurl=file://$repo
enabled=1
gpgcheck=0
priority=1
EOF
        dnf -y -q makecache --repo wave-deps
    else
        (cd "$repo" && dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null)
        chmod -R a+rX "$prefix"
        echo "deb [trusted=yes] file:$repo ./" > /etc/apt/sources.list.d/wave-deps.list
        printf 'Package: *\nPin: origin ""\nPin-Priority: 600\n' > /etc/apt/preferences.d/wave-deps
        apt-get update -qq
    fi
}

want=$(printf '%s\n' "$owner" "$branch" "$@" "${WAVE_DEPS_SHAS:-}")
if [ -f "$prefix/stamp" ] && [ "$(cat "$prefix/stamp")" = "$want" ]; then
    echo "wave-deps: the cached builds of $* at their $branch heads"
    publish
    ls "$repo"
    exit 0
fi
rm -rf "$repo" "$prefix/stamp"
mkdir -p "$repo"
tools
publish

# what the system holds before the siblings' build dependencies come in: they leave with the builds, so the caller's
# steps start from what they would without this action, whether the builds ran or came from the cache
pkgs() {
    if [ "$kind" = rpm ]; then rpm -qa --qf '%{NAME}\n'; else dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1 ~ /^ii/ {print $2}'; fi | sort -u
}
before=$(pkgs)

work=$(mktemp -d)
for name in "$@"; do
    src=$work/$name
    echo "::group::wave-deps: $name at $branch"
    git clone -q --filter=blob:none --branch "$branch" "https://github.com/$owner/$name.git" "$src"
    git config --global --add safe.directory "$src"
    # the commit the cache key was made from (WAVE_DEPS_SHAS: "<repo>=<sha> ..."), not a head that moved since
    sha=$(tr ' ' '\n' <<<"${WAVE_DEPS_SHAS:-}" | sed -n "s/^$name=//p")
    [ -z "$sha" ] || git -C "$src" checkout -q --detach "$sha"
    short=$(git -C "$src" rev-parse --short HEAD)
    version=$(bump "$src")
    echo "wave-deps: $name $short built as $version"
    if [ "$kind" = rpm ]; then
        dnf builddep -y --setopt=install_weak_deps=False "$src"/packaging/*.spec
        "$actions/build-rpm/build-rpm.sh" -n -C "$src" "$repo"
    else
        DEB_BUILD_OPTIONS=nocheck "$actions/build-deb/build-deb.sh" -s +git -L -C "$src" "$repo"
    fi
    publish
    echo "::endgroup::"
done
rm -rf "$work"
added=$(comm -13 <(echo "$before") <(pkgs))
if [ -n "$added" ]; then
    echo "wave-deps: removing the siblings' build dependencies: $(echo $added)"
    if [ "$kind" = rpm ]; then
        dnf remove -y -q $added
    else
        apt-get purge -y -q $added
    fi
fi
echo "$want" > "$prefix/stamp"
ls "$repo"
