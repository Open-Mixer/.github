#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Install openmixer-release on a machine that holds no OpenMixer configuration, then install a package of the
# channel through the repository it adds: the repository is named openmixer, its index verifies with the key
# the package ships, and the package resolves from it.
#
#   install-check.sh <openmixer-release .rpm or .deb, a file or a URL> <package of the channel>
#
# The package is installed alone: it requires nothing another channel serves (the OpenMixer and FreeREAC channels are
# independent, owner ruling 2026-11-23), and tests/install-check-one-channel.sh holds the check to that.
#
# SIGNED=0 skips the signature check of the RPM itself, for a dry run's unsigned build; the repository's
# metadata and the probe package are verified either way.
#
# The testing repositories (RPM) and the testing source (DEB), the staging channel, must be installed and disabled.
#
# Fedora (dnf5) or Debian, as root. Fails when the repository is not the one named, the key does not verify the
# index or the package does not come from the repository.
set -euo pipefail
usage='usage: install-check.sh <openmixer-release package> <package of the channel>'
pkg=${1:?$usage}
probe=${2:?$usage}
work=$(mktemp -d)
chmod 755 "$work" # apt reads a local package as _apt
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

case "$pkg" in
https://*) file=$work/$(basename "$pkg"); curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o "$file" "$pkg" ;;
*) file=$(readlink -f "$pkg") ;;
esac

if command -v dnf >/dev/null; then
    [ ! -e /etc/yum.repos.d/openmixer.repo ] || fail "this machine already has an openmixer.repo"
    dnf install -y --setopt=install_weak_deps=False "$file"
    cat /etc/yum.repos.d/openmixer.repo
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    rpm -qi gpg-pubkey | grep -E '^(Version|Summary|Packager)'
    # the published RPM is signed by the key it ships; a dry run's build is not signed (SIGNED=0)
    if [ "${SIGNED:-1}" = 1 ]; then
        rpm -K "$file" | tee /dev/stderr | grep -q 'digests signatures OK' || fail "$file does not verify with the shipped key"
    else
        echo "$(basename "$file") is a dry run's build: not signed, not checked"
    fi
    # dnf skips a repository it cannot load unless told not to: the index must load and verify
    dnf -y --setopt=retries=10 --setopt=skip_if_unavailable=False makecache --repo openmixer --repo openmixer-noarch ||
        fail "the openmixer repositories do not load"
    dnf repolist | tee "$work/repolist"
    # every OpenMixer repository carries priority=50, the testing ones too: a third-party repository that republishes
    # one of our package names at a higher version must never win (.github#308)
    for id in openmixer openmixer-noarch openmixer-testing openmixer-testing-noarch; do
        p=$(awk -v s="[$id]" '$0 == s {on = 1; next} /^\[/ {on = 0} on && /^priority=/ {sub(/^priority=/, ""); print}' /etc/yum.repos.d/openmixer.repo)
        [ "$p" = 50 ] || fail "[$id] in openmixer.repo has priority '${p:-none}', not 50: a third-party repository could replace our packages"
    done
    for id in openmixer openmixer-noarch; do
        grep -q "^$id " "$work/repolist" || fail "dnf repolist names no $id"
    done
    # the testing repositories (the staging channel) are installed and disabled: the opt-in is the operator's
    dnf repolist --disabled | tee "$work/disabled"
    for id in openmixer-testing openmixer-testing-noarch; do
        grep -q "^$id " "$work/disabled" || fail "dnf repolist --disabled names no $id: the testing repository is missing or enabled"
    done
    dnf install -y --setopt=install_weak_deps=False --setopt=retries=10 "$probe"
    from=$(dnf repoquery --installed --qf '%{from_repo}\n' "$probe" | head -1)
    case "$from" in openmixer|openmixer-noarch) echo "$probe installed from $from" ;; *) fail "$probe came from '$from'" ;; esac
    dnf repoquery --repo openmixer --repo openmixer-noarch --qf '%{name}-%{evr}.%{arch} %{repoid}\n' openmixer-release || true
else
    [ ! -e /etc/apt/sources.list.d/openmixer.sources ] || fail "this machine already has an openmixer.sources"
    apt-get install -y --no-install-recommends "$file"
    ls -l /etc/apt/sources.list.d/openmixer.sources
    cat /etc/apt/sources.list.d/openmixer.sources
    gpg --show-keys /usr/share/keyrings/openmixer-archive-keyring.asc
    apt-get -o Acquire::Retries=5 update 2>&1 | tee "$work/update"
    ! grep -qE '^(W|E):' "$work/update" || fail "apt update with the openmixer source warned or failed"
    # the testing source (the staging channel) is installed and disabled: the opt-in is the tester's. Disabled, apt
    # reads nothing from it; enabled, its signed index loads with the shipped key and no warning; disabled again, it
    # is gone from apt's view. The check puts the file back as the package wrote it.
    testing=/etc/apt/sources.list.d/openmixer-testing.sources
    [ -f "$testing" ] && [ ! -L "$testing" ] || fail "$testing is missing (or a link): the testing source is not installed"
    cat "$testing"
    grep -qx 'Enabled: no' "$testing" || fail "$testing is not 'Enabled: no': the testing source must be installed disabled"
    ! grep -q '/staging/deb/' "$work/update" || fail "apt update read the staging channel with the testing source disabled"
    cp -p "$testing" "$work/testing.sources"
    sed -i 's/^Enabled: no$/Enabled: yes/' "$testing"
    apt-get -o Acquire::Retries=5 update 2>&1 | tee "$work/update-testing"
    cp -p "$work/testing.sources" "$testing"
    ! grep -qE '^(W|E):' "$work/update-testing" || fail "apt update with the testing source enabled warned or failed"
    grep -q '/staging/deb/debian/' "$work/update-testing" || fail "apt update with the testing source enabled did not read the staging channel"
    apt-get -o Acquire::Retries=5 update > "$work/update-again" 2>&1
    ! grep -q '/staging/deb/' "$work/update-again" || fail "apt update still reads the staging channel after the testing source is disabled again"
    echo "the testing source is installed disabled, and enabled it loads the signed staging index"
    apt-cache policy | grep openmixer
    apt-get install -y --no-install-recommends "$probe"
    apt-cache policy "$probe" | tee "$work/policy"
    # shellcheck source=/dev/null
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    # shellcheck source=/dev/null
    [ "$(. /etc/os-release && echo "$ID")" != ubuntu ] || codename=trixie # Ubuntu takes the trixie source
    grep -q "^ \*\*\* .*" "$work/policy" || fail "$probe is not installed"
    awk '/\*\*\*/ {s = 1; next} s && /^ +[0-9]+ / {print; exit}' "$work/policy" | grep -q "openmixer.org/deb/debian/$codename" ||
        fail "the installed $probe does not come from the openmixer source of $codename"
    echo "$probe installed from the openmixer source of $codename"
fi
echo "install check: PASS"
