#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# What joins a snapshot's version and its commit time and commit.
#
#   separator.sh <explicit separator, or empty> <staged: true|false> <dry-run: true|false>
#
# Every snapshot takes +git: the snapshot sorts ABOVE the version, so beside an already published <version> the
# run's own binaries are not pruned behind the published ones by the installability gate's dose --latest 1 (a pull
# request run hits the same pruning), and a (>= <version>) floor is met. A staged build or a dry run always does; ~git
# (below the release) remains only for a caller that names it explicitly and is neither. A release at a tag builds the
# clean version and uses no separator at all (build-deb.sh -t).
set -euo pipefail
explicit=${1:-} staged=${2:-false} dry=${3:-false}
if [ "$staged" = true ] || [ "$dry" = true ]; then echo '+git'
else echo "${explicit:-+git}"; fi
