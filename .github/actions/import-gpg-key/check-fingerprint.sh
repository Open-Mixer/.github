#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The signing key of a channel that is not OpenMixer's is the one fingerprint its caller names.
#
#   check-fingerprint.sh key <imported primary> <wanted>   refuses a signing key that is not the wanted one, by name
#   check-fingerprint.sh want <committed-keys> <wanted>    refuses committed-keys=false with no 40-hex fingerprint named
set -euo pipefail
mode=${1:?usage: check-fingerprint.sh key|want ...}
case $mode in
key)
    have=${2:?}; want=${3:-}
    [ -z "$want" ] || [ "${have^^}" = "${want^^}" ] || {
        echo "::error::the signing key is $have, not the $want this channel signs with: a secret is mapped to another channel's key; nothing was signed" >&2
        exit 1
    }
    ;;
want)
    committed=${2:?}; want=${3:-}
    [ "$committed" != false ] || [[ $want =~ ^[0-9A-Fa-f]{40}$ ]] || {
        echo "::error::committed-keys is false but signing-fingerprint is '$want', not a 40-digit key fingerprint: a channel that is not OpenMixer's names the one key it signs with" >&2
        exit 1
    }
    ;;
*) echo "unknown mode $mode" >&2; exit 2 ;;
esac
