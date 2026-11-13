#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The first staged run into a channel that has no staging path, the way build-rpm.yml / build-deb.yml run it: the build
# job adds the staging channel (add-openmixer with staging), then the publish job publishes into staging/<kind>, then
# the install check adds the staging channel again. The channel is served over HTTP, so a missing file is a real 404.
# Proves:
#   - the control: the fixture has no staging path, and its staging index answers 404 while the real index answers 200;
#   - strict by default: the build job's add-openmixer staging step, with no switch, refuses a staging channel never
#     published and names the URL that answered 404; it never builds against the released dependency on a notice;
#   - the switch: build-rpm.yml and build-deb.yml take staging-bootstrap (boolean, default false) and pass it to the
#     build job's add-openmixer; with it on, the same step adds nothing, says so with a notice, exits 0 and keeps the
#     real channel loading (the first layer of a wave, whose build job runs before anything was staged);
#   - the staged publish, through the action's own steps (the one that names the tree first), creates staging/<kind>
#     with a signed index for every release of the skeleton, and the real tree is byte-identical;
#   - the install check's add-openmixer staging step then adds the staging channel and loads it strictly, and the client
#     takes the staged build;
#   - the switch is not a weaker check: with it on, a staging index with a broken signature, and a staging tree that
#     exists but has no index for the client's release, both fail the step;
#   - purged to nothing: after the purge the step loads the empty index, and the next staged publish lands as the first.
# Runs as root in a throwaway Fedora (rpm) or Debian (deb) container (curl and python3 in it): the client arm writes /etc.
#
#   staging-bootstrap.sh rpm|deb
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
actions=$root/.github/actions
kind=${1:?usage: staging-bootstrap.sh rpm|deb}
case $kind in rpm | deb) ;; *) echo "staging-bootstrap.sh: rpm or deb, not '$kind'" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "staging-bootstrap.sh writes /etc of a throwaway container: run it as root there" >&2; exit 2; }
work=$(mktemp -d)
chmod 755 "$work" # apt reads the signed-by file as _apt
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null || true; rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Staging Test <staging@example.org>' ed25519 sign 1y
NEW_ID=$(gpg --with-colons --fingerprint staging@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$NEW_ID" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed

# the channel checkout as channel-pull leaves it, the real tree and the site, and no staging/ at all
ws=$work/ws; ch=$ws/build/channel
mkdir -p "$ch/rpm" "$ch/deb"
echo '<html>site</html>' > "$ch/index.html"
real_sum() { (cd "$ch" && find . \( -path ./staging -o -path ./.git \) -prune -o -type f -print0 | sort -z | xargs -0 sha256sum); }

# a step of an action, as the runner runs it: picked by its name, or by its `if` when it has no name
step() { # <action.yml> <pattern on name or if> <out>
    python3 -I - "$@" <<'PY'
import re, sys, yaml
path, pat, out = sys.argv[1:4]
steps = yaml.safe_load(open(path))["runs"]["steps"]
hit = [s for s in steps if "run" in s and (re.search(pat, s.get("name") or "") or re.search(pat, s.get("if") or ""))]
assert len(hit) == 1, f"{path}: {len(hit)} steps match {pat!r}"
open(out, "w").write(hit[0]["run"])
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
    mkdir -p "$work/real" "$work/staged" "$work/staged2"
    cp "$(mkpkg omx-lib 3.13.0 1.fc44)" "$work/real/"
    cp "$(mkpkg omx-lib 3.14.0 1.git5f455d3.fc44)" "$work/staged/"
    cp "$(mkpkg omx-lib 3.14.0 1.git6a0b1c2.fc44)" "$work/staged2/"
    "$actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/real" "$NEW_ID" >/dev/null
    rel=$(. /etc/os-release && echo "$VERSION_ID")
    [ "$rel" = 44 ] || fail "the rpm arm runs in fedora:44, not $rel"
    index=staging/rpm/fedora/44/noarch/repodata/repomd.xml
    real_index=rpm/fedora/44/noarch/repodata/repomd.xml
    sk="44 45"
    ;;
deb)
    mkdeb() { # <name> <version>
        local d=$work/db-$1-$2
        mkdir -p "$d/DEBIAN"
        printf '%s\n' "Package: $1" "Version: $2" 'Architecture: amd64' 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
        dpkg-deb --root-owner-group -b "$d" "$work/$1_$2_amd64.deb" >/dev/null
        echo "$work/$1_$2_amd64.deb"
    }
    mkdir -p "$work/real/trixie" "$work/staged/trixie" "$work/staged2/trixie"
    cp "$(mkdeb omx-lib 3.13.0)" "$work/real/trixie/"
    cp "$(mkdeb omx-lib 3.14.0+git5f455d3)" "$work/staged/trixie/"
    cp "$(mkdeb omx-lib 3.14.0+git6a0b1c2)" "$work/staged2/trixie/"
    "$actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/real" "$NEW_ID" >/dev/null
    index=staging/deb/debian/trixie/InRelease
    real_index=deb/debian/trixie/InRelease
    sk="bookworm trixie"
    ;;
esac
(cd "$ch" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.org commit -qm real)
real_sum > "$work/real.before"

# the channel over HTTP, as Pages serves it: a missing path is a 404
port=$((20000 + RANDOM % 20000))
python3 -I -m http.server --bind 127.0.0.1 --directory "$ch" "$port" > "$work/http.log" 2>&1 &
server=$!
base=http://127.0.0.1:$port
code() { curl -s -o /dev/null -w '%{http_code}' "$1" || true; }
for _ in $(seq 1 50); do [ "$(code "$base/index.html")" = 200 ] && break; sleep 0.2; done

# ---- the control: no staging path, a 404 where the staging index would be, a 200 for the real one
[ ! -e "$ch/staging" ] || fail "the fixture has a staging path: $(find "$ch/staging" | head)"
[ "$(code "$base/$real_index")" = 200 ] || fail "the server does not serve the real index $real_index"
[ "$(code "$base/$index")" = 404 ] || fail "the staging index $index does not answer 404 before the first publish"
ok "$kind: control: the channel has no staging path, its staging index answers 404 and the real index 200"

# ---- the client: the real channel added as openmixer-release adds it
if [ "$kind" = rpm ]; then
    install -D -m 644 "$ch/rpm/RPM-GPG-KEY-openmixer" /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
    sed "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/openmixer.repo" > /etc/yum.repos.d/openmixer.repo
    q() { dnf -q -y --disablerepo='*' --enablerepo='openmixer*' "$@"; }
    staging_files=(/etc/yum.repos.d/openmixer-staging.repo)
else
    install -D -m 644 "$ch/deb/openmixer.asc" /usr/share/keyrings/openmixer-archive-keyring.asc
    sed -e 's|@SUITE@|trixie|' -e "s|https://www.openmixer.org/|$base/|" "$root/packaging/openmixer-release/debian/openmixer.sources.in" \
        > /etc/apt/sources.list.d/openmixer.sources
    staging_files=(/etc/apt/sources.list.d/openmixer-staging.sources /etc/apt/preferences.d/openmixer-staging.pref)
fi

# add-openmixer's staging step, as the build job and the install check run it: its script, and its env with the action's
# inputs written in (the ones passed, the declared default for the rest; an input the action does not declare stops here)
step "$actions/add-openmixer/action.yml" 'inputs\.staging' "$work/add-staging.sh"
add_staging() { # [staging-bootstrap value]: unset passes nothing, as a caller without the switch
    python3 -I - "$actions/add-openmixer/action.yml" "$work/step.env" "base-url=$base" suite=trixie ${1:+"staging-bootstrap=$1"} <<'PY2'
import re, sys, yaml
path, out, kv = sys.argv[1], sys.argv[2], dict(a.split("=", 1) for a in sys.argv[3:])
d = yaml.safe_load(open(path)); inputs = d.get("inputs") or {}
for k in kv: assert k in inputs, f"add-openmixer declares no input {k}"
s = [s for s in d["runs"]["steps"] if "inputs.staging" in (s.get("if") or "")][0]
def val(m):
    k = m.group(1); assert k in inputs, f"add-openmixer's staging step reads an undeclared input {k}"
    return str(kv.get(k, inputs[k].get("default", "")))
with open(out, "w") as f:
    for name, v in (s.get("env") or {}).items():
        f.write(name + "=" + re.sub(r"\$\{\{\s*inputs\.([a-z-]+)\s*\}\}", val, str(v)) + "\n")
PY2
    (envfile "$work/step.env"; GITHUB_ACTION_PATH=$actions/add-openmixer bash -e "$work/add-staging.sh")
}

# ---- the build job of the first staged run, no switch: strict, the 404 named
if add_staging > "$work/strict-add.log" 2>&1; then
    fail "with no staging-bootstrap a staging channel never published is not refused: $(cat "$work/strict-add.log")"
fi
grep -qF "$base/$index" "$work/strict-add.log" && grep -q 404 "$work/strict-add.log" ||
    fail "the refusal does not name the URL that answered 404 ($base/$index): $(cat "$work/strict-add.log")"
rm -f "${staging_files[@]}"
ok "$kind: with no switch, a staging channel never published fails the step and names $index answering 404"

# ---- the switch is plumbed: both reusable workflows declare it off by default and hand it to the build job's add-openmixer
python3 -I - "$root/.github/workflows/build-rpm.yml" "$root/.github/workflows/build-deb.yml" "$actions/add-openmixer/action.yml" <<'PY2' ||
import sys, yaml
*wfs, act = sys.argv[1:]
a = yaml.safe_load(open(act))["inputs"].get("staging-bootstrap")
assert a is not None and str(a.get("default")) == "false", f"add-openmixer: staging-bootstrap is {a}, not an input off by default"
for wf in wfs:
    d = yaml.safe_load(open(wf)); i = d[True]["workflow_call"]["inputs"].get("staging-bootstrap")
    assert i is not None and i.get("type") == "boolean" and i.get("default") is False, f"{wf}: staging-bootstrap is {i}, not a boolean off by default"
    adds = [s for s in d["jobs"]["build"]["steps"] if "/actions/add-openmixer@" in s.get("uses", "")]
    assert len(adds) == 1 and adds[0]["with"].get("staging-bootstrap") == "${{ inputs.staging-bootstrap }}", \
        f"{wf}: the build job does not pass staging-bootstrap to add-openmixer"
PY2
    fail "the staging-bootstrap switch is not plumbed from build-rpm.yml / build-deb.yml through add-openmixer"
ok "$kind: build-rpm.yml and build-deb.yml take staging-bootstrap, off by default, and pass it to the build job's add-openmixer"

# ---- the build job of the first layer's staged run, staging-bootstrap: true: the notice, exit 0
add_staging true > "$work/build-add.log" 2>&1 ||
    { cat "$work/build-add.log"; fail "with staging-bootstrap the first staged run stops in its build job on a staging channel never published"; }
for f in "${staging_files[@]}"; do [ ! -e "$f" ] || fail "add-openmixer added the staging channel ($f) where none was published"; done
grep -q '::notice::' "$work/build-add.log" && grep -qi 'not been published' "$work/build-add.log" ||
    fail "add-openmixer does not give the notice that staging was skipped: $(cat "$work/build-add.log")"
if [ "$kind" = rpm ]; then
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null || fail "the real channel does not load beside the skipped staging"
else
    apt-get update -qq -o APT::Update::Error-Mode=any || fail "the real channel does not load beside the skipped staging"
fi
ok "$kind: with staging-bootstrap the build job adds no staging channel where none was published, gives the notice, keeps the real channel"

# ---- the publish job: the action's steps, the one that names the tree first
act=$actions/publish-${kind}s/action.yml
step "$act" '^Prove the packages are there' "$work/first.sh"
step "$act" '^Check the signing key' "$work/check.sh"
step "$act" '^Assemble the tree' "$work/assemble.sh"
step "$act" '^Prove the tree holds' "$work/prove.sh"
publish() { # <package dir>
    : > "$work/env"
    # channel-pull with strip staging/rpm: the pulled dnf metadata of the tree being published is discarded
    if [ "$kind" = rpm ] && [ -d "$ch/staging/rpm" ]; then find "$ch/staging/rpm" -type d -name repodata -prune -exec rm -rf {} +; fi
    if [ "$kind" = rpm ]; then
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms GITHUB_ENV=$work/env RPM_DIR=$1 STAGING=true RELEASES="$sk" bash -e "$work/first.sh")
        envfile "$work/env"
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms OPENMIXER_GPG_KEY_ID=$NEW_ID PUBLIC_KEY_URL= bash -e "$work/check.sh")
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-rpms RPM_DIR=$1 SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID bash -e "$work/assemble.sh")
    else
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs GITHUB_ENV=$work/env DEB_DIR=$1 STAGING=true SUITES="$sk" bash -e "$work/first.sh")
        envfile "$work/env"
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs OPENMIXER_GPG_KEY_ID=$NEW_ID bash -e "$work/check.sh")
        (cd "$ws" && GITHUB_ACTION_PATH=$actions/publish-debs DEB_DIR=$1 SIGN=true OPENMIXER_GPG_KEY_ID=$NEW_ID REQUIRES= \
            CHANGELOGS_URL=$base/staging/deb/changelogs bash -e "$work/assemble.sh")
    fi
    (cd "$ws" && SIGN=true bash -e "$work/prove.sh")
}
publish "$work/staged" > "$work/publish.log" 2>&1 || { cat "$work/publish.log"; fail "the first staged publish into a channel with no staging path failed"; }
if [ "$kind" = rpm ]; then
    for r in 44 45; do for a in x86_64 aarch64 noarch SRPMS; do
        [ -s "$ch/staging/rpm/fedora/$r/$a/repodata/repomd.xml.asc" ] || fail "the first publish left staging/rpm/fedora/$r/$a without signed metadata"
    done; done
    [ -s "$ch/staging/rpm/RPM-GPG-KEY-openmixer" ] && [ -s "$ch/staging/rpm/openmixer-staging.repo" ] || fail "the first publish left staging/rpm without its key or repository file"
