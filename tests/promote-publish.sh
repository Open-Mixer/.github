#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A promotion on a stub channel (promote-staged.yml), through the scripts and action steps it runs: a staged publish as
# build-rpm.yml / build-deb.yml leave it, then collect.py, vouch.sh and the steps of publish-rpms / publish-debs with
# staging off. Proves:
#   - the channel root holds, for every release, the very bytes staging held (the staged checksums verify there), with
#     signed metadata, and the staging tree is byte-identical before and after;
#   - a client with the real channel alone installs the promoted version, and it is the staged build of the commit;
#   - vouch.sh refuses, naming the file: an RPM with no signature, an RPM signed by a key the channel does not serve,
#     a DEB whose bytes are not those of the signed staging index, any DEB once the staging index is altered, and
#     everything when the key file the channel serves is not one this repository pins.
# Runs as root in a throwaway Fedora (rpm) or Debian (deb) container: the client arm writes /etc.
#
#   promote-publish.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
actions=$root/.github/actions
collect=$actions/promote-staged/collect.py
vouch=$actions/promote-staged/vouch.sh
kind=${1:?usage: promote-publish.sh rpm|deb}
[ "$(id -u)" = 0 ] || { echo "promote-publish.sh writes /etc of a throwaway container: run it as root there" >&2; exit 2; }
work=$(mktemp -d)
chmod 755 "$work" # apt reads the repositories and the signed-by file as _apt
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Promote Test <promote@example.org>' ed25519 sign 1y
gpg --batch --quiet --passphrase '' --quick-gen-key 'Stranger <stranger@example.org>' ed25519 sign 1y
NEW_ID=$(gpg --with-colons --fingerprint promote@example.org | awk -F: '/^fpr:/ {print $10; exit}')
OTHER_ID=$(gpg --with-colons --fingerprint stranger@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$NEW_ID" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed

# the channel checkout as channel-pull leaves it: build/channel, with the site beside the trees
ws=$work/ws; ch=$ws/build/channel
mkdir -p "$ch/rpm" "$ch/deb"
echo '<html>site</html>' > "$ch/index.html"
staging_sum() { (cd "$ch" && find staging -type f -print0 | sort -z | xargs -0 sha256sum); }

# a step of an action, run as the runner would: its script with env names set by the caller
step() { # <action.yml> <name pattern> <out>
    python3 -I - "$@" <<'PY'
import re, sys, yaml
path, pat, out = sys.argv[1:4]
steps = yaml.safe_load(open(path))["runs"]["steps"]
hit = [s for s in steps if re.search(pat, s.get("name", ""))]
assert len(hit) == 1, f"{path}: {len(hit)} steps match {pat!r}"
open(out, "w").write(hit[0]["run"])
PY
}
envfile() { [ -f "$1" ] || return 0; while IFS= read -r l; do export "${l?}"; done < "$1"; }
act=$actions/publish-${kind}s/action.yml
step "$act" '^Prove the packages are there' "$work/first.sh"
step "$act" '^Assemble the tree' "$work/assemble.sh"
# the two steps of a publish: <staging true|false> <package dir> <log>
publish() {
    local staging=$1 dir=$2 log=$3
    unset RPM_TREE REPO_FILE SKELETON DEB_TREE LABEL REQUIRES_TREE
    : > "$work/env"
    if [ "$kind" = rpm ]; then
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms GITHUB_ENV=$work/env RPM_DIR=$dir STAGING=$staging RELEASES="44 45" \
            bash -e "$work/first.sh" >/dev/null)
        envfile "$work/env"
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms RPM_DIR=$dir SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID bash -e "$work/assemble.sh") > "$log" 2>&1
    else
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs GITHUB_ENV=$work/env DEB_DIR=$dir STAGING=$staging SUITES="bookworm trixie" \
            bash -e "$work/first.sh" >/dev/null)
        envfile "$work/env"
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$dir SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID REQUIRES=libmod-host-protocol0 \
            CHANGELOGS_URL=https://www.openmixer.org/deb/changelogs bash -e "$work/assemble.sh") > "$log" 2>&1
    fi
}
# vouch.sh must refuse <dir>, naming <pattern>
unvouched() { # <what> <pattern> <channel> <dir>
    if "$vouch" "$3" "$kind" "$4" > "$work/vouch.log" 2>&1; then fail "$1: vouched for"; fi
    grep -qE "$2" "$work/vouch.log" || fail "$1: refused without naming it: $(cat "$work/vouch.log")"
    ok "$kind: refused: $1"
}

