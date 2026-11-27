#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A wave's devel channel (docs/release-operations.md, "The three channel levels") on a stub channel that holds a real
# tree, a staging tree and another wave's devel tree, through the steps of publish-rpms / publish-debs as they run with
# channel-level devel/wave-a, and a client that adds it with add-staging.sh LEVEL=devel/wave-a. Proves:
#   - the publish writes NOTHING outside devel/wave-a/<kind>: every other file of the channel (rpm/, deb/, staging/, the
#     other wave's devel/wave-b/, the site) is byte-identical after the publish and after its lost-race rebuild, and git
#     sees no change outside it;
#   - the package lands under devel/wave-a/<kind>, signed, with signed metadata for every release of the skeleton, the
#     tree's own cells.tsv naming the wave's package alone (staging's cells.tsv unchanged), and the tree's own repository
#     file (rpm: openmixer-devel.repo with the wave written in) or label (deb: OpenMixer-Devel);
#   - a level that is not devel/[a-z0-9-]+ (devel/../rpm, devel/, staging) is refused by the first step, naming it;
#   - a client with the real channel, staging and wave-a's devel channel takes wave-a's build over staging's (priority 5
#     over 10, pin 650 over 600) and never wave-b's higher one; without the devel channel it takes staging's again;
#   - add-staging.sh with a wave never published adds nothing and says so (a wave's first line).
# Sabotage: channel-level.sh joining the devel tree without its devel/<wave>/ prefix makes the first arm red.
# Runs as root in a throwaway Fedora (rpm) or Debian (deb) container: the client arm writes /etc.
#
#   devel-channel-publish.sh rpm|deb     NEW_ID names a signing key of the keyring; without it a throwaway key is made
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
actions=$root/.github/actions
kind=${1:?usage: devel-channel-publish.sh rpm|deb}
[ "$(id -u)" = 0 ] || { echo "devel-channel-publish.sh writes /etc of a throwaway container: run it as root there" >&2; exit 2; }
work=$(mktemp -d)
chmod 755 "$work" # apt reads the repositories and the signed-by file as _apt
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
if [ -z "${NEW_ID:-}" ]; then
    export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'Devel Test <devel@example.org>' ed25519 sign 1y
    NEW_ID=$(gpg --with-colons --fingerprint devel@example.org | awk -F: '/^fpr:/ {print $10; exit}')
fi
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$NEW_ID" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed

