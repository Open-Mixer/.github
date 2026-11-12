#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A staged publish and the purge on a stub channel, through the steps of publish-rpms / publish-debs as they run with
# staging on, the purge-staging script, and a client that adds the channel with add-staging.sh. Proves:
#   - the staged package lands under staging/<kind>, signed, with signed metadata for every release of the skeleton
#     (one that holds nothing too), the staging repository file (rpm) or the staging label (deb);
#   - the real tree, rpm/ and deb/, and the site beside them are byte-identical before and after the staged publish,
#     its lost-race rebuild and the purge;
#   - a deb staging publish whose `requires` only the real tree serves is accepted, and refused when neither does;
#   - a client with the staging channel added takes the staged build even where the real channel has a higher
#     version (priority 10, pin 600), and the real one without it; after the purge it takes the real one again, and
#     the empty staging index still loads;
#   - a later commit of the same version, staged after: its build sorts above the earlier commit's although its sha
#     sorts below (the commit time comes first in the name), a client takes it even while the index holds both, and the
#     staged publish drops the earlier build, so the staging channel holds one build of a version;
#   - add-staging.sh refuses a machine without the real channel.
# Runs as root in a throwaway Fedora (rpm) or Debian (deb) container: the client arm writes /etc.
#
#   staging-publish.sh rpm|deb     NEW_ID in the environment names a signing key of the keyring; without it a
#                                  throwaway key is made in a keyring of its own
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
actions=$root/.github/actions
kind=${1:?usage: staging-publish.sh rpm|deb}
[ "$(id -u)" = 0 ] || { echo "staging-publish.sh writes /etc of a throwaway container: run it as root there" >&2; exit 2; }
work=$(mktemp -d)
chmod 755 "$work" # apt reads the repositories and the signed-by file as _apt
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
# two staged commits of one version, as build-rpm.sh and build-deb.sh name them, <commit time>.<short sha>: B is an
# hour later than A and its sha sorts below A's, the case a name made of the sha alone gets wrong
A=1794480000.99c23a5
B=1794483600.15b5e63

if [ -z "${NEW_ID:-}" ]; then
    export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'Staging Test <staging@example.org>' ed25519 sign 1y
    NEW_ID=$(gpg --with-colons --fingerprint staging@example.org | awk -F: '/^fpr:/ {print $10; exit}')
fi
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$NEW_ID" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed

