#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The noarch pin guard of publish-tree.sh judges only the architectures the release matrix publishes (Open-Mixer/.github#135).
# While the matrix is quick no aarch64 rpm is built and a quick release placed its noarch packages in the x86_64 trees; the
# regeneration of the channel (the prune of open-mixer.github.io, no MATRIX_SET) refused them for aarch64, an architecture
# nobody publishes. The architectures come from release-matrix/matrix.sh, the script the releases read, never a second list,
# and no kept package is relabelled.
#
# The fixture is omx-clap-core on fc44 (as tests/noarch-pin.sh): x86_64 and aarch64 0.32.3 with contract 0.32.3 in noarch, then
# a run of 0.32.4 with its noarch contract 0.32.4.
# Proves:
#   - the matrix is quick (OMX_RELEASE_MATRIX=quick, no MATRIX_SET) and the run builds x86_64: the aarch64 skew is not judged,
#     the run publishes, and cells.tsv records no set for it (nothing is relabelled);
#   - the matrix is full (OMX_RELEASE_MATRIX=full, unset, or MATRIX_SET=full): the same run is refused at main, naming aarch64,
#     and the tree is byte-identical after;
#   - a skew inside a published architecture stays red while the matrix is quick: a run that builds aarch64 alone leaves
#     x86_64's omx-clap-core 0.32.3 behind and is refused naming x86_64, and aarch64 is not named;
#   - an EMPTY published-architecture set (a matrix.sh that publishes no cell for the release) is refused by name, nothing
#     placed, never judged as nothing to check.
# Sabotage: NOARCH_PIN_ACTIONS names a copy of the actions with the architecture filter taken out; the first arm then goes red.
#
#   noarch-pin-matrix-arches.sh     in a Fedora container with rpm-build rpm-sign createrepo_c python3-rpm gnupg2 pinentry findutils zstd diffutils
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
actions=${NOARCH_PIN_ACTIONS:-$here/.github/actions}
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
tree=$work/tree