ws=$work/ws; ch=$ws/build/channel
mkdir -p "$ch/rpm" "$ch/deb" "$ch/docs"
echo '<html>site</html>' > "$ch/index.html"; echo 'manual' > "$ch/docs/index.html"
# every file of the channel outside the wave's tree (and git's own)
outside_sum() { (cd "$ch" && find . \( -path ./devel/wave-a -o -path ./.git \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }

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
rebuild() { # <action.yml> <push id> <input=value>...: the lost-race rebuild of that push, the inputs written in
    python3 -I - "$@" <<'PY'
import re, sys, yaml
path, pid, kv = sys.argv[1], sys.argv[2], dict(a.split("=", 1) for a in sys.argv[3:])
steps = yaml.safe_load(open(path))["runs"]["steps"]
r = [s for s in steps if s.get("id") == pid][0]["with"]["rebuild"]
print(re.sub(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", lambda m: kv[m.group(1)], r))
PY
}
envfile() { [ -f "$1" ] || return 0; while IFS= read -r l; do export "${l?}"; done < "$1"; }

case $kind in
rpm)
    mkpkg() { # <name> <version> <release>
        local d=$work/rb-$1-$2-$3
        mkdir -p "$d"
        printf '%s\n' "Name: $1" "Version: $2" "Release: $3" 'Summary: t' 'License: MIT' 'BuildArch: noarch' '%description' 't' '%files' > "$d/p.spec"
        rpmbuild -bb --quiet --define "_topdir $d" "$d/p.spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2"
        find "$d/RPMS" -name '*.rpm'
    }
    mkdir -p "$work/real" "$work/staged" "$work/wave-b" "$work/wave-a"
    cp "$(mkpkg omx-lib 3.13.0 1.fc45)" "$work/real/"
    cp "$(mkpkg omx-lib 3.14.0 1.fc45)" "$work/staged/"
    cp "$(mkpkg omx-lib 3.16.0 1.fc45)" "$work/wave-b/"
    cp "$(mkpkg omx-lib 3.15.0 1.fc45)" "$work/wave-a/"
    pt=$actions/publish-rpms/publish-tree.sh
    "$pt" "$ch/rpm" "$work/real" "$NEW_ID" >/dev/null
    REPO_FILE=$root/packaging/staging/openmixer-staging.repo MATRIX_SET=quick "$pt" "$ch/staging/rpm" "$work/staged" "$NEW_ID" >/dev/null
    REPO_FILE=$("$actions/publish-rpms/channel-level.sh" repo-file devel/wave-b "$work/repo-b") MATRIX_SET=quick "$pt" "$ch/devel/wave-b/rpm" "$work/wave-b" "$NEW_ID" >/dev/null
    ;;
deb)
    mkdeb() { # <name> <version>
        local d=$work/db-$1-$2
        mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$1"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: all' 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$work/$1_$2_all.deb" >/dev/null
        echo "$work/$1_$2_all.deb"
    }
    mkdir -p "$work/real/trixie" "$work/staged/trixie" "$work/wave-b/trixie" "$work/wave-a/trixie"
    cp "$(mkdeb omx-lib 3.13.0)" "$work/real/trixie/"
    cp "$(mkdeb omx-lib 3.14.0)" "$work/staged/trixie/"
    cp "$(mkdeb omx-lib 3.16.0)" "$work/wave-b/trixie/"
    cp "$(mkdeb omx-lib 3.15.0)" "$work/wave-a/trixie/"
    pt=$actions/publish-debs/publish-tree.sh
    "$pt" "$ch/deb" "$work/real" "$NEW_ID" >/dev/null
    LABEL=OpenMixer-Staging MATRIX_SET=quick "$pt" "$ch/staging/deb" "$work/staged" "$NEW_ID" >/dev/null
    LABEL=OpenMixer-Devel MATRIX_SET=quick "$pt" "$ch/devel/wave-b/deb" "$work/wave-b" "$NEW_ID" >/dev/null
    ;;
*) fail "rpm or deb, not $kind" ;;
esac
(cd "$ch" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm channel)
outside_sum > "$work/outside.before"
ok "$kind: a channel with omx-lib 3.13.0 real, 3.14.0 staged and 3.16.0 in wave-b's devel channel"

# ---- a level that is no wave's is refused before anything is written
act=$actions/publish-${kind}s/action.yml
step "$act" '^Prove the packages are there' "$work/first.sh"
step "$act" '^Assemble the tree' "$work/assemble.sh"
if [ "$kind" = rpm ]; then dirvar=RPM_DIR; skel=RELEASES; sk="44 45"; else dirvar=DEB_DIR; skel=SUITES; sk="bookworm trixie"; fi
for bad in devel/../rpm devel/ staging 'devel/Wave A'; do
    : > "$work/env-bad"
    if (cd "$ws" && env GITHUB_ACTION_PATH="$actions/publish-${kind}s" GITHUB_ENV="$work/env-bad" GITHUB_OUTPUT="$work/out-bad" \
        "$dirvar=$work/wave-a" STAGING=false LEVEL="$bad" "$skel=$sk" bash -e "$work/first.sh") > "$work/bad.log" 2>&1; then
        fail "the level '$bad' was taken"
    fi
    grep -qF "$bad" "$work/bad.log" || fail "the refusal of '$bad' does not name it: $(cat "$work/bad.log")"
    ! grep -q '_TREE=' "$work/env-bad" || fail "the level '$bad' named a tree: $(cat "$work/env-bad")"
done
ok "$kind: devel/../rpm, devel/, staging and a name outside [a-z0-9-] are refused by the first step, naming each"

# ---- the publish into devel/wave-a, through the action's own steps
: > "$work/env"; : > "$work/out"
(cd "$ws" && env GITHUB_ACTION_PATH="$actions/publish-${kind}s" GITHUB_ENV="$work/env" GITHUB_OUTPUT="$work/out" RUNNER_TEMP="$work/runner" \
    "$dirvar=$work/wave-a" STAGING=true LEVEL=devel/wave-a "$skel=$sk" bash -e "$work/first.sh" >/dev/null)
envfile "$work/env"
want_tree=devel/wave-a/$kind
grep -qx "tree=$want_tree" "$work/out" || fail "the first step names the tree $(cat "$work/out"), not $want_tree"
[ "${RPM_TREE:-${DEB_TREE:-}}" = "$want_tree" ] || fail "the tree variable is ${RPM_TREE:-${DEB_TREE:-}}, not $want_tree"
if [ "$kind" = rpm ]; then
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms RPM_DIR=$work/wave-a SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID MATRIX_SET=quick \
        bash -e "$work/assemble.sh") > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; fail "the devel rpm publish failed"; }
    t=$ch/devel/wave-a/rpm
    f=$t/fedora/45/noarch/omx-lib-3.15.0-1.fc45.noarch.rpm
    [ -f "$f" ] || fail "the wave's package is not at $want_tree/fedora/45/noarch: $(cd "$ch" && find devel -name '*.rpm')"
    rpm -qpi "$f" 2>/dev/null | grep -E '^Signature *:' | grep -qiv '(none)' || fail "the wave's package is not signed"
    for rel in 44 45; do for a in x86_64 aarch64 noarch SRPMS; do
        [ -s "$t/fedora/$rel/$a/repodata/repomd.xml.asc" ] || fail "no signed metadata in $want_tree/fedora/$rel/$a"
    done; done
    # shellcheck disable=SC2016 # dnf's variables, written as they are
    grep -qx 'baseurl=https://www.openmixer.org/devel/wave-a/rpm/fedora/$releasever/$basearch/' "$t/openmixer-devel.repo" ||
        fail "the tree does not serve openmixer-devel.repo for wave-a: $(cat "$t/openmixer-devel.repo" 2>&1)"
    [ ! -e "$t/openmixer-staging.repo" ] && [ ! -e "$t/openmixer.repo" ] || fail "the devel tree serves another level's repository file"
    cmd=$(rebuild "$act" push-devel rpm-dir="$work/wave-a")