# the channel checkout as channel-pull leaves it: build/channel, a git repository with the site beside the trees
ws=$work/ws; ch=$ws/build/channel
mkdir -p "$ch/rpm" "$ch/deb" "$ch/docs"
echo '<html>site</html>' > "$ch/index.html"; echo 'manual' > "$ch/docs/index.html"
# every file of the channel outside staging/ (and git's own): the real trees, the keys, the site
real_sum() { (cd "$ch" && find . \( -path ./staging -o -path ./.git \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }

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
# the lost-race rebuild channel-push runs, with the action's inputs written in
rebuild() { # <action.yml> <input=value>...
    python3 -I - "$@" <<'PY'
import re, sys, yaml
path, kv = sys.argv[1], dict(a.split("=", 1) for a in sys.argv[2:])
steps = yaml.safe_load(open(path))["runs"]["steps"]
r = [s for s in steps if "/actions/channel-push@" in s.get("uses", "")][0]["with"]["rebuild"]
print(re.sub(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", lambda m: kv[m.group(1)], r))
PY
}
envfile() { [ -f "$1" ] || return 0; while IFS= read -r l; do export "${l?}"; done < "$1"; }

case $kind in
rpm)
    mkpkg() { # <name> <version> <release> [requires]
        local d=$work/rb-$1-$2-$3
        mkdir -p "$d"
        { printf '%s\n' "Name: $1" "Version: $2" "Release: $3" 'Summary: t' 'License: MIT' 'BuildArch: noarch'
          [ -z "${4:-}" ] || echo "Requires: $4"
          printf '%s\n' '%description' 't' '%files'; } > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2"
        find "$d/RPMS" -name '*.rpm'
    }
    mkdir -p "$work/real" "$work/staged"
    cp "$(mkpkg omx-lib 3.13.0 1.fc44)" "$(mkpkg omx-lib 3.14.1 1.fc44)" "$(mkpkg omx-app 1.0 1.fc44 'omx-lib >= 3.13')" "$work/real/"
    cp "$(mkpkg omx-lib 3.14.0 1.git$A.fc44)" "$work/staged/"
    "$actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/real" "$NEW_ID" >/dev/null
    ;;
deb)
    mkdeb() { # <name> <version> [depends]
        local d=$work/db-$1-$2
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: amd64' 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
        [ -z "${3:-}" ] || echo "Depends: $3" >> "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$work/$1_$2_amd64.deb" >/dev/null
        echo "$work/$1_$2_amd64.deb"
    }
    mkdir -p "$work/real/trixie" "$work/staged/trixie"
    cp "$(mkdeb libmod-host-protocol0 0.10.11)" "$(mkdeb omx-lib 3.13.0)" "$(mkdeb omx-lib 3.14.1)" "$work/real/trixie/"
    cp "$(mkdeb omx-lib 3.14.0+git$A libmod-host-protocol0)" "$work/staged/trixie/"
    REQUIRES=libmod-host-protocol0 "$actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/real" "$NEW_ID" >/dev/null
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
(cd "$ch" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.org commit -qm real)
real_sum > "$work/real.before"
ok "$kind: a real channel with omx-lib 3.13.0 and 3.14.1"

# ---- the staged publish, through the action's own steps
act=$actions/publish-${kind}s/action.yml
step "$act" '^Prove the packages are there' "$work/first.sh"
step "$act" '^Assemble the tree' "$work/assemble.sh"
: > "$work/env"
if [ "$kind" = rpm ]; then
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms GITHUB_ENV=$work/env RPM_DIR=$work/staged STAGING=true RELEASES="44 45" \
        bash -e "$work/first.sh" >/dev/null)
    envfile "$work/env"
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms RPM_DIR=$work/staged SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID \
        bash -e "$work/assemble.sh") > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; fail "the staged rpm publish failed"; }
    s=$ch/staging/rpm
    f=$s/fedora/44/noarch/omx-lib-3.14.0-1.git$A.fc44.noarch.rpm
    [ -f "$f" ] || fail "the staged package is not at staging/rpm/fedora/44/noarch: $(cd "$ch" && find staging -name '*.rpm')"
    rpm -qpi "$f" 2>/dev/null | grep -E '^Signature *:' | grep -qiv '(none)' || fail "the staged package is not signed"
    for rel in 44 45; do for a in x86_64 aarch64 noarch SRPMS; do
        [ -s "$s/fedora/$rel/$a/repodata/repomd.xml.asc" ] || fail "no signed metadata in staging/rpm/fedora/$rel/$a"
    done; done
    cmp "$s/openmixer-staging.repo" "$root/packaging/staging/openmixer-staging.repo" || fail "the staging tree does not serve openmixer-staging.repo"
    [ ! -e "$s/openmixer.repo" ] || fail "the staging tree serves the real channel's repository file"
    [ -s "$s/RPM-GPG-KEY-openmixer" ] || fail "the staging tree serves no key"
    cmd=$(rebuild "$act" rpm-dir="$work/staged")
