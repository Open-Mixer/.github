#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# built-arches.sh deb|rpm <packages dir>: the architectures the release built, space separated, on stdout: what a dry
# run's installability check judges. A pull-request dry run builds x86_64/amd64 only, so its architecture-independent
# packages (noarch, all) land beside the published packages of every other architecture without their new builds, and
# a consumer pinned to them reads as broken there; the release itself builds every architecture and is judged on all
# of them. Source packages, noarch and all are not architectures; nothing printed when the release has none.
set -euo pipefail
kind=$1 dir=$2
case $kind in
  rpm) find "$dir" -name '*.rpm' ! -name '*.src.rpm' -printf '%f\n' | sed -E 's/.*\.([^.]+)\.rpm$/\1/' ;;
  deb) find "$dir" -name '*.deb' -printf '%f\n' | sed -E 's/.*_([^_]+)\.deb$/\1/' ;;
  *) echo "built-arches.sh: deb or rpm, not '$kind'" >&2; exit 2 ;;
esac | { grep -vxE 'noarch|all' || true; } | sort -u | paste -sd' ' -