else
    (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$work/wave-a SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID MATRIX_SET=quick \
        REQUIRES='' CHANGELOGS_URL=https://www.openmixer.org/devel/wave-a/deb/changelogs bash -e "$work/assemble.sh") \
        > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; fail "the devel deb publish failed"; }
    t=$ch/devel/wave-a/deb
    [ -f "$t/debian/trixie/all/omx-lib_3.15.0_all.deb" ] || fail "the wave's package is not at $want_tree/debian/trixie/all: $(cd "$ch" && find devel -name '*.deb')"
    for suite in bookworm trixie; do
        [ -s "$t/debian/$suite/InRelease" ] || fail "no signed index for $want_tree/debian/$suite"
        grep -qx 'Label: OpenMixer-Devel' "$t/debian/$suite/InRelease" || fail "$want_tree/debian/$suite is not labelled OpenMixer-Devel"
    done
    [ -s "$t/openmixer.asc" ] || fail "the devel tree serves no key"
    cmd=$(rebuild "$act" push-devel requires= changelogs-url=https://www.openmixer.org/devel/wave-a/deb/changelogs deb-dir="$work/wave-a")
fi
outside_sum | cmp -s - "$work/outside.before" || fail "the devel publish changed files outside $want_tree: $(outside_sum | diff "$work/outside.before" - | head)"
[ -z "$(cd "$ch" && git status --porcelain --untracked-files=all -- . ':(exclude)devel/wave-a')" ] || fail "git sees changes outside devel/wave-a: $(cd "$ch" && git status --porcelain -- . ':(exclude)devel/wave-a')"
[ "$(awk -F'\t' '!/^#/ {print $1 " " $2 " " $3}' "$t/cells.tsv")" = "omx-lib 3.15.0 quick" ] || fail "the wave's cells.tsv is not its own: $(cat "$t/cells.tsv")"
if ! grep -q '3.14.0' "$ch/staging/$kind/cells.tsv" || grep -q '3.15.0' "$ch/staging/$kind/cells.tsv"; then fail "staging's cells.tsv took the wave's row"; fi
ok "$kind: the publish lands under $want_tree alone, signed, indexed, with its own cells.tsv; every other file is byte-identical"

(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm devel)
(cd "$ws" && env PUBLISH_RPMS_ACTION="$actions/publish-rpms" PUBLISH_DEBS_ACTION="$actions/publish-debs" OPENMIXER_GPG_KEY_ID="$NEW_ID" \
    bash -c "$cmd") > "$work/rebuild.log" 2>&1 || { cat "$work/rebuild.log"; fail "the lost-race rebuild failed"; }
outside_sum | cmp -s - "$work/outside.before" || fail "the rebuild changed files outside $want_tree"
[ -z "$(cd "$ch" && git status --porcelain --untracked-files=all -- . ':(exclude)devel/wave-a')" ] || fail "the rebuild wrote outside devel/wave-a"
ok "$kind: the lost-race rebuild assembles $want_tree again and nothing else"

# ---- a client: the real channel, staging, and wave-a's devel channel above both
base=file://$ch
if [ "$kind" = rpm ]; then
    # a container an earlier test of the job used: what it installed or added is gone first
    for p in omx-lib omx-app omx-new; do rpm -e --nodeps "$p" >/dev/null 2>&1 || true; done
    rm -f /etc/yum.repos.d/openmixer-staging.repo /etc/yum.repos.d/openmixer-devel.repo
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    q() { dnf -q -y --disablerepo='*' --enablerepo='openmixer*' --disablerepo='openmixer-testing*' "$@"; }
    BASE_URL=$base "$actions/add-openmixer/add-staging.sh" >/dev/null
    out=$(BASE_URL=$base LEVEL=devel/wave-a "$actions/add-openmixer/add-staging.sh")
    grep -q 'priority 5' <<< "$out" || fail "the devel channel was not added at priority 5: $out"
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null
    q install omx-lib >/dev/null
    got=$(rpm -q --qf '%{VERSION}' omx-lib); repo=$(dnf -q repoquery --installed --qf '%{from_repo}' omx-lib)
    [ "$got" = 3.15.0 ] || fail "with wave-a's devel channel the client took omx-lib $got, not wave-a's 3.15.0"
    case $repo in openmixer-devel*) ;; *) fail "wave-a's omx-lib came from $repo" ;; esac
    q remove omx-lib >/dev/null
    mv /etc/yum.repos.d/openmixer-devel.repo "$work/"
    q makecache --refresh >/dev/null; q install omx-lib >/dev/null
    [ "$(rpm -q --qf '%{VERSION}' omx-lib)" = 3.14.0 ] || fail "without the devel channel the client took omx-lib $(rpm -q --qf '%{VERSION}' omx-lib), not staging's 3.14.0"
    q remove omx-lib >/dev/null