else
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs GITHUB_ENV=$work/env DEB_DIR=$work/staged STAGING=true SUITES="bookworm trixie" \
        bash -e "$work/first.sh" >/dev/null)
    envfile "$work/env"
    # a requires package neither tree serves is refused; one only the real tree serves is accepted
    if (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$work/staged SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID \
        REQUIRES=libnothing0 CHANGELOGS_URL= bash -e "$work/assemble.sh") > "$work/refused.log" 2>&1; then
        fail "a staged deb publish whose requires no tree serves passed"
    fi
    grep -q 'holds no libnothing0' "$work/refused.log" || fail "the missing requires is not named: $(cat "$work/refused.log")"
    (cd "$ch" && git checkout -q -- . && git clean -qfdx)
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$work/staged SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID \
        REQUIRES=libmod-host-protocol0 CHANGELOGS_URL=https://www.openmixer.org/staging/deb/changelogs bash -e "$work/assemble.sh") \
        > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; fail "the staged deb publish failed"; }
    s=$ch/staging/deb
    [ -f "$s/debian/trixie/amd64/omx-lib_3.14.0+git${A}_amd64.deb" ] || fail "the staged package is not at staging/deb/debian/trixie/amd64"
    for suite in bookworm trixie; do
        [ -s "$s/debian/$suite/InRelease" ] || fail "no signed index for staging/deb/debian/$suite"
        grep -qx 'Label: OpenMixer-Staging' "$s/debian/$suite/InRelease" || fail "staging/deb/debian/$suite is not labelled OpenMixer-Staging"
    done
    [ -s "$s/openmixer.asc" ] || fail "the staging tree serves no key"
    cmd=$(rebuild "$act" requires=libmod-host-protocol0 changelogs-url=https://www.openmixer.org/staging/deb/changelogs deb-dir="$work/staged")
fi
real_sum | cmp -s - "$work/real.before" || fail "the staged publish changed the real tree: $(real_sum | diff "$work/real.before" - | head)"
ok "$kind: the staged publish lands under staging/$kind, signed, with every release of the skeleton indexed"

# a lost race: channel-push resets to the new tip and runs the rebuild; nothing changes in the real tree, and the
# staged files are kept as they are
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org commit -qm staged)
staged_rev=$(cd "$ch" && git rev-parse HEAD)
(cd "$ws" && env PUBLISH_RPMS_ACTION="$actions/publish-rpms" PUBLISH_DEBS_ACTION="$actions/publish-debs" OPENMIXER_GPG_KEY_ID="$NEW_ID" \
    bash -c "$cmd") > "$work/rebuild.log" 2>&1 || { cat "$work/rebuild.log"; fail "the lost-race rebuild failed"; }
real_sum | cmp -s - "$work/real.before" || fail "the rebuild changed the real tree"
[ -z "$(cd "$ch" && git status --porcelain -- . ':(exclude)staging')" ] || fail "the rebuild wrote outside staging/"
[ -z "$(cd "$ch" && git status --porcelain -- "staging/$kind" | grep -E '\.(rpm|deb)$')" ] || fail "the rebuild changed a staged package"
ok "$kind: the lost-race rebuild assembles staging/$kind again and nothing else"

# ---- a client: the real channel, then the staging channel beside it
base=file://$ch
err=$(BASE_URL=$base "$actions/add-openmixer/add-staging.sh" 2>&1) && fail "add-staging.sh added staging with no real channel"
echo "$err" | grep -q 'never alone' || fail "add-staging.sh does not say why: $err"
if [ "$kind" = rpm ]; then
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    q() { dnf -q -y --disablerepo='*' --enablerepo='openmixer*' "$@"; }
    BASE_URL=$base "$actions/add-openmixer/add-staging.sh" >/dev/null
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null
    q install omx-app >/dev/null
    got=$(rpm -q --qf '%{VERSION}-%{RELEASE}' omx-lib); repo=$(dnf -q repoquery --installed --qf '%{from_repo}' omx-lib)
    [ "$got" = 3.14.0-1.git$A.fc44 ] || fail "with staging the client took omx-lib $got, not the staged 3.14.0-1.git$A"
    case $repo in openmixer-staging*) ;; *) fail "the staged omx-lib came from $repo" ;; esac
    q remove omx-app omx-lib >/dev/null
    mv /etc/yum.repos.d/openmixer-staging.repo "$work/"
    q makecache --refresh >/dev/null; q install omx-lib >/dev/null
    [ "$(rpm -q --qf '%{VERSION}' omx-lib)" = 3.14.1 ] || fail "without staging the client took omx-lib $(rpm -q --qf '%{VERSION}' omx-lib), not the real 3.14.1"
    q remove omx-lib >/dev/null
    mv "$work/openmixer-staging.repo" /etc/yum.repos.d/
