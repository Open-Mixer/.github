#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A package of one house organisation is never published into the other's channel (owner ruling 2026-11-23, .github#224:
# the OpenMixer and FreeREAC channels are independent; FreeREAC's libreac, reac-pw and reac-stageboxes reached the
# OpenMixer channel because a FreeREAC release.yml that named no target-repo took the shared workflows' default, and a
# republish workflow of this repository built them for it).
#
#   channel-owner.sh <channel owner/repo> <package file>...
#
# The house organisations and what names each: Open-Mixer (github.com/Open-Mixer/, openmixer.org) and FreeREAC
# (github.com/FreeREAC/, freereac.github.io), compared without case. Refused, naming the reason, before anything is placed:
#   - a run of one house organisation (GITHUB_REPOSITORY_OWNER, the calling repository's owner) publishing into the other's
#     channel;
#   - a package whose URL (rpm) or Homepage (deb) names one house organisation, into the other's channel.
# A package whose URL names neither (an upstream project this channel packages: clap, mod-host) is not judged here.
# publish-rpms/publish-tree.sh and publish-debs/publish-tree.sh call it on the packages a run would place, never on what
# the tree already serves, so a regeneration of a tree (the prune, the removal of FreeREAC's packages) is not refused.
set -euo pipefail
usage='usage: channel-owner.sh <channel owner/repo> <package file>...'
channel=${1:?$usage}; shift
house() { # <text>: the house organisation it names, lower case, or nothing
    local t=${1,,}
    case $t in
    *github.com/open-mixer/* | *://openmixer.org* | *://www.openmixer.org*) echo open-mixer ;;
    *github.com/freereac/* | *://freereac.github.io*) echo freereac ;;
    esac
}
owner=${channel%%/*}; owner=${owner,,}
case $owner in open-mixer | freereac) ;; *) exit 0 ;; esac # a channel of neither house is not this rule's
bad=0
caller=${GITHUB_REPOSITORY_OWNER:-}; caller=${caller,,}
if [ -n "$caller" ] && { [ "$caller" = open-mixer ] || [ "$caller" = freereac ]; } && [ "$caller" != "$owner" ]; then
    echo "refused: a run of ${GITHUB_REPOSITORY_OWNER} publishes into $channel, the channel of another organisation (name its own target-repo)" >&2
    bad=1
fi
for f in "$@"; do
    case $f in
    *.rpm) url=$(rpm -qp --nosignature --qf '%{URL}' "$f" 2>/dev/null) || { echo "refused: $(basename "$f") is not a readable rpm" >&2; bad=1; continue; } ;;
    *.deb) url=$(dpkg-deb -f "$f" Homepage 2>/dev/null) || url= ;;
    *) continue ;;
    esac
    of=$(house "$url")
    if [ -n "$of" ] && [ "$of" != "$owner" ]; then
        echo "refused: $(basename "$f") is a package of $of ($url), not of the owner of $channel" >&2
        bad=1
    fi
done
[ "$bad" = 0 ] || { echo "nothing was placed or signed: a channel serves its own organisation's packages only" >&2; exit 1; }