else
    for s in bookworm trixie; do
        grep -qx 'Label: OpenMixer-Staging' "$ch/staging/deb/debian/$s/InRelease" || fail "the first publish left staging/deb/debian/$s without a signed, labelled index"
    done
    [ -s "$ch/staging/deb/openmixer.asc" ] || fail "the first publish left staging/deb without its key"
fi
real_sum | cmp -s - "$work/real.before" || fail "the first staged publish changed the real tree"
[ "$(code "$base/$index")" = 200 ] || fail "the staging index is not served after the first publish"
ok "$kind: the first staged publish creates staging/$kind with a signed index for every release, the real tree untouched"

# ---- the install check: the staging channel is there now and is added and loaded strictly
add_staging > "$work/verify-add.log" 2>&1 || { cat "$work/verify-add.log"; fail "the install check cannot add the staging channel the first publish made"; }
for f in "${staging_files[@]}"; do [ -s "$f" ] || fail "add-openmixer did not add $f once staging was published"; done
if [ "$kind" = rpm ]; then
    q install omx-lib >/dev/null
    [ "$(rpm -q --qf '%{RELEASE}' omx-lib)" = 1.git5f455d3.fc44 ] || fail "the client took omx-lib $(rpm -q --qf '%{VERSION}-%{RELEASE}' omx-lib), not the staged build"
    q remove omx-lib >/dev/null
