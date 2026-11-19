#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# What joins a snapshot's version and its commit time and commit.
#
#   separator.sh <explicit separator, or empty> <staged: true|false> <dry-run: true|false>
#
# A staged build and a release DRY RUN (a run that is not at a release tag) take +git: the snapshot sorts ABOVE the
# version, so beside an already published <version> the run's own binaries are not pruned behind the published ones by
# the installability gate's dose --latest 1, and a (>= <version>) floor is met. Any other snapshot (a pull request's)
# takes the caller's separator, ~git by default, below the release. A release at a tag builds the clean version and
# uses no separator at all (build-deb.sh -t).
set -euo pipefail
explicit=${1:-} staged=${2:-false} dry=${3:-false}
if [ "$staged" = true ] || [ "$dry" = true ]; then echo '+git'
else echo "${explicit:-~git}"; fi
