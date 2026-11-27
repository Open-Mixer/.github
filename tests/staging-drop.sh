#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The drop of purge-staging (purge-staging/drop-staging.sh) on a fixture channel published by the real tree scripts with
# a throwaway key: staging/<kind> serves foo and foo-data at a dated 2026112401 and at 0.1.1, foo-extra (a name foo is a
# prefix of) at 2026112401, and bar in a release of its own (rpm fc44, deb bookworm); the real tree serves foo 2026112401
# too. The drop is foo@2026112401,foo-data@2026112401. Proves:
#   - the check passes and counts the files of each entry, over both staging trees (an entry only staging/deb holds
#     passes the rpm side's check and is left alone by its drop);
#   - exactly the files of those two package versions leave staging/<kind> (rpm: x86_64, aarch64, noarch and SRPMS;
#     deb: amd64, arm64 and all), each printed; every other file of the channel is byte-identical, the real tree rpm/ or
#     deb/ included; the only other paths that change are the metadata of the directories (rpm) or the Debian release
#     (deb) the files left and cells.tsv;
#   - that metadata is signed again and verifies, no longer lists the dropped files and still lists the kept ones;
#     cells.tsv loses the dropped rows and keeps every other line;
#   - a drop of what is no longer there removes nothing and writes nothing;
#   - the check refuses, naming each, an entry that matches no file (a version that is a prefix of a served one, a
#     name no file has), and a malformed entry (a pattern); the tree is unchanged by it.
# Sabotage, each must turn this test red: a prefix match of the name (foo-extra goes too); every directory's metadata
# made again (an untouched index changes); the check's refusal taken out.
#
#   staging-drop.sh rpm|deb     rpm: rpm-build rpm-sign createrepo_c python3-rpm gnupg2 zstd diffutils; deb: apt-utils gnupg gpgv dpkg-dev
set -euo pipefail
kind=${1:?usage: staging-drop.sh rpm|deb}
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${STAGING_DROP_ACTIONS:-$here/.github/actions}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Release <release@example.org>' ed25519 sign 1y
key=$(gpg --batch --with-colons --fingerprint release@example.org | awk -F: '/^fpr:/ {print $10; exit}')
printf '%s packages throwaway\n' "$key" > "$work/pinned.txt"
export PINNED_FINGERPRINTS=$work/pinned.txt
mkdir -p "$work/no-committed"
export SERVED_KEYS_DIR=$work/no-committed
ch=$work/channel
st=$ch/staging/$kind
D=2026112401
drop="foo@$D,foo-data@$D"