else
    apt-get update -qq -o APT::Update::Error-Mode=any
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.0+git5f455d3 ] || fail "the candidate is omx-lib $cand, not the staged build"
fi
ok "$kind: the install check adds the staging channel the first publish made, and the client takes the staged build"

# ---- the tolerance is for a staging channel never published, never for a broken one
# a fresh machine without the staging channel: its files gone, and the staging metadata dnf or apt cached with them (apt
# keeps a cached index when a new one fails to verify, with a warning only; a fresh build container has none)
unadd() { rm -f "${staging_files[@]}"; rm -rf /var/cache/libdnf5/openmixer-staging* /var/lib/apt/lists/*_staging_deb_*; }
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org commit -qm staged)
if [ "$kind" = rpm ]; then
    echo '<!-- tampered -->' >> "$ch/staging/rpm/fedora/44/noarch/repodata/repomd.xml"
else
    sed -i 's/^Label: OpenMixer-Staging$/Label: OpenMixer-Tampered/' "$ch/staging/deb/debian/trixie/InRelease"
fi
unadd
if add_staging true > "$work/tampered.log" 2>&1; then fail "add-openmixer loaded a staging index with a broken signature: $(cat "$work/tampered.log")"; fi
(cd "$ch" && git checkout -q -- .)
mv "$ch/staging/$kind" "$work/kept-tree"
mkdir -p "$ch/staging/$kind"; cp "$work/kept-tree/$([ "$kind" = rpm ] && echo RPM-GPG-KEY-openmixer || echo openmixer.asc)" "$ch/staging/$kind/"
unadd
if add_staging true > "$work/partial.log" 2>&1; then fail "add-openmixer skipped a staging tree that exists but has no index for this release: $(cat "$work/partial.log")"; fi
rm -rf "$ch/staging/$kind"; mv "$work/kept-tree" "$ch/staging/$kind"
ok "$kind: with staging-bootstrap, a staging index with a broken signature, and a staging tree without this release's index, still fail"

# ---- purged to nothing: the empty index loads, and the next staged publish lands as the first did
SKELETON=$sk "$actions/purge-staging/purge-staging.sh" "$kind" "$ch" "$NEW_ID" > "$work/purge.log" 2>&1 || { cat "$work/purge.log"; fail "the purge failed"; }
[ -z "$(find "$ch/staging/$kind" -name "*.$kind")" ] || fail "the purge left packages"
unadd
add_staging > "$work/purged-add.log" 2>&1 || { cat "$work/purged-add.log"; fail "add-openmixer cannot add the purged, empty staging channel"; }
for f in "${staging_files[@]}"; do [ -s "$f" ] || fail "add-openmixer skipped the purged staging channel: its empty index is published"; done
(cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org commit -qm purged)
publish "$work/staged2" > "$work/publish2.log" 2>&1 || { cat "$work/publish2.log"; fail "the staged publish after the purge failed"; }
real_sum | cmp -s - "$work/real.before" || fail "the staged publish after the purge changed the real tree"
if [ "$kind" = rpm ]; then
    q --setopt=skip_if_unavailable=False makecache --refresh >/dev/null
    q install omx-lib >/dev/null
    [ "$(rpm -q --qf '%{RELEASE}' omx-lib)" = 1.git6a0b1c2.fc44 ] || fail "after the purge and a publish the client took omx-lib $(rpm -q --qf '%{RELEASE}' omx-lib)"
else
    apt-get update -qq -o APT::Update::Error-Mode=any
    cand=$(apt-cache policy omx-lib | awk '/Candidate:/ {print $2}')
    [ "$cand" = 3.14.0+git6a0b1c2 ] || fail "after the purge and a publish the candidate is omx-lib $cand"
fi
ok "$kind: purged to nothing, the empty index loads and the next staged publish lands like the first"
echo "staging-bootstrap $kind: all passed"