else
    install -D -m 644 "$ch/deb/openmixer.asc" /usr/share/keyrings/openmixer-archive-keyring.asc
    sed -e 's|@SUITE@|trixie|' -e "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/debian/openmixer.sources.in" \
        > /etc/apt/sources.list.d/openmixer.sources
    BASE_URL=$base SUITE=trixie "$actions/add-openmixer/add-staging.sh" >/dev/null
    apt-get update -qq -o APT::Update::Error-Mode=any
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.0+git$A ] || fail "with staging the candidate is omx-lib $cand, not the staged 3.14.0+git$A: $(apt-cache policy omx-lib)"
    apt-cache policy omx-lib | grep -A1 "3.14.0+git$A" | grep -q '^ *600 .*staging/deb' || fail "the staged build is not pinned 600: $(apt-cache policy omx-lib)"
    apt-get install -y -qq --no-install-recommends omx-lib >/dev/null
    [ "$(dpkg-query -W -f='${Version}' omx-lib)" = 3.14.0+git$A ] || fail "with staging apt installed another omx-lib"
    apt-get purge -y -qq omx-lib libmod-host-protocol0 >/dev/null
    mv /etc/apt/preferences.d/openmixer-staging.pref /etc/apt/sources.list.d/openmixer-staging.sources "$work/"
    apt-get update -qq
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.1 ] || fail "without staging the candidate is omx-lib $cand, not the real 3.14.1"
    mv "$work/openmixer-staging.pref" /etc/apt/preferences.d/; mv "$work/openmixer-staging.sources" /etc/apt/sources.list.d/
fi
ok "$kind: a client with staging added takes the staged build over a higher real version, and the real one without it"

