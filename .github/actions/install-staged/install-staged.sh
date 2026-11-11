#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Install the staged packages of other repositories, all in one dnf or apt transaction.
#
#   install-staged.sh [owner/]repo@version[:package,package] ...
#
# Each argument names the prerelease staged-v<version> of Open-Mixer/<repo> (or <owner>/<repo>), which a staged run of
# build-rpm.yml or build-deb.yml filled. Of its files the container takes those of its own target, fc44 x86_64 (and
# noarch) on Fedora, trixie amd64 (and all) on Debian, the only targets staged; never a debuginfo, debugsource, dbgsym or
# source package; with a package list, only those packages. The dependencies they carry resolve from the normal channels
# in the same transaction.
#
# Refused, before anything is installed: a repository with no such prerelease, a staged tag that is a real release, a
# target with no file, a named package that is absent, a file whose version is not <version>, and a staged version
# outside a floor or ceiling the consumer's packaging/*.spec or debian/control puts on that package in a dependency
# field (STAGED_TREE, default the working directory; a range this cannot read is a ::warning::, staged.py floor).
#
# The repositories are public: the release is read from the REST API and the files from their download URLs, with no
# token (GH_TOKEN, when set, only raises the API rate limit). Runs as root in a Fedora or Debian container.
# STAGED_API, STAGED_TARGET (rpm:fc44.x86_64, deb:trixie.amd64), STAGED_DIR and STAGED_DRY=1 (stop before the
# install) are for tests/staged-packages.sh.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
lib=$here/staged.py
owner=${STAGED_OWNER:-Open-Mixer}
api=${STAGED_API:-https://api.github.com}
dir=${STAGED_DIR:-${RUNNER_TEMP:-/tmp}/staged-packages}
tree=${STAGED_TREE:-.}
target=${STAGED_TARGET:-}
die() { echo "::error::install-staged: $*" >&2; exit 1; }
[ "$#" -gt 0 ] || die "no [owner/]repo@version given"

need() { # <command> <package>
    command -v "$1" >/dev/null && return 0
    if command -v dnf >/dev/null; then dnf install -y -q --setopt=install_weak_deps=False "$2"
    else apt-get update -qq && apt-get install -y -qq --no-install-recommends "$2" ca-certificates; fi
}
need python3 python3
need curl curl

if [ -z "$target" ]; then
    . /etc/os-release
    if command -v dnf >/dev/null; then target=rpm:fc${VERSION_ID}.$(uname -m)
    else target=deb:${VERSION_CODENAME:-unknown}.$(dpkg --print-architecture); fi
fi
kind=${target%%:*}
case $target in
    rpm:fc44.x86_64|deb:trixie.amd64) ;;
    *) die "packages are staged for fc44.x86_64 (RPM) and trixie.amd64 (DEB) only, not ${target#*:}: this container takes the channel's releases" ;;
esac

auth=()
[ -z "${GH_TOKEN:-}" ] || [ "${api#https://}" = "$api" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
rm -rf "$dir"; mkdir -p "$dir"
files=() names=() versions=() floors=()
for spec in "$@"; do
    [[ $spec =~ ^(([A-Za-z0-9_.-]+)/)?([A-Za-z0-9_.-]+)@([0-9][0-9A-Za-z.+~]*)(:([A-Za-z0-9_.+,-]+))?$ ]] ||
        die "'$spec' is not [owner/]repo@version[:package,package]"
    o=${BASH_REMATCH[2]:-$owner} r=${BASH_REMATCH[3]} v=${BASH_REMATCH[4]} pkgs=${BASH_REMATCH[6]}
    tag=staged-v$v
    json=$dir/$r.json
    # only a 404 (a missing file, for the tests' file:// API) says nothing was staged: a rate limit or a network
    # error is reported as what it is, with the answer
    code=$(curl -sSL --retry 5 --retry-delay 3 --connect-timeout 20 "${auth[@]}" -o "$json" -w '%{http_code}' \
        "$api/repos/$o/$r/releases/tags/$tag" 2>"$dir/curl.err") && rc=0 || rc=$?
    case $rc:$code in
        0:200|0:000) ;;
        0:404|37:*) die "$o/$r has no staged release $tag: nothing was staged for $v, the run that stages it has not finished, or v$v is released and its staged packages are gone (then drop it from staged-deps)" ;;
        *) die "$o/$r $tag could not be read (HTTP $code, curl exit $rc): $(tr '\n' ' ' < "$dir/curl.err")$(head -c 300 "$json" 2>/dev/null | tr '\n' ' ')" ;;
    esac
    sel=$(python3 -I "$lib" select --kind "$kind" --target "${target#*:}" --repo "$o/$r" --version "$v" \
        --packages "$pkgs" --release "$json") || exit 1
    mkdir -p "$dir/$r"
    while IFS=$'\t' read -r name ver url file; do
        curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$dir/$r/$file" "$url" ||
            die "$o/$r $tag: $file does not download from $url"
        files+=("$dir/$r/$file") names+=("$name") versions+=("$ver")
        echo "staged: $dir/$r/$file"
        python3 -I "$lib" floor --kind "$kind" --tree "$tree" "$name" "$ver" 2>>"$dir/floors" || floors+=("$name")
    done <<<"$sel"
done
[ ! -s "$dir/floors" ] || cat "$dir/floors" >&2 # the refusals, and the ranges that could not be checked
if [ "${#floors[@]}" -gt 0 ]; then die "the staged ${floors[*]} do not meet this tree's packaging"; fi
[ "${STAGED_DRY:-}" != 1 ] || exit 0

# the file is what its name says: the name chose it, the contents are what get installed
for i in "${!files[@]}"; do
    f=${files[$i]}
    if [ "$kind" = rpm ]; then got=$(rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE}' "$f")
    else got="$(dpkg-deb -f "$f" Package) $(dpkg-deb -f "$f" Version)"; fi
    want="${names[$i]} ${versions[$i]}"
    # a DEB's file name carries no epoch, its Version field does
    [ "$got" = "$want" ] || { [ "$kind" = deb ] && [ "${got%% *} ${got#* *:}" = "$want" ]; } ||
        die "$(basename "$f") holds $got, not $want"
done

if [ "$kind" = rpm ]; then
    dnf install -y --setopt=install_weak_deps=False "${files[@]}"
    rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' "${names[@]}"
else
    chmod 755 "$dir" "$dir"/*/ && chmod 644 "${files[@]}" # apt reads a local package as _apt
    apt-get update -qq
    apt-get install -y --no-install-recommends "${files[@]}"
    dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' "${names[@]}"
fi
