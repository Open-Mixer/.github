# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Sourced, not run: the package name and upstream version a channel file's name says, the one reading cells.sh and
# purge-staging/drop-staging.sh share.
#
#   file_name_version rpm|deb <file>   prints "<package> <upstream version>", or nothing for a name of another shape
#
# rpm: <name>-<version>-<release>.<arch>.rpm (a source package's arch is src); deb: <name>_<version>_<arch>.deb, whose
# epoch (%3a), revision and +git / ~git suffix are not part of the upstream version.
file_name_version() {
    local b n v
    b=$(basename "$2" ".$1")
    if [ "$1" = rpm ]; then
        b=${b%.*}                       # the architecture
        [[ $b == *-*-* ]] || return 0
        b=${b%-*}                       # the Release
        n=${b%-*} v=${b##*-}
    else
        [[ $b == *_*_* ]] || return 0
        n=${b%%_*} v=${b#*_}
        v=${v%_*}                       # the architecture
        v=${v#*%3a} v=${v%%[+~]git*} v=${v%-*}
    fi
    printf '%s %s\n' "$n" "$v"
}