# ---- a later commit of the same version is staged
mkdir -p "$work/staged-b"
if [ "$kind" = rpm ]; then
    cmpv() { rpm --eval "%{lua:print(rpm.vercmp('$1', '$2'))}"; }
    [ "$(cmpv "1.git$B.fc44" "1.git$A.fc44")" = 1 ] || fail "the later commit's release 1.git$B does not sort above 1.git$A"
    [ "$(cmpv "1.git${B#*.}.fc44" "1.git${A#*.}.fc44")" = -1 ] || fail "the two shas alone sort by time: this is not the case under test"
    cp "$(mkpkg omx-lib 3.14.0 "1.git$B.fc44")" "$work/staged-b/"
    old=$s/fedora/44/noarch/omx-lib-3.14.0-1.git$A.fc44.noarch.rpm
    new=$s/fedora/44/noarch/omx-lib-3.14.0-1.git$B.fc44.noarch.rpm
    taken() { q makecache --refresh >/dev/null; q install omx-lib >/dev/null; rpm -q --qf '%{VERSION}-%{RELEASE}' omx-lib; q remove omx-lib >/dev/null; }
    want=3.14.0-1.git$B.fc44
    # both builds in the index, as a publish that drops nothing leaves them: the order alone decides
    (cd "$ws" && NEWEST_ONLY='' "$actions/publish-rpms/publish-tree.sh" "$s" "$work/staged-b" "$NEW_ID") > "$work/both.log" 2>&1 || { cat "$work/both.log"; fail "the publish of the later commit failed"; }
    [ -f "$old" ] && [ -f "$new" ] || fail "without NEWEST_ONLY a publish removed a package"
    got=$(taken); [ "$got" = "$want" ] || fail "with both builds served the client took omx-lib $got, not the later commit's $want"
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms RPM_DIR=$work/staged-b SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID \
        bash -e "$work/assemble.sh") > "$work/publish-b.log" 2>&1 || { cat "$work/publish-b.log"; fail "the staged publish of the later commit failed"; }
else
    dpkg --compare-versions "3.14.0+git$B" gt "3.14.0+git$A" || fail "the later commit's 3.14.0+git$B does not sort above 3.14.0+git$A"
    dpkg --compare-versions "3.14.0+git${B#*.}" lt "3.14.0+git${A#*.}" || fail "the two shas alone sort by time: this is not the case under test"
    mkdir -p "$work/staged-b/trixie"
    cp "$(mkdeb omx-lib "3.14.0+git$B" libmod-host-protocol0)" "$work/staged-b/trixie/"
    old=$s/debian/trixie/amd64/omx-lib_3.14.0+git${A}_amd64.deb
    new=$s/debian/trixie/amd64/omx-lib_3.14.0+git${B}_amd64.deb
    taken() { apt-get update -qq -o APT::Update::Error-Mode=any; apt-cache policy omx-lib | awk '/Candidate:/ {print $2}'; }
    want=3.14.0+git$B
    (cd "$ws" && NEWEST_ONLY='' REQUIRES=libmod-host-protocol0 CHANGELOGS_URL=https://www.openmixer.org/staging/deb/changelogs \
        "$actions/publish-debs/publish-tree.sh" "$s" "$work/staged-b" "$NEW_ID") > "$work/both.log" 2>&1 || { cat "$work/both.log"; fail "the publish of the later commit failed"; }
    [ -f "$old" ] && [ -f "$new" ] || fail "without NEWEST_ONLY a publish removed a package"
    got=$(taken); [ "$got" = "$want" ] || fail "with both builds served the candidate is omx-lib $got, not the later commit's $want"
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$work/staged-b SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID \
        REQUIRES=libmod-host-protocol0 CHANGELOGS_URL=https://www.openmixer.org/staging/deb/changelogs bash -e "$work/assemble.sh") \
        > "$work/publish-b.log" 2>&1 || { cat "$work/publish-b.log"; fail "the staged publish of the later commit failed"; }
fi
[ -f "$new" ] || fail "the staged publish lost the later commit's build"
[ ! -e "$old" ] || fail "the staged publish left the earlier commit's build beside the later one: $(ls "$(dirname "$old")")"
grep -q "^dropped $(basename "$old") " "$work/publish-b.log" || fail "the staged publish does not say what it dropped: $(cat "$work/publish-b.log")"
got=$(taken); [ "$got" = "$want" ] || fail "after the staged publish of the later commit the client took omx-lib $got, not $want"
real_sum | cmp -s - "$work/real.before" || fail "the staged publish of the later commit changed the real tree"
ok "$kind: the build of a later commit sorts above the earlier one's whatever the shas, and staging keeps that build alone"

# ---- the purge
(cd "$ch" && git checkout -q -- . && git clean -qfdx && [ "$(git rev-parse HEAD)" = "$staged_rev" ])
if [ "$kind" = rpm ]; then sk="44 45"; else sk="bookworm trixie"; fi
SKELETON=$sk "$actions/purge-staging/purge-staging.sh" "$kind" "$ch" "$NEW_ID" > "$work/purge.log" 2>&1 || { cat "$work/purge.log"; fail "the purge failed"; }
real_sum | cmp -s - "$work/real.before" || fail "the purge changed the real tree: $(real_sum | diff "$work/real.before" - | head)"
[ -z "$(cd "$ch" && git status --porcelain --untracked-files=all -- . ":(exclude)staging/$kind")" ] || fail "the purge wrote outside staging/$kind"
[ -z "$(find "$ch/staging/$kind" -name "*.$kind")" ] || fail "the purge left packages: $(find "$ch/staging/$kind" -name "*.$kind")"
if [ "$kind" = rpm ]; then
    for rel in 44 45; do for a in x86_64 aarch64 noarch SRPMS; do
        [ -s "$ch/staging/rpm/fedora/$rel/$a/repodata/repomd.xml.asc" ] || fail "the purge left staging/rpm/fedora/$rel/$a without signed metadata"
    done; done
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null || fail "the empty staging channel does not load"
    q install omx-lib >/dev/null
    [ "$(rpm -q --qf '%{VERSION}' omx-lib)" = 3.14.1 ] || fail "after the purge the client took omx-lib $(rpm -q --qf '%{VERSION}' omx-lib)"
else
    for suite in bookworm trixie; do
        grep -qx 'Label: OpenMixer-Staging' "$ch/staging/deb/debian/$suite/InRelease" || fail "the purged index of $suite is not signed and labelled"
    done
    [ ! -e "$ch/staging/deb/changelogs" ] || fail "the purge left the staged changelogs"
    apt-get update -qq -o APT::Update::Error-Mode=any || fail "the empty staging channel does not load"
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.1 ] || fail "after the purge the candidate is omx-lib $cand"
fi
ok "$kind: the purge empties staging/$kind, keeps its index loadable and signed, and leaves the real tree byte-identical"

# a purge of a channel that never had a staging tree makes the empty one
rm -rf "$ch/staging"
SKELETON=$sk "$actions/purge-staging/purge-staging.sh" "$kind" "$ch" > "$work/purge2.log" 2>&1 || { cat "$work/purge2.log"; fail "the purge of a channel without staging failed"; }
real_sum | cmp -s - "$work/real.before" || fail "the purge of a fresh staging tree changed the real tree"
ok "$kind: a purge where nothing was staged leaves an empty index, and the real tree as it was"
rm -rf "$work"
echo "staging-publish $kind: all passed"
