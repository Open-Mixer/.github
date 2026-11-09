#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A rerun of a DEB release after its publish job succeeded. The first attempt uploads the published copies as one
# more artifact of the run, laid out flat, and artifacts outlive their attempt: the download of the next attempt
# must not take them for build output, because publish-tree.sh refuses a package outside <suite>/. Runs the
# workflow's own patterns and steps twice over one tree, against a stand-in for the artifact store. The second arm
# widens the pattern to the one that took the copies in, and the refusal must come back.
#
#   tests/deb-rerun-layout.sh     needs dpkg-dev, apt-utils and python3 with PyYAML
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
wf=$here/.github/workflows/build-deb.yml
action=$here/.github/actions/publish-debs
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
write("pattern-publish", uses("publish", "actions/download-artifact")[0]["pattern"])
write("pattern-release", uses("release", "actions/download-artifact")[0]["pattern"])
write("name-build", uses("build", "actions/upload-artifact")[0]["name"])
write("name-signed", uses("publish", "actions/upload-artifact")[0]["name"])
write("attach.sh", next(s["run"] for s in wf["release"]["steps"] if s.get("name") == "Attach the DEBs to the release"))
write("keep.sh", next(s["run"] for s in action if s.get("name") == "Keep the published copies"))
PY
expand() { # expand <file> <suite> <arch>: a workflow expression filled in as the runner would
    sed -e "s/\${{ inputs.package-name }}/$pkg/g" -e "s/\${{ matrix.suite }}/$2/g" -e "s/\${{ matrix.arch }}/$3/g" "$1"
}

mkdir "$work/bin"; printf '#!/bin/sh\necho "gh $*" >> "$GH_LOG"\n' > "$work/bin/gh"; chmod +x "$work/bin/gh"

deb() { # deb <dir> <arch>
    local root=$work/pkg-$2
    mkdir -p "$root/DEBIAN" "$1"
    printf 'Package: %s\nVersion: 1.0\nArchitecture: %s\nMaintainer: t <t@example.org>\nDescription: t\n' "$pkg" "$2" > "$root/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$root" "$1/${pkg}_1.0_$2.deb" >/dev/null
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

attempt() { # attempt <n> <publish pattern> <release pattern>: the publish job, then the release job
    local n=$1 run=$dir/attempt$1
    mkdir -p "$run"
    download "$2" "$run/collected"
    mv "$run/collected" "$dir/collected"
    (cd "$dir" && "$action/publish-tree.sh" build/channel/deb collected) > "$run/publish.log" 2>&1 || { rm -rf "$dir/collected"; return 1; }
    (cd "$dir" && rm -rf signed && DEB_DIR=collected SIGNED_DIR=signed bash "$work/keep.sh") >> "$run/publish.log" 2>&1
    # the path of the upload is signed/*.deb, so the artifact is flat
    mkdir -p "$dir/store/$(expand "$work/name-signed" - -)"
    cp "$dir"/signed/*.deb "$dir/store/$(expand "$work/name-signed" - -)/"
    rm -rf "$dir/collected" "$dir/signed"
    mkdir -p "$run/release"
    download "$3" "$run/release/collected"
    (cd "$run/release" && env PATH="$work/bin:$PATH" GH_LOG="$run/gh.log" GH_TOKEN=x TAG=v1.0 GITHUB_REPOSITORY=Open-Mixer/t \
        RUNNER_TEMP="$run" bash "$work/attach.sh") >> "$run/publish.log" 2>&1
}

arm() { # arm <name>: a fresh artifact store holding the four builds, and an empty tree
    dir=$work/$1
    mkdir -p "$dir/store" "$dir/build/channel/deb"
    local suite arch
    for suite in bookworm trixie; do
        for arch in amd64 arm64; do
            deb "$dir/store/$(expand "$work/name-build" "$suite" "$arch")/$suite" "$arch"
        done
    done
}

expected="${pkg}_1.0_bookworm_amd64.deb ${pkg}_1.0_bookworm_arm64.deb ${pkg}_1.0_trixie_amd64.deb ${pkg}_1.0_trixie_arm64.deb"
check_attached() { # check_attached <attempt>: the assets the release job handed to gh
    local got
    got=$(cd "$dir/attempt$1/release/assets" && ls | tr '\n' ' ')
    [ "${got% }" = "$expected" ] || fail "attempt $1 attached: $got"
}

publish=$(expand "$work/pattern-publish" - -)
release=$(expand "$work/pattern-release" - -)

arm fixed
attempt 1 "$publish" "$release" || { cat "$dir/attempt1/publish.log" >&2; fail "the first attempt did not publish"; }
check_attached 1
attempt 2 "$publish" "$release" || { cat "$dir/attempt2/publish.log" >&2; fail "the rerun refused its own packages"; }
grep -q '^kept   ' "$dir/attempt2/publish.log" || fail "the rerun did not keep what the first attempt published"
! grep -q '^placed ' "$dir/attempt2/publish.log" || fail "the rerun placed a package again"
check_attached 2
grep -q 'upload v1.0' "$dir/attempt2/gh.log" || fail "the rerun attached nothing"
echo "ok   a rerun after a successful publish keeps the packages and attaches them"

# the positive control: the wide pattern takes the flat copies in and is refused, which is what the arm above escapes
wide="$pkg-debs-*"
arm wide
attempt 1 "$wide" "$wide" || fail "control: the first attempt did not publish"
if attempt 2 "$wide" "$wide"; then fail "control: the flat copies were not refused, this test sees nothing"; fi
grep -q 'is not laid out <suite>/<package>.deb' "$dir/attempt2/publish.log" || { cat "$dir/attempt2/publish.log" >&2; fail "control: refused for another reason"; }
echo "ok   control: a pattern that takes the flat copies in is refused"