case $kind in
rpm)
    mkpkg() { # <name> <version> <release> <out dir>: the noarch package and its source package
        local d=$work/rb-$1-$2-$3
        mkdir -p "$d" "$4"
        printf '%s\n' "Name: $1" "Version: $2" "Release: $3" 'Summary: t' 'License: MIT' 'BuildArch: noarch' '%description' 't' '%files' > "$d/p.spec"
        rpmbuild -ba --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2-$3"
        find "$d/RPMS" "$d/SRPMS" -name '*.rpm' -exec cp {} "$4/" \;
    }
    for rel in 44 45; do
        mkpkg omx-lib 3.13.0 "1.fc$rel" "$work/real"
        mkpkg omx-lib 3.14.0 "1.git5f455d3.fc$rel" "$work/staged"
    done
    "$actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/real" "$NEW_ID" >/dev/null
    collect_args=(rpm --name omx-lib --version 3.14.0 --releases "44 45" --arches "x86_64 aarch64")
    n=4
    ;;
deb)
    mkdeb() { # <name> <version> <out dir> [depends] [payload]
        local d=$work/db-$1-$2-${5:-0}
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1" "$3"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: amd64' 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
        [ -z "${4:-}" ] || echo "Depends: $4" >> "$d/DEBIAN/control"
        [ -z "${5:-}" ] || echo "$5" > "$d/usr/share/doc/$1/README"
        dpkg-deb --root-owner-group -b "$d" "$3/$1_$2_amd64.deb" >/dev/null
    }
    for suite in bookworm trixie; do
        mkdeb libmod-host-protocol0 0.10.11 "$work/real/$suite"
        mkdeb omx-lib 3.13.0 "$work/real/$suite"
        mkdeb omx-lib 3.14.0+git5f455d3 "$work/staged/$suite" libmod-host-protocol0
    done
    REQUIRES=libmod-host-protocol0 "$actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/real" "$NEW_ID" >/dev/null
    collect_args=(deb --name omx-lib --version 3.14.0 --releases "bookworm trixie" --arches amd64)
    n=2
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
publish true "$work/staged" "$work/staged.log" || { cat "$work/staged.log"; fail "the staged publish failed"; }
staging_sum > "$work/staging.before"
ok "$kind: a channel serving omx-lib 3.13.0, with 3.14.0 of 5f455d3 staged for every release"

# ---- collect and vouch
python3 -I "$collect" "$ch" "${collect_args[@]}" --out "$work/promo" > "$work/collect.log" 2>&1 || { cat "$work/collect.log"; fail "the collect failed"; }
[ "$(find "$work/promo" -name "*.$kind" | wc -l)" = "$n" ] || fail "collected $(find "$work/promo" -name "*.$kind" | wc -l) files, not $n"
"$vouch" "$ch" "$kind" "$work/promo" > "$work/vouch.log" 2>&1 || { cat "$work/vouch.log"; fail "the staged build is not vouched for"; }
[ "$(grep -c '^vouched ' "$work/vouch.log")" = "$n" ] || fail "not every file is vouched for: $(cat "$work/vouch.log")"
ok "$kind: the $n staged files are found and the channel's key vouches for each"

