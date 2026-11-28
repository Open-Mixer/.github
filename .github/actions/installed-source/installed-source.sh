#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# installed-source.sh <rpm> <record name> <git url> — prints the full commit the INSTALLED <rpm> was built from, so a job
# reads the source of exactly the version the channel gave it, with no version typed and no tag assumed.
#
# The channel model has three levels, devel/<wave> -> staging -> production, the same bytes promoted, and a tag only on
# main: a merge to devel publishes the real version with no tag and no commit in its name (.github#289). What the
# release tooling records instead is the channel's build record, <tree>/built/<record name>/<version>.commit
# (.github actions/publish-rpms/record-built.sh, one full commit), in the tree the package was published to and copied
# with it on promotion. So, in order:
#   1. the build record of the tree the installed package came from (dnf's from_repo, its baseurl up to /fedora/);
#   2. a snapshot's release, .git<time>.<short>, the commit in the package's own name, resolved against <git url>;
#   3. the release tag v<version> on <git url>: production, whose packages are built from main's tags.
# None of the three: exit 1, naming each place read. Prints one line, the commit, on stdout; the reasons go to stderr.
#
# INSTALLED_VERSION, INSTALLED_RELEASE and INSTALLED_BASEURL replace what rpm and dnf say (tests/installed-source.sh).
set -euo pipefail
usage='usage: installed-source.sh <rpm> <record name> <git url>'
pkg=${1:?$usage} name=${2:?$usage} url=${3:?$usage}
say() { echo "installed-source: $*" >&2; }

v=${INSTALLED_VERSION:-$(rpm -q --qf '%{VERSION}' "$pkg")}
rel=${INSTALLED_RELEASE:-$(rpm -q --qf '%{RELEASE}' "$pkg")}
if [ -n "${INSTALLED_BASEURL+x}" ]; then
  baseurl=$INSTALLED_BASEURL
else
  repo=$(dnf repoquery --installed --qf '%{from_repo}' "$pkg" 2>/dev/null | head -n 1)
  baseurl=$(awk -v id="[$repo]" '$0 == id { s = 1; next } /^\[/ { s = 0 } s && sub(/^baseurl *= */, "") { print; exit }' \
    /etc/yum.repos.d/*.repo 2>/dev/null || true)
  say "$pkg $v-$rel came from ${repo:-no repository} (${baseurl:-no baseurl})"
fi

# 1. the build record of the tree it came from
if [ -n "$baseurl" ] && [ "${baseurl%%/fedora/*}" != "$baseurl" ]; then
  rec=${baseurl%%/fedora/*}/built/$name/$v.commit
  if got=$(curl -fsS --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "$rec" 2>/dev/null | tr -d '[:space:]'); then
    [[ $got =~ ^[0-9a-f]{40}$ ]] || { say "$rec holds '$got', not a full commit"; exit 1; }
    say "$pkg $v: built by $got ($rec)"
    printf '%s\n' "$got"; exit 0
  fi
  say "$pkg $v: no build record at $rec"
else
  say "$pkg $v: its repository's baseurl '${baseurl}' names no channel tree"
fi

# 2. a snapshot names its commit in its release
short=$(printf '%s\n' "$rel" | sed -n 's/.*\.git\([0-9]*\.\)\{0,1\}\([0-9a-f]\{7,40\}\)\(\..*\)\{0,1\}$/\2/p')
if [ -n "$short" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  git init -q "$scratch"
  git -C "$scratch" fetch -q --filter=tree:0 "$url" '+refs/heads/*:refs/remotes/origin/*' || true
  if full=$(git -C "$scratch" rev-parse -q --verify "$short^{commit}"); then
    say "$pkg $v-$rel: the snapshot of $full"
    printf '%s\n' "$full"; exit 0
  fi
  say "$pkg $v-$rel: no branch of $url holds $short"
fi

# 3. production: the release tag
if full=$(git ls-remote "$url" "refs/tags/v$v^{}" "refs/tags/v$v" | awk 'NR == 1 || /\^\{\}$/ { c = $1 } END { if (c) print c }') &&
   [ -n "$full" ]; then
  say "$pkg $v: the tag v$v, $full"
  printf '%s\n' "$full"; exit 0
fi
say "$pkg $v: no build record, no commit in its release '$rel', no tag v$v on $url: its source cannot be named"
exit 1
