#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# tree-version.sh rpm|deb [<tree>]
#
# Prints the version a tree packages, as its own packaging tool reads it, never a text match:
#   rpm  rpmspec -q --srpm --qf '%{VERSION}' of the one packaging/*.spec, its macros expanded (Version: %{upstream} is
#        the value of upstream, not the word)
#   deb  dpkg-parsechangelog -S Version of debian/changelog, without the Debian revision (1.2.0-1 is 1.2.0), the
#        version a channel file name and a v<version> tag carry
# Refuses, naming the tree, a tree with no spec or more than one, an empty version, and an epoch (no epochs, ever).
# The build workflows read the version of a merge to devel, of a staged dispatch and of a pull request into devel with
# it, and promote-staged the version at the commit it promotes (.github#289).
set -euo pipefail
kind=${1:?usage: tree-version.sh rpm|deb [<tree>]}
tree=${2:-.}
case $kind in
    rpm)
        shopt -s nullglob
        specs=("$tree"/packaging/*.spec)
        [ "${#specs[@]}" = 1 ] || { echo "::error::$tree holds ${#specs[@]} packaging/*.spec files, not one: cannot tell its version" >&2; exit 1; }
        v=$(rpmspec -q --srpm --qf '%{VERSION}\n' "${specs[0]}" | head -n1) ;;
    deb)
        [ -f "$tree/debian/changelog" ] || { echo "::error::$tree has no debian/changelog: cannot tell its version" >&2; exit 1; }
        v=$(dpkg-parsechangelog -l "$tree/debian/changelog" -S Version)
        case $v in *:*) echo "::error::$tree/debian/changelog carries the epoch of $v: no epoch is ever used" >&2; exit 1 ;; esac
        case $v in *-*) v=${v%-*} ;; esac ;;
    *) echo "usage: tree-version.sh rpm|deb [<tree>]" >&2; exit 2 ;;
esac
[ -n "$v" ] || { echo "::error::$tree names no $kind version" >&2; exit 1; }
case $v in *%*) echo "::error::$tree names the $kind version '$v', a macro left unexpanded" >&2; exit 1 ;; esac
printf '%s\n' "$v"
