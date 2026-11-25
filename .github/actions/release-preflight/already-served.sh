#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# already-served.sh <tag> <package>...   (paths of the channel tree on stdin)
#
# Exits 1, naming the file, when the tree holds a package of the given names at the version the tag names:
#   rpm/**/<name>-<version>-<release>.<arch>.rpm      deb/**/<name>_<version>[-<revision>]_<arch>.deb
# Names may be globs. A tag that is not v<version> names no version and passes. KIND=rpm or KIND=deb reads only that
# half of the tree (a release's deb job must not be refused by the rpms its own rpm job just published); empty reads both.
# RELEASES, space separated, names the Fedora releases (rpm/fedora/<release>/) or Debian suites (deb/debian/<suite>/)
# the release publishes into; a file under another release or suite is not this release's, so an fc44 build of the
# version does not refuse its fc45 publish. A file outside those trees is read for every release; empty reads all.
# STAGING=true reads staging/rpm and staging/deb as well: a merge to devel builds the real package once and publishes it
# to staging, so a version staged before is published already and is never built again (.github#289).
# REAL_ONLY=true counts real builds alone: a file whose name carries a snapshot stamp (.git, +git, ~git) is skipped. A
# dispatched staged run builds a snapshot of the tree's version, and a snapshot of a version published as a real build is
# retired (.github#289): the version is bumped on devel instead.
set -uo pipefail
tag=$1; shift
ver=${tag#v}
[ "$ver" != "$tag" ] || exit 0
found=
while IFS= read -r path; do
  base=${path##*/} full=$path
  if [ "${REAL_ONLY:-false}" = true ]; then
    case $base in *.git*|*+git*|*~git*) continue ;; esac
  fi
  if [ "${STAGING:-false}" = true ]; then path=${path#staging/}; fi
  case $path in
    rpm/*.rpm) [ "${KIND:-}" != deb ] || continue ;;
    deb/*.deb) [ "${KIND:-}" != rpm ] || continue ;;
    *) continue ;;
  esac
  if [ -n "${RELEASES:-}" ]; then
    case $path in
      rpm/fedora/*/*|deb/debian/*/*)
        rel=${path#*/*/}; rel=${rel%%/*}
        case " $RELEASES " in *" $rel "*) ;; *) continue ;; esac ;;
    esac
  fi
  for name in "$@"; do
    # shellcheck disable=SC2254 # name is a glob on purpose
    case $base in
      ${name}-${ver}-*.rpm|${name}_${ver}-*.deb|${name}_${ver}_*.deb) found="$found $full"; break ;;
    esac
  done
done
if [ -n "$found" ]; then
  for f in $found; do echo "::error::$tag is already served: $f (the channel holds this version; bump the version, or set republish for a rerun that must finish a partial publish)"; done
  if [ "${REAL_ONLY:-false}" = true ]; then
    echo "::error::$tag is published as a real build: a snapshot of a published version is retired: bump the version on devel"
  elif [ "${STAGING:-false}" = true ]; then
    echo "::error::a merge to devel builds the real package once: a change after a published build is a new version, never the same one again (no rebuild of a published version, no epoch)"
  fi
  exit 1
fi
echo "$tag is not served yet"