snapshot() { (cd "$ch" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$1"; }
changed() { { diff "$1" "$2" || true; } | sed -n 's/^[<>] [0-9a-f]*  \.\///p' | LC_ALL=C sort -u; }
drop_run() { "$actions/purge-staging/drop-staging.sh" "$@"; }

case $kind in
rpm)
    mkrpm() { # <name> <version> <arch> <fedora release> <out dir>
        local spec=$work/$1-$2-$3-$4.spec
        printf '%s\n' "Name: $1" "Version: $2" "Release: 1.fc$4" 'Summary: t' 'License: MIT' \
            "$([ "$3" = noarch ] && echo 'BuildArch: noarch')" '%description' "$1 $2" '%files' > "$spec"
        rpmbuild -ba --quiet --define "_topdir $work/rb-$1-$2-$3-$4" --define 'dist %{nil}' --define 'debug_package %{nil}' \
            $([ "$3" = noarch ] || echo "--target $3") "$spec" >/dev/null 2>&1 || fail "rpmbuild $1 $2 $3 fc$4"
        mkdir -p "$5"
        find "$work/rb-$1-$2-$3-$4" -name '*.rpm' -exec cp -n {} "$5/" \;
    }
    stage() { REPO_FILE=$here/packaging/staging/openmixer-staging.repo "$actions/publish-rpms/publish-tree.sh" "$st" "$1" "$key"; }
    for a in x86_64 aarch64; do mkrpm foo $D $a 45 "$work/s"; mkrpm foo 0.1.1 $a 45 "$work/s"; done
    mkrpm foo-data $D noarch 45 "$work/s"
    mkrpm foo-data 0.1.1 noarch 45 "$work/s"
    mkrpm foo-extra $D x86_64 45 "$work/s"
    mkrpm bar 1 x86_64 44 "$work/s"
    mkrpm foo $D x86_64 45 "$work/real"
    gone=$(printf '%s\n' "fedora/45/x86_64/foo-$D-1.fc45.x86_64.rpm" "fedora/45/aarch64/foo-$D-1.fc45.aarch64.rpm" \
        "fedora/45/noarch/foo-data-$D-1.fc45.noarch.rpm" "fedora/45/SRPMS/foo-$D-1.fc45.src.rpm" \
        "fedora/45/SRPMS/foo-data-$D-1.fc45.src.rpm")
    kept="fedora/45/x86_64/foo-0.1.1-1.fc45.x86_64.rpm fedora/45/x86_64/foo-extra-$D-1.fc45.x86_64.rpm fedora/45/noarch/foo-data-0.1.1-1.fc45.noarch.rpm"
    index='fedora/45/(x86_64|aarch64|noarch|SRPMS)/repodata/.*'
    untouched=fedora/44/x86_64/repodata/repomd.xml
    listing() { # <dir>: the file names its primary metadata lists
        local f
        for f in "$st/$1"/repodata/*primary.xml*; do
            case $f in *.zst) zstd -dcq "$f" ;; *.xz) xz -dc "$f" ;; *.gz) gzip -dc "$f" ;; *) cat "$f" ;; esac
        done | sed -n 's/.*<location href="\([^"]*\)".*/\1/p'
    }
    verify_index() { # <dir>
        gpg --batch --quiet --verify "$st/$1/repodata/repomd.xml.asc" "$st/$1/repodata/repomd.xml" 2>/dev/null ||
            fail "the metadata of staging/rpm/$1 does not verify"
    }
    index_dirs='fedora/45/x86_64 fedora/45/aarch64 fedora/45/noarch fedora/45/SRPMS'
    in_index() { listing "${1%/*}" | grep -qxF "${1##*/}"; }
    # a name only staging/deb holds: the check reads both trees
    mkdir -p "$ch/staging/deb/debian/trixie/amd64"
    : > "$ch/staging/deb/debian/trixie/amd64/onlydeb_1-1_amd64.deb"
    ;;
deb)
    mkdeb() { # <package> <version> <arch> <suite> <out dir>
        local d=$work/b-$1-$2-$3-$4
        mkdir -p "$d/DEBIAN" "$5/$4"
        printf '%s\n' "Package: $1" "Version: $2" "Architecture: $3" 'Maintainer: t <t@example.org>' "Description: $1 $2" > "$d/DEBIAN/control"
        dpkg-deb -b "$d" "$5/$4/${1}_${2}_$3.deb" >/dev/null
    }
    stage() { LABEL=OpenMixer-Staging CHANGELOGS_URL=https://example.org/staging/deb/changelogs "$actions/publish-debs/publish-tree.sh" "$st" "$1" "$key"; }
    for a in amd64 arm64; do mkdeb foo $D-1 $a trixie "$work/s"; mkdeb foo 0.1.1-1 $a trixie "$work/s"; done
    mkdeb foo-data $D-1 all trixie "$work/s"
    mkdeb foo-data 0.1.1-1 all trixie "$work/s"
    mkdeb foo-extra $D-1 arm64 trixie "$work/s"
    mkdeb bar 1-1 amd64 bookworm "$work/s"
    mkdeb foo $D-1 amd64 trixie "$work/real"
    gone=$(printf '%s\n' "debian/trixie/amd64/foo_$D-1_amd64.deb" "debian/trixie/arm64/foo_$D-1_arm64.deb" \
        "debian/trixie/all/foo-data_$D-1_all.deb")
    kept="debian/trixie/amd64/foo_0.1.1-1_amd64.deb debian/trixie/arm64/foo-extra_$D-1_arm64.deb debian/trixie/all/foo-data_0.1.1-1_all.deb"
    index='debian/trixie/(Packages|Packages\.gz|Release|InRelease|Release\.gpg)'
    untouched=debian/bookworm/InRelease
    index_dirs=debian/trixie
    verify_index() { # <suite dir>
        gpg --batch --export "$key" > "$work/keyring.gpg"
        gpgv --keyring "$work/keyring.gpg" "$st/$1/InRelease" 2>/dev/null || fail "the index of staging/deb/$1 does not verify"
        grep -qx 'Label: OpenMixer-Staging' "$st/$1/InRelease" || fail "the index of staging/deb/$1 lost its label"
        grep -qx 'Changelogs: https://example.org/staging/deb/changelogs/@CHANGEPATH@_changelog' "$st/$1/Release" ||
            fail "the index of staging/deb/$1 lost its Changelogs field"
    }
    in_index() { local s; s=${1#debian/}; s=${s%%/*}; grep -qx "Filename: ./${1#debian/"$s"/}" "$st/debian/$s/Packages"; }
    ;;
*) fail "usage: staging-drop.sh rpm|deb" ;;
esac
mkdir -p "$ch/rpm" "$ch/deb"
stage "$work/s" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture's staged publish failed"; }
if [ "$kind" = rpm ]; then
    "$actions/publish-rpms/publish-tree.sh" "$ch/rpm" "$work/real" "$key" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture's real publish failed"; }
else
    "$actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/real" "$key" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture's real publish failed"; }
fi
for f in $gone $kept; do [ -f "$st/$f" ] || fail "the fixture has no staging/$kind/$f"; in_index "$f" || fail "the fixture's index does not list $f"; done
[ -f "$st/$untouched" ] || fail "the fixture has no $untouched"
cp "$st/cells.tsv" "$work/cells.before"
grep -qP "^foo\t$D\t" "$work/cells.before" || fail "the fixture's cells.tsv has no foo $D row"

# ---- the drop: exactly the named versions leave, only their metadata is made again
sleep 1 # an index made again carries another date and signature: a rewrite shows in the bytes
snapshot "$work/before"
drop_run check "$ch" "$drop" > "$work/check.log" 2>&1 || { cat "$work/check.log"; fail "the check refused a drop staging holds"; }
grep -qx "foo@$D: [0-9]* file(s)" "$work/check.log" || { cat "$work/check.log"; fail "the check does not count foo@$D"; }
if [ "$kind" = rpm ]; then
    drop_run check "$ch" "$drop,onlydeb@1" > "$work/check.log" 2>&1 || { cat "$work/check.log"; fail "the check refused an entry only staging/deb holds"; }
    drop="$drop,onlydeb@1"
fi
drop_run "$kind" "$ch" "$drop" "$key" > "$work/drop.log" 2>&1 || { cat "$work/drop.log"; fail "the drop failed"; }
snapshot "$work/after"
for f in $gone; do
    [ ! -e "$st/$f" ] || fail "the drop left staging/$kind/$f"
    grep -qxF "removed staging/$kind/$f" "$work/drop.log" || { cat "$work/drop.log"; fail "the drop did not print staging/$kind/$f"; }
done
[ "$(grep -c '^removed ' "$work/drop.log")" = "$(wc -l <<< "$gone")" ] || { cat "$work/drop.log"; fail "the drop removed other files than the named versions"; }
ch_paths=$(changed "$work/before" "$work/after")
unexpected=$(grep -vxE "$(sed "s|^|staging/$kind/|" <<< "$gone" | paste -sd'|')|staging/$kind/cells\.tsv|staging/$kind/$index" <<< "$ch_paths" || true)
[ -z "$unexpected" ] || { cat "$work/drop.log"; fail "the drop changed other files: $unexpected"; }
grep -qE "^staging/$kind/$index$" <<< "$ch_paths" || fail "the drop did not make the touched metadata again"
! grep -qxF "staging/$kind/$untouched" <<< "$ch_paths" || fail "the drop made $untouched again, where nothing left"
ok "$kind: exactly the files of foo@$D and foo-data@$D left staging/$kind, each printed; every other file byte-identical, rpm/ and deb/ included"

for d in $index_dirs; do verify_index "$d"; done
for f in $gone; do ! in_index "$f" || fail "the index still lists the dropped $f"; done
for f in $kept; do in_index "$f" || fail "the index lost the kept $f"; done
ok "$kind: the metadata of what the files left is signed again, verifies, and lists the kept versions only"

[ -z "$(awk -F'\t' -v d=$D '($1 == "foo" || $1 == "foo-data") && $2 == d' "$st/cells.tsv")" ] || fail "cells.tsv keeps a dropped row"
diff <(grep -vP "^(foo|foo-data)\t$D\t" "$work/cells.before") "$st/cells.tsv" > /dev/null ||
    fail "cells.tsv changed other lines: $(diff "$work/cells.before" "$st/cells.tsv")"
ok "$kind: cells.tsv loses the dropped rows and keeps every other line"

# ---- a drop of what is gone writes nothing
snapshot "$work/before"
drop_run "$kind" "$ch" "foo@$D" "$key" > "$work/log" 2>&1 || { cat "$work/log"; fail "a drop with nothing left to remove failed"; }
grep -q '^nothing of the drop is in staging' "$work/log" || { cat "$work/log"; fail "a drop with nothing to remove does not say so"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "a drop with nothing to remove changed the tree: $(changed "$work/before" "$work/after")"
ok "$kind: a drop of what staging no longer holds removes nothing and writes nothing"

# ---- refusals: named, nothing written
refused() { # <what> <drop> <expected refusal>...
    local what=$1 list=$2; shift 2
    snapshot "$work/before"
    if drop_run check "$ch" "$list" > "$work/log" 2>&1; then cat "$work/log"; fail "the check passed $what"; fi
    for r in "$@"; do grep -qF "refused $r" "$work/log" || { cat "$work/log"; fail "the refusal of $what does not name $r"; }; done
    grep -q 'nothing was removed' "$work/log" || { cat "$work/log"; fail "the refusal of $what does not say nothing was removed"; }
    snapshot "$work/after"
    cmp -s "$work/before" "$work/after" || fail "the refused check of $what changed the tree"
}
refused "versions staging does not hold" "foo@0.1.1,foo@20261124,nope@1" "foo@20261124: no file" "nope@1: no file"
grep -q 'refused foo@0.1.1' "$work/log" && fail "the check refused foo@0.1.1, which staging holds"
refused "a pattern" "foo*@0.1.1" "'foo*@0.1.1': not name@version"
ok "$kind: the check refuses by name an entry that matches no file, and a pattern; nothing is written"

# ---- the wiring: the workflow hands drop to both jobs and checks in the first; the action pulls a drop with its metadata
if [ -z "${STAGING_DROP_ACTIONS:-}" ]; then
    python3 -I - "$here" <<'PY' || fail "the purge-staging wiring of drop is not as this test proves it"
import sys, yaml
root = sys.argv[1]
wf = yaml.safe_load(open(f"{root}/.github/workflows/purge-staging.yml"))
on = wf.get("on", wf.get(True))
for trigger in ("workflow_dispatch", "workflow_call"):
    assert on[trigger]["inputs"]["drop"]["default"] == "", f"{trigger} has no drop input defaulting to empty"
jobs = wf["jobs"]
assert jobs["deb"]["needs"] == "rpm", "the deb job does not wait for the rpm job, which checks the drop"
for job, check in (("rpm", "true"), ("deb", "false")):
    w = [s for s in jobs[job]["steps"] if "purge-staging" in s.get("uses", "")][0]["with"]
    assert w["drop"] == "${{ inputs.drop }}", f"the {job} job does not pass drop"
    assert w["drop-check"] == check, f"the {job} job's drop-check is {w['drop-check']!r}, not {check!r}"
act = yaml.safe_load(open(f"{root}/.github/actions/purge-staging/action.yml"))
steps = act["runs"]["steps"]
pull = [s for s in steps if "channel-pull" in s.get("uses", "")][0]
assert pull["with"]["strip"] == "${{ (inputs.drop == '' && inputs.kind == 'rpm') && 'staging/rpm' || 'none' }}", "a drop strips metadata"
purge = [s for s in steps if s.get("name") == "Purge the staging tree"][0]
assert purge["if"] == "inputs.drop == ''", "the purge runs beside a drop"
drop = [s for s in steps if s.get("name", "").startswith("Drop the named")][0]
assert drop["if"] == "inputs.drop != ''" and "drop-staging.sh\" check" in drop["run"], "the drop step does not check"
for s in steps:
    if s.get("id", "").startswith("push-"):
        assert "drop-staging.sh" in s["with"]["rebuild"], f"{s['id']} does not repeat the drop on a lost race"
PY
    ok "$kind: the workflow passes drop to both jobs, the rpm job checks it, and the action pulls a drop with its metadata"
fi

# ---- sabotage, each must turn this test red:
#   prefix   the name compared as a prefix: foo@$D takes foo-extra $D too
#   index    every directory's metadata made again (no REINDEX): an index nothing left changes
#   refusal  the check's refusal taken out
if [ -z "${STAGING_DROP_ACTIONS:-}" ]; then
    for what in prefix index refusal; do
        sab=$work/sab-$what
        mkdir -p "$sab"
        cp -a "$here/.github" "$here/packaging" "$sab/"
        script=$sab/.github/actions/purge-staging/drop-staging.sh
        case $what in
        prefix)
            sed -i 's/^        \[ -n "\$nv" \] && \[ -n "\${want\[\$nv\]:-}" \] || continue$/        hit=; for w in "${!want[@]}"; do [[ ${nv% *} == "${w% *}"* \&\& ${nv#* } == "${w#* }" ]] \&\& hit=1; done; [ -n "$hit" ] || continue/' "$script"
            want='FAIL: the drop (removed other files|changed other files)' ;;
        index) sed -i 's/^    REINDEX=\$reindex /    REINDEX= /' "$script"; want='FAIL: the drop changed other files' ;;
        refusal) sed -i 's/^            missing=1$/            :/' "$script"; want='FAIL: the check passed' ;;
        esac
        ! cmp -s "$script" "$here/.github/actions/purge-staging/drop-staging.sh" || fail "the $what sabotage did not change drop-staging.sh"
        if STAGING_DROP_ACTIONS=$sab/.github/actions bash "$0" "$kind" > "$work/sab.log" 2>&1; then
            cat "$work/sab.log"; fail "with the $what sabotage this test stayed green"
        fi
        grep -qE "$want" "$work/sab.log" || { cat "$work/sab.log"; fail "the $what sabotage went red for another reason"; }
        ok "$kind: sabotage ($what) goes red: $(grep -m1 -oE "$want" "$work/sab.log")"
    done
fi
echo "staging-drop $kind: the named versions only, the touched metadata only, signed; refusals by name"
