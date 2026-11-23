#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# floors.sh ROOT: the floors check where a repository did not wire it itself (.github#237). A tree with
# packaging/deps.txt must state its floors in the spec, debian/control and the workflows (render.sh --check), and is
# red by name otherwise; a tree with no deps.txt declares no floors and passes, saying so. release-preflight runs it
# on every release and dry run of build-rpm.yml and build-deb.yml; public-sources-check.yml runs the deps-render action
# on every pull request of a repository that has the file.
set -uo pipefail
root=${1:?floors.sh needs the tree to check}
if [ ! -f "$root/packaging/deps.txt" ]; then
  echo "deps-render: no packaging/deps.txt in $root: this repository declares no floors, nothing to check"
  exit 0
fi
out=$("$(dirname "$0")/render.sh" --check "$root" 2>&1); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ]; then
  echo "::error title=deps.txt floors::the floors of packaging/deps.txt are not the ones the spec, debian/control or a workflow states; bring deps.txt to the packaged floors (render.sh --write renders the other way)"
  exit 1
fi
