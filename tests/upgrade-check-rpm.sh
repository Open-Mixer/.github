#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The upgrade arm of the release install check (.github/actions/upgrade-check/upgrade-rpm.sh) with real dnf, on a
# throwaway channel of packages built here. The channel serves omxfix 1.0 (omxfix, omxfix-core-data owning
# /usr/share/omxfix-data/x.json, and omxfix-extra) and 1.1; omxfix requires its data package at its own version.
# The arms:
#   - 2.0 renames omxfix-core-data to omxfix-data WITH `Obsoletes: omxfix-core-data < 2.0` and obsoletes
#     omxfix-extra, which it drops: GREEN, from 1.1 and from 1.0;
#   - the same 2.0 without the rename's Obsoletes (omx-clap-core 0.34.0): RED, the file conflict named;
#   - 2.0 that keeps the rename's Obsoletes but drops omxfix-extra with none: RED, omxfix-extra named as left behind;
#   - a first release, nothing served: a notice, exit 0;
#   - with <back> 1 only 1.1 is checked, with 2 both.
# Runs as root in a throwaway Fedora container (it rewrites /etc/yum.repos.d and installs into it), with rpm-build and
# createrepo_c installed.
#
#   upgrade-check-rpm.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
gate=$here/.github/actions/upgrade-check/upgrade-rpm.sh
[ "$(id -u)" = 0 ] || { echo "upgrade-check-rpm.sh installs packages into a throwaway container: run it as root there" >&2; exit 2; }
t=$(mktemp -d); trap 'rm -rf "$t" /etc/yum.repos.d/fixchan.repo' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

# build <version> <variant> <out dir>: variant old (1.x names), renamed (2.0 with every Obsoletes), no-obsoletes,
# drops-extra (the rename's Obsoletes, none for the dropped omxfix-extra)
build() {
    local v=$1 variant=$2 out=$3 spec data=omxfix-data obs=
    spec=$t/omxfix-$v-$variant.spec
    mkdir -p "$out"
    case $variant in
        old) data=omxfix-core-data ;;
        renamed) obs=$'Obsoletes: omxfix-core-data < 2.0\nObsoletes: omxfix-extra < 2.0' ;;
        no-obsoletes) obs='' ;;
        drops-extra) obs='Obsoletes: omxfix-core-data < 2.0' ;;
    esac
    {
        printf 'Name: omxfix\nVersion: %s\nRelease: 1\nSummary: fixture\nLicense: GPL-3.0-or-later\nBuildArch: noarch\n' "$v"
        printf 'Requires: %s = %%{version}-%%{release}\n%%description\nfixture\n' "$data"
        printf '%%package -n %s\nSummary: fixture data\n%s\n%%description -n %s\nfixture\n' "$data" "$obs" "$data"
        [ "$variant" != old ] || printf '%%package extra\nSummary: fixture extra\n%%description extra\nfixture\n'
        printf '%%install\nmkdir -p %%{buildroot}/usr/share/omxfix %%{buildroot}/usr/share/omxfix-data\n'
        printf 'echo %s > %%{buildroot}/usr/share/omxfix/bin\necho %s > %%{buildroot}/usr/share/omxfix-data/x.json\n' "$v" "$v"
        [ "$variant" != old ] || printf 'echo %s > %%{buildroot}/usr/share/omxfix/extra\n' "$v"
        printf '%%files\n/usr/share/omxfix/bin\n%%files -n %s\n/usr/share/omxfix-data/x.json\n' "$data"
        [ "$variant" != old ] || printf '%%files extra\n/usr/share/omxfix/extra\n'
    } > "$spec"
    rpmbuild -bb --quiet --define "_topdir $t/rpmbuild" --define "_rpmdir $out" --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$spec" >/dev/null 2>&1 \
        || { rpmbuild -bb --define "_topdir $t/rpmbuild" --define "_rpmdir $out" "$spec"; fail "the fixture $v $variant does not build"; }
}

chan=$t/chan
build 1.0 old "$chan"
build 1.1 old "$chan"
createrepo_c -q "$chan"
printf '[fixchan]\nname=fixture channel\nbaseurl=file://%s\ngpgcheck=0\n' "$chan" > /etc/yum.repos.d/fixchan.repo
dnf -y -q makecache --repo fixchan >/dev/null

run() { # <candidate dir> [<back>]: the gate's exit status, its output in $t/out
    set +e; bash "$gate" "$1" fixchan "${2:-2}" > "$t/out" 2>&1; local rc=$?; set -e
    rpm -qa 'omxfix*' | grep -q . && fail "the gate left omxfix packages installed: $(rpm -qa 'omxfix*' | tr '\n' ' ')"
    return $rc
}

build 2.0 renamed "$t/good"
run "$t/good" || { cat "$t/out"; fail "2.0 with the rename's Obsoletes did not upgrade cleanly"; }
if ! grep -q '^ok   omxfix 1.1-1 -> 2.0-1' "$t/out" || ! grep -q '^ok   omxfix 1.0-1 -> 2.0-1' "$t/out"; then
    cat "$t/out"; fail "the green arm did not check both 1.0 and 1.1"
fi
ok "a rename with Obsoletes upgrades from 1.0 and 1.1 in one transaction, nothing left behind"

run "$t/good" 1 || { cat "$t/out"; fail "back 1 went red"; }
grep -q '1.0-1 ->' "$t/out" && { cat "$t/out"; fail "back 1 checked 1.0 too"; }
grep -q '^ok   omxfix 1.1-1 -> 2.0-1' "$t/out" || { cat "$t/out"; fail "back 1 did not check 1.1"; }
ok "back 1 checks the newest served version alone"

build 2.0 no-obsoletes "$t/bad"
if run "$t/bad"; then cat "$t/out"; fail "a rename with no Obsoletes went green"; fi
grep -q '::error::upgrade from omxfix 1.1-1 to 2.0-1 fails:.*conflicts' "$t/out" || { cat "$t/out"; fail "the red did not name the file conflict"; }
ok "a rename with no Obsoletes is red, the conflict named (the omx-clap-core 0.34.0 defect)"

build 2.0 drops-extra "$t/drop"
if run "$t/drop"; then cat "$t/out"; fail "a dropped package with no Obsoletes went green"; fi
grep -q '::error::upgrade from omxfix 1.1-1 to 2.0-1 leaves omxfix-extra-1.1-1.noarch installed' "$t/out" \
    || { cat "$t/out"; fail "the red did not name omxfix-extra as left behind"; }
ok "a package dropped with no Obsoletes is red, named as left behind"

build 1.0 renamed "$t/first"
sed -i 's/^Name: omxfix$/Name: omxnew/' "$t"/omxfix-1.0-renamed.spec
rm -rf "$t/first"; mkdir "$t/first"
rpmbuild -bb --quiet --define "_topdir $t/rpmbuild" --define "_rpmdir $t/first" --define '_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm' "$t"/omxfix-1.0-renamed.spec >/dev/null 2>&1
run "$t/first" || { cat "$t/out"; fail "a first release went red"; }
grep -q '::notice::upgrade-rpm: fixchan serves no omxnew below 1.0-1' "$t/out" || { cat "$t/out"; fail "a first release did not say there was nothing to check"; }
ok "a first release, nothing served: a notice"
