#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A rerun of an RPM release after its publish job succeeded (.github#24, the RPM side of tests/deb-rerun-layout.sh).
# The first attempt uploads the kept copies as one more artifact of the run, and artifacts outlive their attempt: the
# download of the next attempt must not take them for build output. Runs the workflow's own patterns and the action's
# own steps (the tree step that writes RPM_TREE to GITHUB_ENV, publish-tree.sh, the keep step) twice over one tree,
# against a stand-in for the artifact store, for the real tree (rpm/) and the staging tree (staging/rpm/). A step that
# fails is the harness failing, never a pass. The positive control in each tree: a copy the tree does not hold where the
# keep step reads it (laid out under the other tree) is refused by the keep step, and the sabotage takes that refusal out
# and must turn the control red.
#
#   tests/rpm-rerun-layout.sh     needs rpm-build, createrepo_c, gpg and python3 with PyYAML
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
wf=$here/.github/workflows/build-rpm.yml
action=$here/.github/actions/publish-rpms
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT; [ -z "${KEEP:-}" ] || echo "$work"
fail() { echo "FAIL: $*" >&2; exit 1; }
pkg=demo

python3 - "$wf" "$action/action.yml" "$work" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))["jobs"]
action = yaml.safe_load(open(sys.argv[2]))["runs"]["steps"]
out = sys.argv[3]
def write(name, text):
    with open(f"{out}/{name}", "w") as f:
        f.write(str(text) + "\n")
def uses(job, what):
    return [s["with"] for s in wf[job]["steps"] if s.get("uses", "").startswith(what)]
write("pattern-release", uses("publish-release", "actions/download-artifact")[0]["pattern"])
write("pattern-staged", uses("publish", "actions/download-artifact")[0]["pattern"])
write("name-build", uses("build", "actions/upload-artifact")[0]["name"])
write("name-signed", uses("publish-release", "actions/upload-artifact")[0]["name"])
write("name-signed-staged", uses("publish", "actions/upload-artifact")[0]["name"])
write("keep.sh", next(s["run"] for s in action if s.get("name") == "Keep the signed copies"))
# the step that names the tree (RPM_TREE, and the staging repository file, skeleton and newest-only) for the later steps
write("tree.sh", next(s["run"] for s in action if s.get("name") == "Prove the packages are there before anything signs them")
      .replace("/tmp/collected.txt", f"{out}/collected.txt"))
PY
expand() { # expand <file> <fedora> <arch>: a workflow expression filled in as the runner would
    sed -e "s/\${{ inputs.package-name }}/$pkg/g" -e "s/\${{ matrix.fedora }}/$2/g" -e "s/\${{ matrix.arch }}/$3/g" "$1"
}

rpmfile() { # rpmfile <dir> <fedora> <arch>: an empty binary package of that cell
    local top=$work/rpmbuild
    mkdir -p "$top/SPECS" "$1"
    printf 'Name: %s\nVersion: 1.0\nRelease: 1%%{?dist}\nSummary: t\nLicense: GPL-3.0-or-later\n%%description\nt\n%%files\n' "$pkg" > "$top/SPECS/$pkg.spec"
    rpmbuild -bb --quiet --target "$3" --define "_topdir $top" --define "dist .fc$2" "$top/SPECS/$pkg.spec" >/dev/null 2>&1 ||
        fail "rpmbuild could not make the $2/$3 fixture"
    find "$top/RPMS" -name "$pkg-1.0-1.fc$2.$3.rpm" -exec mv {} "$1/" \;
    [ -f "$1/$pkg-1.0-1.fc$2.$3.rpm" ] || fail "no $2/$3 fixture package"
}

download() { # download <pattern> <dest>: what download-artifact does with merge-multiple
    local name
    mkdir -p "$2"
    for name in "$dir"/store/*/; do
        name=$(basename "$name")
        # shellcheck disable=SC2053 # the pattern is the workflow's glob
        [[ $name == $1 ]] && cp -r "$dir/store/$name/." "$2/"
    done
    return 0
}

attempt() { # attempt <n> <pattern> [keep.sh]: the publish job of one attempt; 1 when the keep step refuses a package the
    # tree does not hold, 3 when it fails for any other reason
    local n=$1 run=$dir/attempt$1 keep=${3:-$work/keep.sh}
    mkdir -p "$run"
    download "$2" "$dir/collected"
    # the action's first step writes the tree and its environment to GITHUB_ENV; the steps after it read them there
    : > "$run/github-env"
    (cd "$dir" && GITHUB_ACTION_PATH=$action RPM_DIR=collected STAGING=$staging MATRIX_SET='' CATCH_UP='' RELEASES=45 \
        KEY_FILE_IN='' COMMITTED_KEYS=true SIGNING_FPR='' REPO_FILE_IN='' CHANNEL_IN=Open-Mixer/open-mixer.github.io \
        GITHUB_ENV=$run/github-env bash "$work/tree.sh") > "$run/publish.log" 2>&1 ||
        { cat "$run/publish.log" >&2; fail "attempt $n: the tree step failed"; }
    grep -qx "RPM_TREE=$tree" "$run/github-env" || fail "attempt $n: the action names another tree than $tree"
    (cd "$dir" && set -a && . "$run/github-env" && set +a && "$action/publish-tree.sh" "build/channel/${place:-$tree}" collected) \
        >> "$run/publish.log" 2>&1 || { cat "$run/publish.log" >&2; fail "attempt $n: publish-tree.sh failed"; }
    # the keep step reads RPM_TREE from GITHUB_ENV: run alone it would die on an unbound variable, so it runs with it,
    # and only its refusal of a package the tree does not hold may fail it
    if ! (cd "$dir" && set -a && . "$run/github-env" && set +a && rm -rf signed && RPM_DIR=collected SIGNED_DIR=signed bash "$keep") \
        >> "$run/publish.log" 2>&1; then
        rm -rf "$dir/collected"
        grep -q 'is not in the tree' "$run/publish.log" && return 1
        return 3
    fi
    # the path of the upload is signed/*.rpm, so the artifact is flat
    mkdir -p "$dir/store/$signed"
    cp "$dir"/signed/*.rpm "$dir/store/$signed/" || fail "attempt $n: no kept copy to upload"
    rm -rf "$dir/collected" "$dir/signed"
}

arm() { # arm <name> <staging> <cells>: a fresh artifact store holding the builds of the cells ("<fedora>/<arch> ..."), and an
    # empty tree
    dir=$work/$1 staging=$2 tree=rpm place=
    [ "$staging" = false ] || tree=staging/rpm
    signed=$(expand "$work/name-signed" - -); [ "$staging" = false ] || signed=$(expand "$work/name-signed-staged" - -)
    mkdir -p "$dir/store" "$dir/build/channel/$tree"
    local cell
    for cell in $3; do rpmfile "$dir/store/$(expand "$work/name-build" "${cell%/*}" "${cell#*/}")" "${cell%/*}" "${cell#*/}"; done
}

