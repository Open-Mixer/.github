#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# tests/installed-source.sh — .github/actions/installed-source/installed-source.sh names the commit each channel level records, and refuses when
# none does. A scratch channel tree (file://) and a scratch repository stand in for the channel and GitHub:
#   devel    a real devel build, no tag and no commit in its name: the tree's build record;
#   snapshot a staged snapshot (.git<time>.<short>) with no record: the commit in its release;
#   tag      a production build with no record: the tag v<version>, peeled;
#   none     a devel build whose record is missing, with no tag: refused (exit 1), never a guessed commit;
#   garbage  a record that holds no full commit: refused.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.github/actions/installed-source" && pwd)
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
git init -q "$S/src"
g() { git -C "$S/src" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
g commit -q --allow-empty -m one
one=$(g rev-parse HEAD)
g commit -q --allow-empty -m two
two=$(g rev-parse HEAD)
g tag -a -m v1.0.0 v1.0.0 "$one"
mkdir -p "$S/devel/rpm/built/pkg" "$S/prod/rpm"
printf '%s\n' "$two" > "$S/devel/rpm/built/pkg/2.0.0.commit"

fail=0
check() { # $1 = case, $2 = expected commit or "refused", then the env assignments
  local label=$1 want=$2; shift 2
  local got rc=0
  got=$(env "$@" bash "$HERE/installed-source.sh" pkg pkg "file://$S/src" 2>/dev/null) || rc=$?
  if [ "$want" = refused ]; then
    [ "$rc" -ne 0 ] && [ -z "$got" ] || { echo "installed-source test: FAIL $label: answered '$got', not refused"; fail=1; return; }
  else
    [ "$rc" -eq 0 ] && [ "$got" = "$want" ] || { echo "installed-source test: FAIL $label: '$got' (exit $rc), not $want"; fail=1; return; }
  fi
  echo "installed-source test: $label — $want"
}
check devel "$two" INSTALLED_VERSION=2.0.0 INSTALLED_RELEASE=1.fc45 "INSTALLED_BASEURL=file://$S/devel/rpm/fedora/45/x86_64/"
check snapshot "$one" INSTALLED_VERSION=1.0.0 "INSTALLED_RELEASE=1.git1764000000.${one:0:9}.fc45" "INSTALLED_BASEURL=file://$S/prod/rpm/fedora/45/x86_64/"
check tag "$one" INSTALLED_VERSION=1.0.0 INSTALLED_RELEASE=1.fc45 "INSTALLED_BASEURL=file://$S/prod/rpm/fedora/45/x86_64/"
check none refused INSTALLED_VERSION=3.0.0 INSTALLED_RELEASE=1.fc45 "INSTALLED_BASEURL=file://$S/devel/rpm/fedora/45/x86_64/"
printf 'not-a-commit\n' > "$S/devel/rpm/built/pkg/4.0.0.commit"
check garbage refused INSTALLED_VERSION=4.0.0 INSTALLED_RELEASE=1.fc45 "INSTALLED_BASEURL=file://$S/devel/rpm/fedora/45/x86_64/"
[ "$fail" -eq 0 ] || exit 1
echo "installed-source test: all five cases hold"
