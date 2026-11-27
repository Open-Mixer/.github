#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The channel levels of the three-channel model (docs/release-operations.md, "The three channel levels"):
# devel/<wave> -> staging -> the channel root, the same bytes promoted up. One place names where a level's
# tree lies in the channel, so the publish, the client and the promotion never spell the path twice.
#
#   channel-level.sh tree <rpm|deb> <level>      prints the tree of the level: staging/<kind> or devel/<wave>/<kind>
#   channel-level.sh wave <level>                prints <wave> of devel/<wave> (or of a bare <wave>)
#   channel-level.sh repo-file <level> <dir>     writes the dnf repository file the level's rpm tree serves into <dir>
#                                                (devel: openmixer-devel.repo with the wave written in) and prints its path
#
# A level is `staging` or `devel/<wave>`, <wave> being [a-z0-9-]+ (the wave's name: devel-wave-2026-11-27).
# Anything else is refused, naming it: a level is joined into a path of the channel, so `devel/../rpm` or an empty wave
# must never reach a mkdir, a copy or a `git add`.
set -euo pipefail
usage='usage: channel-level.sh tree <rpm|deb> <level> | wave <level> | repo-file <level> <dir>'
here=$(dirname "$(readlink -f "$0")")
die() { echo "channel-level: $*" >&2; exit 1; }

wave_of() { # <level or wave>: the wave, or a refusal
    local w=${1#devel/}
    [[ $w =~ ^[a-z0-9-]+$ ]] || die "'$1' is not devel/<wave> with <wave> of [a-z0-9-]+"
    printf '%s\n' "$w"
}
check_level() { # <level>: staging or devel/<wave>, else a refusal
    case $1 in
        staging) ;;
        devel/*) wave_of "$1" >/dev/null ;;
        *) die "'$1' is not a channel level: staging or devel/<wave>" ;;
    esac
}

cmd=${1:?$usage}
case $cmd in
tree)
    kind=${2:?$usage} level=${3:?$usage}
    case $kind in rpm | deb) ;; *) die "rpm or deb, not '$kind'" ;; esac
    check_level "$level"
    if [ "$level" = staging ]; then echo "staging/$kind"; else echo "devel/$(wave_of "$level")/$kind"; fi
    ;;
wave)
    [ "${2:?$usage}" != staging ] || die "staging is a level of its own, not a wave"
    wave_of "$2"
    ;;
repo-file)
    level=${2:?$usage} dir=${3:?$usage}
    check_level "$level"
    if [ "$level" = staging ]; then
        readlink -f "$here/../../../packaging/staging/openmixer-staging.repo"
    else
        mkdir -p "$dir"
        sed "s|@WAVE@|$(wave_of "$level")|g" "$here/../../../packaging/devel/openmixer-devel.repo.in" > "$dir/openmixer-devel.repo"
        readlink -f "$dir/openmixer-devel.repo"
    fi
    ;;
*) die "$usage" ;;
esac