else
    # a container an earlier test of the job used: what it installed or added is gone first
    for p in omx-lib omx-new; do dpkg -P "$p" >/dev/null 2>&1 || true; done
    rm -f /etc/apt/sources.list.d/openmixer-staging.sources /etc/apt/preferences.d/openmixer-staging.pref \
        /etc/apt/sources.list.d/openmixer-devel.sources /etc/apt/preferences.d/openmixer-devel.pref
    install -D -m 644 "$ch/deb/openmixer.asc" /usr/share/keyrings/openmixer-archive-keyring.asc
    sed -e 's|@SUITE@|trixie|' -e "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/debian/openmixer.sources.in" \
        > /etc/apt/sources.list.d/openmixer.sources
    BASE_URL=$base SUITE=trixie "$actions/add-openmixer/add-staging.sh" >/dev/null
    out=$(BASE_URL=$base SUITE=trixie LEVEL=devel/wave-a "$actions/add-openmixer/add-staging.sh")
    grep -q 'pinned 650' <<< "$out" || fail "the devel channel was not pinned 650: $out"
    apt-get update -qq -o APT::Update::Error-Mode=any
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.15.0 ] || fail "with wave-a's devel channel the candidate is omx-lib $cand, not 3.15.0: $(apt-cache policy omx-lib)"
    apt-cache policy omx-lib | grep -A1 ' 3.15.0 ' | grep -q '^ *650 .*devel/wave-a/deb' || fail "wave-a's build is not pinned 650: $(apt-cache policy omx-lib)"
    ! apt-cache policy omx-lib | grep -q 3.16.0 || fail "the client sees wave-b's build"
    mv /etc/apt/preferences.d/openmixer-devel.pref /etc/apt/sources.list.d/openmixer-devel.sources "$work/"
    apt-get update -qq
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.0 ] || fail "without the devel channel the candidate is omx-lib $cand, not staging's 3.14.0"
fi
ok "$kind: a client with wave-a's devel channel takes its build over staging's, never wave-b's; without it, staging's"

# ---- a wave never published: nothing added, said so (the wave's first line)
out=$(BASE_URL=$base SUITE=trixie LEVEL=devel/wave-c "$actions/add-openmixer/add-staging.sh" 2>&1) || fail "a wave never published failed add-staging.sh: $out"
grep -q 'has not been published yet' <<< "$out" || fail "add-staging.sh does not say the wave was never published: $out"
[ ! -e /etc/yum.repos.d/openmixer-devel.repo ] && [ ! -e /etc/apt/sources.list.d/openmixer-devel.sources ] || fail "a wave never published was added"
ok "$kind: a wave never published is skipped with a notice, nothing added"
rm -rf "$work"
echo "devel-channel-publish $kind: all passed"