# ---- what the signature check refuses
if [ "$kind" = rpm ]; then
    mkpkg omx-lib 3.14.0 1.git0badc0d.fc44 "$work/unsigned"
    unvouched "an RPM with no signature" 'refused omx-lib-3.14.0-1.git0badc0d.fc44.noarch.rpm: not signed by a key the channel serves' "$ch" "$work/unsigned"
    mkpkg omx-lib 3.14.0 1.git0badc0d.fc45 "$work/stranger"
    for f in "$work/stranger"/*.rpm; do rpmsign --define "_gpg_name $OTHER_ID" --addsign "$f" >/dev/null 2>&1 || fail "rpmsign with the other key"; done
    unvouched "an RPM signed by a key the channel does not serve" 'refused omx-lib-3.14.0-1.git0badc0d.fc45.noarch.rpm: not signed by a key the channel serves' "$ch" "$work/stranger"
else
    mkdeb omx-lib 3.14.0+git5f455d3 "$work/planted/trixie" libmod-host-protocol0 planted
    unvouched "a DEB whose bytes are not those of the staging index" 'refused trixie/omx-lib_3.14.0\+git5f455d3_amd64.deb: not in the signed staging index of trixie' "$ch" "$work/planted"
    cp -a "$ch" "$work/altered"
    echo >> "$work/altered/staging/deb/debian/trixie/Packages"
    unvouched "a DEB once the staging index is altered" 'refused trixie/omx-lib_3.14.0\+git5f455d3_amd64.deb' "$work/altered" "$work/promo"
fi
printf '%s packages throwaway\n' "$OTHER_ID" > "$work/pinned-other.txt"
if PINNED_FINGERPRINTS=$work/pinned-other.txt "$vouch" "$ch" "$kind" "$work/promo" > "$work/vouch.log" 2>&1; then fail "a key file this repository does not pin vouched"; fi
grep -q 'not one this repository pins' "$work/vouch.log" || fail "the unpinned key file is not named: $(cat "$work/vouch.log")"
ok "$kind: refused: everything, when the channel's key file is not one this repository pins"

# ---- the promotion: the publish with staging off
publish false "$work/promo" "$work/promote.log" || { cat "$work/promote.log"; fail "the promotion publish failed"; }
(cd "$ch" && sha256sum -c --quiet "$work/promo.sha256") || fail "the channel root does not hold the bytes staging held"
staging_sum | cmp -s - "$work/staging.before" || fail "the promotion changed the staging tree: $(staging_sum | diff "$work/staging.before" - | head)"
if [ "$kind" = rpm ]; then
    for rel in 44 45; do for a in noarch SRPMS; do
        [ -s "$ch/rpm/fedora/$rel/$a/repodata/repomd.xml.asc" ] || fail "no signed metadata in rpm/fedora/$rel/$a"
        while IFS= read -r f; do cmp -s "$f" "$ch/staging/rpm/fedora/$rel/$a/$(basename "$f")" || fail "$(basename "$f") differs from the staged file"
        done < <(find "$ch/rpm/fedora/$rel/$a" -name 'omx-lib-3.14.0-*.rpm')
    done; done
else
    for suite in bookworm trixie; do
        grep -q 'omx-lib_3.14.0+git5f455d3_amd64.deb' "$ch/deb/debian/$suite/Packages" || fail "deb/debian/$suite does not index the promoted package"
        [ -s "$ch/deb/debian/$suite/InRelease" ] || fail "no signed index for deb/debian/$suite"
    done
fi
ok "$kind: the channel root holds the staged bytes for every release, indexed and signed; staging is as it was"

# ---- a client with the real channel alone
# the real channel alone: nothing an earlier test of this container left (a staging source, an installed omx-lib)
if [ "$kind" = rpm ]; then
    rm -f /etc/yum.repos.d/openmixer*.repo
    if rpm -q omx-app >/dev/null 2>&1; then rpm -e omx-app; fi
    if rpm -q omx-lib >/dev/null 2>&1; then rpm -e omx-lib; fi
else
    rm -f /etc/apt/sources.list.d/openmixer*.sources /etc/apt/preferences.d/openmixer*.pref
    for p in omx-app omx-lib; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed'; then dpkg --purge "$p" >/dev/null; fi
    done
fi
base=file://$ch
if [ "$kind" = rpm ]; then
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    q() { dnf -q -y --disablerepo='*' --enablerepo='openmixer*' "$@"; }
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null
    q install omx-lib-3.14.0 >/dev/null
    got=$(rpm -q --qf '%{VERSION}-%{RELEASE}' omx-lib); repo=$(dnf -q repoquery --installed --qf '%{from_repo}' omx-lib)
    rel=$(rpm -E %fedora)
    [ "$got" = "3.14.0-1.git5f455d3.fc$rel" ] || fail "the client took omx-lib $got, not the promoted 3.14.0-1.git5f455d3.fc$rel"
    case $repo in openmixer-staging*) fail "the promoted omx-lib came from $repo" ;; esac
else
    install -D -m 644 "$ch/deb/openmixer.asc" /usr/share/keyrings/openmixer-archive-keyring.asc
    suite=$(. /etc/os-release && echo "$VERSION_CODENAME")
    sed -e "s|@SUITE@|$suite|" -e "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/debian/openmixer.sources.in" \
        > /etc/apt/sources.list.d/openmixer.sources
    apt-get update -qq -o APT::Update::Error-Mode=any
    pinned=$(apt-cache madison omx-lib | awk -v v="3.14.0+git5f455d3" 'index($3, v) == 1 {print $3; exit}')
    [ -n "$pinned" ] || fail "the channel root does not offer omx-lib 3.14.0+git5f455d3: $(apt-cache madison omx-lib)"
    apt-get install -y -qq --no-install-recommends "omx-lib=$pinned" >/dev/null
    [ "$(dpkg-query -W -f='${Version}' omx-lib)" = 3.14.0+git5f455d3 ] || fail "apt installed another omx-lib"
fi
ok "$kind: a client with the real channel alone installs the promoted version, the staged build of 5f455d3"
rm -rf "$work"
echo "promote-publish $kind: all passed"
