#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The upgrade arm of the release install check, RPM: a machine that holds what the channel serves of this source
# upgrades onto the new build in one dnf transaction, and keeps none of the old packages. For each of the newest
# <back> versions of the source the channel serves below the build (2 by default):
#   1. install every binary package of that version (debuginfo and debugsource aside) from the channel;
#   2. offer the build as a repository above the channel and run `dnf upgrade` on those packages, as a host does;
#   3. RED when the transaction fails (a file two packages own, a requirement nothing meets: dnf's own lines are
#      quoted), and RED when a package of the source is left at the old version afterwards: a package the build
#      renamed or dropped without `Obsoletes:` (omx-clap-core 0.34.0, .github#261).
# A served version whose own set no longer installs from the channel measures nothing: it is named as a warning, never
# a pass. No served version below the build (a first release) is a notice. The packages of the source are removed
# between versions, so each one starts from the channel alone. Runs as root in the release's own Fedora container,
# the channel already added (add-openmixer).
#
#   upgrade-rpm.sh <dir of the built RPMs> <channel> [<back>]     <channel>: openmixer (repositories openmixer and,
#                                                                  where the repository file has it, openmixer-noarch)
set -euo pipefail
dir=$(readlink -f "$1"); channel=$2; back=${3:-2}
[[ $back =~ ^[1-9][0-9]*$ ]] || { echo "::error::upgrade-rpm: <back> '$back' is not a count of 1 or more"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "::error::upgrade-rpm installs into the container: run it as root there"; exit 2; }
arch=$(rpm -E %_arch)
mapfile -t built < <(find "$dir" -maxdepth 1 -name '*.rpm' ! -name '*.src.rpm' \( -name "*.$arch.rpm" -o -name '*.noarch.rpm' \) \
    ! -name '*-debuginfo-*' ! -name '*-debugsource-*' | sort)
[ "${#built[@]}" -gt 0 ] || { echo "::error::upgrade-rpm: no $arch or noarch RPM in $dir"; exit 2; }
srpm=$(rpm -qp --qf '%{SOURCERPM}' "${built[0]}" 2>/dev/null)
new=${srpm%.src.rpm}; rel=${new##*-}; new=${new%-*}; src=${new%-*}; new=${new##*-}-$rel
for f in "${built[@]}"; do
    [ "$(rpm -qp --qf '%{SOURCERPM}' "$f" 2>/dev/null)" = "$srpm" ] || { echo "::error::upgrade-rpm: $f is not a package of $srpm"; exit 2; }
done
repos=(--repo "$channel"); ! grep -qx "\[$channel-noarch\]" "/etc/yum.repos.d/$channel.repo" 2>/dev/null || repos+=(--repo "$channel-noarch")
vercmp() { rpm --eval "%{lua: print(rpm.vercmp('$1', '$2'))}"; }

# the versions of the source the channel serves below the build, newest last
mapfile -t served < <(dnf repoquery -q "${repos[@]}" --arch "$arch,noarch" --qf '%{sourcerpm}\n' 2>/dev/null \
    | awk -v src="$src" '{ s = $1; sub(/-[^-]*-[^-]*\.src\.rpm$/, "", s) } s == src { vr = substr($1, length(src) + 2); sub(/\.src\.rpm$/, "", vr); print vr }' | sort -uV)
older=()
for vr in "${served[@]}"; do [ "$(vercmp "$vr" "$new")" = -1 ] && older+=("$vr"); done
if [ "${#older[@]}" -eq 0 ]; then
    echo "::notice::upgrade-rpm: $channel serves no $src below $new for $arch: no upgrade to check"
    exit 0
fi
from=("${older[@]: -$back}")

# the build, as a repository above the channel
cand=$(mktemp -d); trap 'rm -rf "$cand" /etc/yum.repos.d/upgrade-candidate.repo' EXIT
cp "${built[@]}" "$cand"/
createrepo_c -q "$cand"
printf '[upgrade-candidate]\nname=the build under check\nbaseurl=file://%s\ngpgcheck=0\npriority=1\n' "$cand" > /etc/yum.repos.d/upgrade-candidate.repo

# the installed packages of the source: at the build's version (new), or at any other (old: what an upgrade left behind)
of_source() { # new|old
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{SOURCERPM}\n' | awk -v src="$src" -v srpm="$srpm" -v want="$1" '
        { s = $2; sub(/-[^-]*-[^-]*\.src\.rpm$/, "", s) }
        s == src && (want == "new") == ($2 == srpm) { print $1 }' | sort | paste -sd ' '
}
red=0 measured=0
for vr in "${from[@]}"; do
    echo "== $src $vr -> $new ($arch)"
    mapfile -t old < <(dnf repoquery -q "${repos[@]}" --arch "$arch,noarch" --qf '%{name}-%{evr}.%{arch} %{sourcerpm}\n' 2>/dev/null \
        | awk -v s="$src-$vr.src.rpm" '$2 == s {print $1}' | grep -vE -- '-debug(info|source)-' | sort -u)
    if ! dnf install -y -q --setopt=install_weak_deps=False --disablerepo=upgrade-candidate "${old[@]}" > "$cand.base.log" 2>&1; then
        echo "::warning::upgrade-rpm: the served $src $vr does not install from $channel today, so no upgrade from it is measured: $(grep -m3 -E '^ *(-|Problem|Error)' "$cand.base.log" | tr '\n' ' ')"
        continue
    fi
    mapfile -t names < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' | awk -v s="$src-$vr.src.rpm" '$2 == s {print $1}' | sort -u)
    echo "installed: ${old[*]}"
    measured=$((measured + 1))
    if dnf upgrade -y --setopt=install_weak_deps=False "${names[@]}" > "$cand.up.log" 2>&1; then
        left=$(of_source old)
        if [ -n "$left" ]; then
            echo "::error::upgrade from $src $vr to $new leaves $left installed: a package $new renamed or dropped carries no Obsoletes: <old name> < <first version without it>"
            red=1
        else
            echo "ok   $src $vr -> $new: one transaction, now $(of_source new)"
        fi
    else
        cat "$cand.up.log"
        echo "::error::upgrade from $src $vr to $new fails: $(grep -m4 -E 'conflicts|nothing provides|cannot install|Problem' "$cand.up.log" | tr '\n' ' ')"
        red=1
    fi
    # the next version starts from the channel alone
    read -ra gone <<< "$(of_source old) $(of_source new)"
    [ "${#gone[@]}" -eq 0 ] || dnf remove -y -q --noautoremove "${gone[@]}" > /dev/null 2>&1 || rpm -e --nodeps "${gone[@]}"
done
rm -f "$cand.base.log" "$cand.up.log"
[ "$measured" -gt 0 ] || echo "::warning::upgrade-rpm: none of $src ${from[*]} installs from $channel today: no upgrade was measured"
exit "$red"
