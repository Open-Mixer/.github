#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Generated lower-layer floors (owner ruling 2026-11-26, .github#312): a package requires every OpenMixer package of a
# lower layer at least at the version it was built against. The version is read from the build root, never typed: a
# spec names its OpenMixer dependencies bare, and the build copy of the spec gets the floor.
#
#   floors.sh apply <spec>       every bare name of a Requires: line that is an installed OpenMixer package becomes
#                                "<name> >= <its installed version>"; the spec is the build copy, edited in place
#   floors.sh check <rpm>...     fails, naming each, a built package that requires an installed OpenMixer package with
#                                no version (the gate: a missing floor is a defect, as a hand-typed one is)
#
# An OpenMixer package is one installed from an openmixer* repository (the channel, staging, testing) or from a local
# file (@commandline: the contract-bootstrap siblings). A name with a version already, a macro (%{name}...), a file
# path, a rich dependency or a capability such as pkgconfig(...) or a soname is left as it is: rpm generates those, and a
# soname carries its floor in its versioned symbols. Exit 0 done, 1 a check found an unversioned OpenMixer requirement,
# 2 usage. Env: FLOORS_RPM, FLOORS_DNF (tests).
set -euo pipefail
RPM=${FLOORS_RPM:-rpm}
DNF=${FLOORS_DNF:-dnf}

# ours <name>: prints the installed version of <name> when it is an OpenMixer package, else nothing
ours() {
    local v repo
    v=$("$RPM" -q --qf '%{VERSION}\n' "$1" 2>/dev/null | head -1) || return 0
    [ -n "$v" ] || return 0
    repo=$("$DNF" -q repoquery --installed --qf '%{from_repo}\n' "$1" 2>/dev/null | head -1) || return 0
    case $repo in openmixer*|@commandline) echo "$v" ;; esac
}

plain() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; }

apply() {
    local spec=$1 line out tag rest words w i next v n=0
    out=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^(Requires:[[:space:]]*)(.*)$ ]]; then
            tag=${BASH_REMATCH[1]} rest=${BASH_REMATCH[2]}
            # a rich dependency ((a or b)) is rpm's own grammar: left whole
            if [[ $rest != *'('* ]]; then
                read -r -a words <<<"${rest//,/ }"
                rest=
                for ((i = 0; i < ${#words[@]}; i++)); do
                    w=${words[i]} next=${words[i + 1]:-}
                    if [[ $next =~ ^(\>=|\<=|=|\>|\<)$ ]]; then
                        rest+="${rest:+ }$w $next ${words[i + 2]:-}"; i=$((i + 2)); continue
                    fi
                    v=
                    plain "$w" && v=$(ours "$w")
                    if [ -n "$v" ]; then
                        rest+="${rest:+, }$w >= $v"; n=$((n + 1)); echo "floor: $w >= $v (installed in the build root)"
                    else
                        rest+="${rest:+, }$w"
                    fi
                done
                line=$tag$rest
            fi
        fi
        printf '%s\n' "$line" >> "$out"
    done < "$spec"
    cat "$out" > "$spec"; rm -f "$out"
    echo "floors: $n generated in $(basename "$spec")"
}

check() {
    local f req name bad=0
    for f in "$@"; do
        case $f in *.src.rpm) continue ;; esac
        while IFS= read -r req; do
            name=${req%% *}
            plain "$name" || continue
            [ "$name" = "$req" ] || continue   # versioned
            [ -n "$(ours "$name")" ] || continue
            echo "$(basename "$f") requires $name with no version: an OpenMixer package of a lower layer needs its generated floor (.github#312)"
            bad=1
        done < <("$RPM" -qp --requires "$f" 2>/dev/null)
    done
    return "$bad"
}

case ${1:-} in
    apply) [ $# -eq 2 ] || { echo "usage: floors.sh apply <spec>" >&2; exit 2; }; apply "$2" ;;
    check) shift; [ $# -ge 1 ] || { echo "usage: floors.sh check <rpm>..." >&2; exit 2; }; check "$@" ;;
    *) echo "usage: floors.sh apply <spec> | check <rpm>..." >&2; exit 2 ;;
esac
