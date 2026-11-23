#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# packaging/openmixer-release/install-check.sh installs openmixer-release ALONE on the clean machine, on Fedora and on
# Debian: the OpenMixer and FreeREAC channels are independent (owner ruling 2026-11-23, .github#224), so the check
# never fetches or installs FreeREAC's release package, even with FREEREAC_RELEASE_URL in the environment (the variable
# release-package.yml passed while openmixer-release 1-7 to 1-9 required freereac-release).
#
# The package managers are recording stubs on a PATH of their own and /etc is a scratch directory, so this runs
# anywhere, as any user; what is proved is what the script asks the package manager to do, not what dnf or apt does.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
check=$here/../packaging/openmixer-release/install-check.sh
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# a PATH holding the stubs and the few real tools the script uses, and no dnf unless the arm puts one there
real_path() {
    mkdir -p "$1"
    for t in bash mktemp chmod rm readlink basename cat grep tee head awk ls sed cut tr cp; do
        ln -sf "$(command -v "$t")" "$1/$t"
    done
}
stub() { # <dir> <name> <body>
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n%s\n' "$2" "$w" "$3" > "$1/$2"
    chmod +x "$1/$2"
}
# the script as it runs on the machine, its /etc pointed at the scratch directory
prepare() { # <arm>
    local d=$w/$1
    mkdir -p "$d/etc/yum.repos.d" "$d/etc/apt/sources.list.d" "$d/etc/pki/rpm-gpg" "$d/usr/share/keyrings"
    sed -e "s|/etc/|$d/etc/|g" -e "s|/usr/share/keyrings/|$d/usr/share/keyrings/|g" "$check" > "$d/check.sh"
    printf 'ID=debian\nVERSION_CODENAME=trixie\n' > "$d/etc/os-release"
    echo pkg > "$d/openmixer-release.pkg"
    : > "$w/calls"
}
# curl: any fetch is recorded; a FreeREAC one is what this test exists to catch
curl_body='out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done; [ -z "$out" ] || echo deb > "$out"'

# ---- Fedora
d=$w/rpm; prepare rpm; real_path "$d/bin"
stub "$d/bin" dnf "
case \"\$*\" in
  *openmixer-release.pkg*) printf '[openmixer]\n[openmixer-noarch]\n' > '$d/etc/yum.repos.d/openmixer.repo' ;;
  'repolist --disabled') printf 'openmixer-testing x\nopenmixer-testing-noarch x\n' ;;
  repolist) printf 'openmixer x\nopenmixer-noarch x\n' ;;
  *'repoquery --installed'*) echo openmixer ;;
esac"
stub "$d/bin" rpm 'echo "Version     : 1"'
stub "$d/bin" curl "$curl_body"
PATH=$d/bin FREEREAC_RELEASE_URL=https://fr.example.org/rpm/freereac-release.noarch.rpm SIGNED=0 \
    bash "$d/check.sh" "$d/openmixer-release.pkg" probe-pkg > "$w/rpm.log" 2>&1 || { cat "$w/rpm.log"; fail "rpm: the install check failed on the stubs"; }
grep -q 'install check: PASS' "$w/rpm.log" || fail "rpm: the install check did not reach its end: $(cat "$w/rpm.log")"
! grep -qi freereac "$w/calls" || fail "rpm: the install check reached the FreeREAC channel: $(grep -i freereac "$w/calls")"
first=$(grep -m1 '^dnf install' "$w/calls")
[ "$first" = "dnf install -y --setopt=install_weak_deps=False $d/openmixer-release.pkg" ] ||
    fail "rpm: openmixer-release is not installed alone: '$first'"
echo "ok   rpm: openmixer-release is installed alone, FREEREAC_RELEASE_URL is not read"

# ---- Debian
d=$w/deb; prepare deb; real_path "$d/bin"
stub "$d/bin" apt-get "
case \"\$*\" in
  *openmixer-release.pkg*) echo 'Types: deb' > '$d/etc/apt/sources.list.d/openmixer.sources'
    printf 'Enabled: no\nTypes: deb\n' > '$d/etc/apt/sources.list.d/openmixer-testing.sources' ;;
  *update) ! grep -qx 'Enabled: yes' '$d/etc/apt/sources.list.d/openmixer-testing.sources' ||
    echo 'Get:1 https://www.openmixer.org/staging/deb/debian/trixie ./ InRelease' ;;
esac"
stub "$d/bin" apt-cache "
case \"\$*\" in
  'policy probe-pkg') printf ' *** 1 500\n        500 https://www.openmixer.org/deb/debian/trixie ./ Packages\n' ;;
  policy) echo ' 500 https://www.openmixer.org/deb/debian/trixie ./ Packages release o=OpenMixer' ;;
esac"
stub "$d/bin" gpg 'echo "pub   ed25519 2026-01-01"'
stub "$d/bin" curl "$curl_body"
PATH=$d/bin FREEREAC_RELEASE_URL=https://fr.example.org/deb/freereac-release.deb \
    bash "$d/check.sh" "$d/openmixer-release.pkg" probe-pkg > "$w/deb.log" 2>&1 || { cat "$w/deb.log"; fail "deb: the install check failed on the stubs"; }
grep -q 'install check: PASS' "$w/deb.log" || fail "deb: the install check did not reach its end: $(cat "$w/deb.log")"
! grep -qi freereac "$w/calls" || fail "deb: the install check reached the FreeREAC channel: $(grep -i freereac "$w/calls")"
! grep -q '^curl ' "$w/calls" || fail "deb: the install check fetched something for a local package: $(grep '^curl ' "$w/calls")"
first=$(grep -m1 '^apt-get install' "$w/calls")
[ "$first" = "apt-get install -y --no-install-recommends $d/openmixer-release.pkg" ] ||
    fail "deb: openmixer-release is not installed alone: '$first'"
echo "ok   deb: openmixer-release is installed alone, FREEREAC_RELEASE_URL is not read"
echo "install-check one channel: ok"