kept_all() { # kept_all <attempt> <cells>: the rerun placed nothing, kept every package, and the tree holds each cell once
    local cell
    grep -q '^kept   ' "$dir/attempt$1/publish.log" || fail "$what: the rerun did not keep what the first attempt published"
    ! grep -q '^placed ' "$dir/attempt$1/publish.log" || fail "$what: the rerun placed a package again"
    for cell in $2; do
        [ -f "$dir/build/channel/$tree/fedora/${cell%/*}/${cell#*/}/$pkg-1.0-1.fc${cell%/*}.${cell#*/}.rpm" ] ||
            fail "$what: $tree/fedora/$cell does not hold its package"
    done
    [ "$(find "$dir/build/channel/$tree" -name '*.rpm' | wc -l)" = "$(echo "$2" | wc -w)" ] || fail "$what: the tree holds another count of packages than $2"
}

release=$(expand "$work/pattern-release" - -)
staged=$(expand "$work/pattern-staged" - -)
[ "$release" = "$pkg-rpms-fc*" ] && [ "$staged" = "$pkg-rpms-fc*" ] || fail "the download patterns are $release and $staged"

# the real tree: both architectures of the release, twice
what=release; arm fixed false "45/x86_64 45/aarch64"
attempt 1 "$release" || fail "release: the first attempt did not publish"
attempt 2 "$release" || fail "release: the rerun refused its own packages"
kept_all 2 "45/x86_64 45/aarch64"
[ ! -d "$dir/build/channel/staging" ] || fail "release: staging/ was written"
echo "ok   a rerun of a release keeps the packages in rpm/ and uploads the kept copies again"

# the staging tree: the tested platform alone (release-matrix/quick.txt), twice; rpm/ is never written
what=staged; arm staged-fixed true "45/x86_64"
attempt 1 "$staged" || fail "staged: the first attempt did not publish"
attempt 2 "$staged" || fail "staged: the rerun refused its own packages"
kept_all 2 "45/x86_64"
[ -z "$(find "$dir/build/channel/rpm" -name '*.rpm' -print -quit 2>/dev/null)" ] || fail "staged: rpm/ was written"
echo "ok   staged: a rerun keeps the packages in staging/rpm and leaves rpm/ alone"

# the positive control: the packages laid out under the other tree, where the keep step does not read, are refused by
# it; with that refusal taken out (the sabotage), the same run passes, so this test sees the refusal
sed '/is not in the tree/d' "$work/keep.sh" > "$work/keep-blind.sh"
grep -q 'is not in the tree' "$work/keep.sh" || fail "the keep step of publish-rpms refuses no package the tree does not hold"
! grep -q 'is not in the tree' "$work/keep-blind.sh" || fail "the sabotage did not take the refusal out"
# control <name> <staging> <keep.sh>: the status of a first attempt whose packages are placed under the other tree
control() {
    arm "$1" "$2" "45/x86_64"
    if [ "$2" = false ]; then place=staging/rpm; else place=rpm; fi
    mkdir -p "$dir/build/channel/$place"
    local st=0; attempt 1 "$release" "$3" || st=$?
    place=; return "$st"
}
for s in false true; do
    st=0; control "control-$s" "$s" "$work/keep.sh" || st=$?
    [ "$st" = 1 ] || { cat "$dir/attempt1/publish.log" >&2; fail "control ($tree): a package the tree does not hold was not refused by name (status $st): this test sees nothing"; }
    echo "ok   control ($tree): a package laid out under the other tree is refused by the keep step, by name"
    st=0; control "sabotage-$s" "$s" "$work/keep-blind.sh" || st=$?
    [ "$st" != 1 ] || fail "sabotage ($tree): with the refusal out of the keep step the control still sees it"
    echo "ok   sabotage ($tree): with the refusal out of the keep step the control goes red (status $st), so it is the refusal it sees"
done