snapshot() { (cd "$tree" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$1"; }
build() { # <out dir> <version> <arch>: omx-clap-core and its noarch contract, which the binary package pins exactly
    local id=$2-$3 spec
    spec=$work/$id.spec
    printf '%s\n' 'Name: omx-clap-core' "Version: $2" 'Release: 1.fc44' 'Summary: t' 'License: MIT' "Requires: omx-clap-core-contract = $2-1.fc44" \
        '%description' 'core' '%package contract' 'Summary: t' 'BuildArch: noarch' '%description contract' 'contract' '%files' '%files contract' > "$spec"
    rpmbuild -bb --quiet --define "_topdir $work/rb-$id" --define 'dist %{nil}' --define 'debug_package %{nil}' \
        --target "$3" "$spec" >/dev/null 2>&1 || fail "rpmbuild $id"
    mkdir -p "$1"
    find "$work/rb-$id" -name '*.rpm' -exec cp {} "$1/" \;
}
# a run with no MATRIX_SET, as the regeneration of the channel makes it; OMX_RELEASE_MATRIX is the matrix the releases read
regen() { # <wave or empty> <rpm dir>
    MATRIX_SET= OMX_RELEASE_MATRIX=$1 "$actions/publish-rpms/publish-tree.sh" "$tree" "$2" "$key"
}

# ---- the channel as the quick wave left it: 0.32.3 on both architectures, published whole
build "$work/r0" 0.32.3 x86_64
build "$work/r0" 0.32.3 aarch64
MATRIX_SET=full "$actions/publish-rpms/publish-tree.sh" "$tree" "$work/r0" "$key" > "$work/log" 2>&1 || { cat "$work/log"; fail "the fixture channel could not be published"; }
cp -a "$tree" "$work/tree0"
build "$work/r1" 0.32.4 x86_64      # 0.32.4 built for x86_64 alone, aarch64 still on 0.32.3: the skew of the issue
restore() { rm -rf "$tree"; cp -a "$work/tree0" "$tree"; }

# ---- 1. the matrix is quick: aarch64 is not published, so its skew is not judged; no kept package is relabelled
restore
cells0=$(cat "$tree/cells.tsv")
regen quick "$work/r1" > "$work/log" 2>&1 || { cat "$work/log"; fail "a regeneration under the quick matrix was refused for aarch64, which the matrix does not publish"; }
[ -f "$tree/fedora/44/noarch/omx-clap-core-contract-0.32.4-1.fc44.noarch.rpm" ] || fail "the contract 0.32.4 is not placed"
# the new version takes no set ('-'); every line the tree had keeps its set (here: full)
while IFS= read -r l; do
    grep -qxF -- "$l" "$tree/cells.tsv" || { diff <(echo "$cells0") "$tree/cells.tsv" || true; fail "a regeneration with no MATRIX_SET relabelled a kept line of cells.tsv: $l"; }
done <<< "$cells0"
grep -q $'^omx-clap-core\t0.32.4\t-\t' "$tree/cells.tsv" || { cat "$tree/cells.tsv"; fail "the regeneration recorded a set for 0.32.4 although it names none"; }
ok "under the quick matrix the aarch64 skew is not judged, and no line of cells.tsv is relabelled"

# ---- 2. the matrix is full, unset, or MATRIX_SET=full: the same run is refused at main
for w in full ''; do
    restore
    snapshot "$work/before"
    if regen "$w" "$work/r1" > "$work/log" 2>&1; then cat "$work/log"; fail "OMX_RELEASE_MATRIX='$w': a run that left aarch64 on 0.32.3 published"; fi
    grep -q 'not built for aarch64' "$work/log" || { cat "$work/log"; fail "OMX_RELEASE_MATRIX='$w': the refusal does not name aarch64"; }
    grep -q 'nothing was placed or signed' "$work/log" || { cat "$work/log"; fail "OMX_RELEASE_MATRIX='$w': the refusal does not say nothing was placed"; }
    snapshot "$work/after"
    cmp -s "$work/before" "$work/after" || fail "OMX_RELEASE_MATRIX='$w': the refused run changed the tree"
done
restore
if MATRIX_SET=full "$actions/publish-rpms/publish-tree.sh" "$tree" "$work/r1" "$key" > "$work/log" 2>&1; then cat "$work/log"; fail "MATRIX_SET=full published the aarch64 skew"; fi
grep -q 'not built for aarch64' "$work/log" || { cat "$work/log"; fail "MATRIX_SET=full: the refusal does not name aarch64"; }
ok "under the full matrix (set by the variable, by its absence, or by MATRIX_SET) the aarch64 skew is refused at main and the tree is unchanged"

# ---- 3. a skew inside a published architecture stays red under the quick matrix
restore
build "$work/r3" 0.32.4 aarch64     # aarch64 alone: x86_64 keeps omx-clap-core 0.32.3 under a contract 0.32.4
snapshot "$work/before"
if regen quick "$work/r3" > "$work/log" 2>&1; then cat "$work/log"; fail "a skew on x86_64, which the quick matrix publishes, was published"; fi
grep -q 'not built for x86_64' "$work/log" || { cat "$work/log"; fail "the refusal does not name x86_64"; }
grep -q 'not built for aarch64' "$work/log" && fail "the refusal names aarch64, which the quick matrix does not publish"
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused run changed the tree"
ok "a skew inside a published architecture (x86_64, quick matrix) is still refused, naming it"

# ---- 4. an empty published set is refused by name, never judged as nothing to check
restore
cp -a "$actions" "$work/empty-actions"
cat > "$work/empty-actions/release-matrix/matrix.sh" <<'SH'
#!/bin/bash
echo 'cells=[]' >> "${GITHUB_OUTPUT:-/dev/stdout}"
SH
snapshot "$work/before"
if MATRIX_SET= OMX_RELEASE_MATRIX=quick REPO_FILE=$here/packaging/openmixer-release/openmixer.repo "$work/empty-actions/publish-rpms/publish-tree.sh" "$tree" "$work/r1" "$key" > "$work/log" 2>&1; then
    cat "$work/log"; fail "an empty published-architecture set was judged as nothing to check"
fi
grep -q 'the release matrix publishes no architecture for fc44' "$work/log" || { cat "$work/log"; fail "the empty set is not refused by name"; }
snapshot "$work/after"
cmp -s "$work/before" "$work/after" || fail "the refused run changed the tree"
ok "an empty published-architecture set is refused by name, nothing placed"
echo "noarch-pin-matrix-arches: all passed"
