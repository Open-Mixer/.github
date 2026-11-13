#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A catch-up run plans only the cells a served version lacks (docs/release-operations.md, "Catching a served version
# up"), offline. matrix.sh is run as the first job runs it, against a fixture cells.tsv shaped like the channel's on
# 2026-11-13: plugin-qualify 0.20.4 served for fc44 x86_64, fc45 x86_64 and trixie arm64, three of the four quick
# cells, with its language packs arch-independent (noarch, all). Proves:
#   - the deb run plans exactly trixie amd64, the missing cell; the rpm run plans nothing and says so (count 0, cells
#     []), and so does a version served in every cell of the set;
#   - an arch-independent package (all, noarch) serves every cell of its release and is never judged there, so a
#     release naming one beside an arch package still plans the arch package's missing cell;
#   - with the full matrix, only the set's missing cells are planned, never a served one and never one outside the set;
#   - refused by name: a version the channel does not serve at all, a package of the release with no line at that
#     version, a cell some packages serve and others lack, a tag that names no version, no cells.tsv;
#   - the workflows: build-rpm.yml and build-deb.yml take a catch-up input, hand it to release-matrix with the package
#     names and the channel, to the preflight and to the publish, build and publish nothing when the plan is empty,
#     and record no set of their own in cells.tsv; publish-rpms and publish-debs hand it to the tree script, the
#     lost-race rebuild included; plugin-qualify-shaped callers can pass it;
#   - sabotage: matrix.sh with the subtraction taken out plans the served cells again, and this test goes red.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
matrix=${MATRIX_SH:-$here/.github/actions/release-matrix/matrix.sh}

printf '# package\tversion\tset\tcells\n' > "$t/deb.tsv"
printf '%s\t%s\t%s\t%s\n' \
    plugin-qualify 0.20.3 - 'bookworm/amd64 bookworm/arm64 trixie/amd64 trixie/arm64' \
    plugin-qualify 0.20.4 quick 'trixie/arm64' \
    plugin-qualify 0.20.5 quick 'trixie/amd64 trixie/arm64' \
    plugin-qualify-l10n-ca 0.20.4 quick 'trixie/all' \
    plugin-qualify-l10n-de 0.20.4 quick 'trixie/all' \
    libfoo1 1.0.0 full 'bookworm/amd64 bookworm/arm64 trixie/arm64' \
    libfoo-dev 1.0.0 full 'bookworm/amd64 bookworm/arm64 trixie/arm64 trixie/amd64' \
    libbar1 2.0.0 full 'bookworm/amd64 bookworm/arm64 trixie/arm64' \
    bar-contract 2.0.0 full 'bookworm/all trixie/all' \
    >> "$t/deb.tsv"
printf '# package\tversion\tset\tcells\n' > "$t/rpm.tsv"
printf '%s\t%s\t%s\t%s\n' \
    plugin-qualify 0.20.4 quick 'fc44/x86_64 fc45/x86_64' \
    plugin-qualify-langpack-ca 0.20.4 quick 'fc44/noarch fc45/noarch' \
    omx-thing 0.3.0 full 'fc44/aarch64 fc45/aarch64 fc45/x86_64' \
    >> "$t/rpm.tsv"

# plan <kind> <tag> <names> [matrix] [releases] [arches]: runs matrix.sh as a catch-up, its outputs in $t/out
plan() {
    local kind=$1 rel arch
    if [ "$kind" = rpm ]; then rel='["44", "45"]' arch='["x86_64", "aarch64"]'; else rel='["bookworm", "trixie"]' arch='["amd64", "arm64"]'; fi
    env -i PATH=/usr/bin:/bin KIND="$kind" MATRIX="${4:-quick}" RELEASES="${5:-$rel}" ARCHES="${6:-$arch}" EVENT=workflow_dispatch \
        REF_TYPE=branch SOURCE_REF="$2" CATCH_UP=true CELLS_TSV="${TSV:-$t/$kind.tsv}" NAMES="$3" GITHUB_OUTPUT="$t/out" \
        bash "$matrix" > "$t/log" 2>&1
}
out() { sed -n "s/^$1=//p" "$t/out"; }
refused() { # <what> <pattern the refusal names> <plan args...>
    local what=$1 pat=$2
    shift 2
    : > "$t/out"
    if plan "$@"; then cat "$t/log"; fail "$what was planned"; fi
    grep -q "::error::catch-up: .*$pat" "$t/log" || { cat "$t/log"; fail "the refusal of $what does not name $pat"; }
    [ ! -s "$t/out" ] || fail "$what wrote outputs before it was refused"
}

: > "$t/out"; plan deb v0.20.4 plugin-qualify || { cat "$t/log"; fail "the deb catch-up of plugin-qualify v0.20.4 failed"; }
[ "$(out cells)" = '[{"suite":"trixie","arch":"amd64"}]' ] || { cat "$t/log" "$t/out"; fail "the deb catch-up planned $(out cells), not trixie amd64 alone"; }
[ "$(out count)" = 1 ] && [ "$(out releases)" = trixie ] && [ "$(out first-arch)" = amd64 ] && [ "$(out set)" = quick ] ||
    fail "the deb catch-up outputs are not count 1, trixie, amd64, quick: $(cat "$t/out")"
grep -q 'trixie/arm64 already serves plugin-qualify 0.20.4: not built' "$t/log" || fail "the served cell is not named as left out: $(cat "$t/log")"
grep -q 'catch-up of v0.20.4' "$t/log" || fail "the plan does not say it is a catch-up"
ok "deb: plugin-qualify v0.20.4, served in trixie arm64, plans trixie amd64 alone"

: > "$t/out"; plan rpm v0.20.4 plugin-qualify || { cat "$t/log"; fail "the rpm catch-up of plugin-qualify v0.20.4 failed"; }
[ "$(out cells)" = '[]' ] && [ "$(out count)" = 0 ] && [ -z "$(out first-arch)" ] ||
    { cat "$t/log" "$t/out"; fail "the rpm catch-up of a version served in both quick rpm cells planned $(out cells)"; }
grep -q 'nothing is missing, this run builds nothing' "$t/log" || fail "an empty plan does not say so"
ok "rpm: the same version, served in fc44 and fc45 x86_64, plans nothing and says so"

: > "$t/out"; plan deb v0.20.5 plugin-qualify || { cat "$t/log"; fail "a whole version failed"; }
[ "$(out cells)" = '[]' ] && [ "$(out count)" = 0 ] || fail "a version served in every quick cell planned $(out cells)"
ok "deb: a version served in every quick cell plans nothing"

: > "$t/out"; plan deb v0.20.4 'plugin-qualify plugin-qualify-l10n-*' || { cat "$t/log"; fail "an arch package beside arch-independent ones failed"; }
[ "$(out cells)" = '[{"suite":"trixie","arch":"amd64"}]' ] || fail "with its language packs named, the deb catch-up planned $(out cells)"
: > "$t/out"; plan deb v0.20.4 'plugin-qualify-l10n-*' || { cat "$t/log"; fail "an all-only release failed"; }
[ "$(out count)" = 0 ] || fail "packages served in trixie/all planned $(out cells): all serves every cell of its release"
: > "$t/out"; plan rpm v0.20.4 'plugin-qualify-langpack-*' || { cat "$t/log"; fail "a noarch-only release failed"; }
[ "$(out count)" = 0 ] || fail "packages served in fc44/noarch and fc45/noarch planned $(out cells)"
: > "$t/out"; plan deb v2.0.0 'libbar1 bar-contract' || { cat "$t/log"; fail "an arch library beside its all package failed"; }
[ "$(out cells)" = '[{"suite":"trixie","arch":"amd64"}]' ] || fail "libbar1 with its all package planned $(out cells)"
ok "arch-independent packages (all, noarch) serve their whole release and are never judged against the arch ones"

: > "$t/out"; plan deb v0.20.4 plugin-qualify full || { cat "$t/log"; fail "the full-matrix catch-up failed"; }
[ "$(out cells)" = '[{"suite":"bookworm","arch":"amd64"},{"suite":"bookworm","arch":"arm64"},{"suite":"trixie","arch":"amd64"}]' ] ||
    fail "the full-matrix catch-up planned $(out cells)"
: > "$t/out"; plan rpm v0.3.0 omx-thing full || { cat "$t/log"; fail "the full rpm catch-up failed"; }
[ "$(out cells)" = '[{"fedora":"44","arch":"x86_64"}]' ] && [ "$(out first-arch)" = x86_64 ] ||
    fail "omx-thing, missing fc44 x86_64 alone, planned $(out cells) (first arch $(out first-arch))"
: > "$t/out"; plan rpm v0.3.0 omx-thing quick '["44", "45"]' '["x86_64"]' || { cat "$t/log"; fail "the quick rpm catch-up failed"; }
[ "$(out cells)" = '[{"fedora":"44","arch":"x86_64"}]' ] || fail "the quick rpm catch-up planned $(out cells), outside the set or served"
ok "the full matrix plans its missing cells only; aarch64, outside the quick set, is never planned by a quick run"

refused "a version the channel does not serve" 'serves no plugin-qualify 0.21.0 at all' deb v0.21.0 plugin-qualify
refused "a package of the release with no line at the version" 'no plugin-qualify-extra 0.20.4' deb v0.20.4 'plugin-qualify plugin-qualify-extra'
refused "a cell one package serves and another lacks" 'trixie/amd64 serves libfoo-dev 1.0.0 but not libfoo1' deb v1.0.0 'libfoo1 libfoo-dev'
refused "a tag that names no version" "'main' is not v<version>" deb main plugin-qualify
TSV=$t/none refused "a run with no cells.tsv" 'no cells.tsv' deb v0.20.4 plugin-qualify
printf 'not a header\n' > "$t/bad.tsv"
TSV=$t/bad.tsv refused "a run on a file that is not a cells.tsv" 'not a cells.tsv' deb v0.20.4 plugin-qualify
refused "a run with no tag" 'needs the tag' deb '' plugin-qualify
ok "refused by name: an unserved version, a missing package, a half-served cell, a tag with no version, no cells.tsv"

# without CATCH_UP nothing changes: the same deb run builds both quick cells
env -i PATH=/usr/bin:/bin KIND=deb MATRIX=quick RELEASES='["bookworm", "trixie"]' ARCHES='["amd64", "arm64"]' EVENT=workflow_dispatch \
    SOURCE_REF=v0.20.4 CELLS_TSV="$t/deb.tsv" NAMES=plugin-qualify GITHUB_OUTPUT="$t/plain" bash "$matrix" > /dev/null
grep -qx 'cells=\[{"suite":"trixie","arch":"amd64"},{"suite":"trixie","arch":"arm64"}\]' "$t/plain" || fail "a run that is not a catch-up planned $(cat "$t/plain")"
ok "a run that is not a catch-up builds the set as before"

# ---- the workflows hand catch-up on, and an empty plan builds and publishes nothing
python3 -I - "$here" <<'PY'
import sys, yaml
here = sys.argv[1]
def load(p):
    with open(f"{here}/{p}") as f:
        return yaml.safe_load(f)
for kind in ("rpm", "deb"):
    wf = load(f".github/workflows/build-{kind}.yml")
    inp = wf[True]["workflow_call"]["inputs"]
    c = inp.get("catch-up")
    assert c and c["type"] == "boolean" and c["default"] is False, f"build-{kind}.yml has no boolean catch-up input defaulting to false"
    jobs = wf["jobs"]
    pre = jobs["preflight"]
    assert pre["outputs"].get("count") == "${{ steps.matrix.outputs.count }}", f"build-{kind}.yml's preflight does not output the planned count"
    m = [s for s in pre["steps"] if s.get("id") == "matrix"][0]["with"]
    assert m.get("catch-up") == "${{ inputs.catch-up }}", f"build-{kind}.yml does not hand catch-up to release-matrix"
    assert m.get("names") == "${{ inputs.binary-names || inputs.package-name }}", f"build-{kind}.yml does not name the packages to release-matrix"
    assert m.get("channel") == "${{ inputs.target-repo }}" and m.get("token") == "${{ secrets.PAGES_TOKEN }}", \
        f"build-{kind}.yml does not give release-matrix the channel to read cells.tsv from"
    pf = [s for s in pre["steps"] if "release-preflight" in s.get("uses", "")][0]["with"]
    assert pf.get("catch-up") == "${{ inputs.catch-up }}", f"build-{kind}.yml does not hand catch-up to the preflight"
    assert "needs.preflight.outputs.count != '0'" in jobs["build"]["if"], f"build-{kind}.yml builds on an empty plan"
    assert "needs.preflight.outputs.count != '0'" in jobs["publish"]["if"], f"build-{kind}.yml publishes on an empty plan"
    pub = [s for s in jobs["publish"]["steps"] if s.get("id") == "publish"][0]["with"]
    assert pub.get("catch-up") == "${{ inputs.catch-up }}", f"build-{kind}.yml does not hand catch-up to the publish"
    assert pub.get("matrix-set") == "${{ !inputs.catch-up && needs.preflight.outputs.set || '' }}", \
        f"build-{kind}.yml records a set of its own on a catch-up (cells.tsv must keep the version's)"
    act = load(f".github/actions/publish-{kind}s/action.yml")
    assert act["inputs"].get("catch-up", {}).get("default") == "false", f"publish-{kind}s has no catch-up input"
    first = act["runs"]["steps"][1]
    assert first["env"].get("CATCH_UP") == "${{ inputs.catch-up }}" and 'echo "CATCH_UP=$CATCH_UP" >> "$GITHUB_ENV"' in first["run"], \
        f"publish-{kind}s does not put CATCH_UP in the job's environment, where the tree script and the rebuild read it"
ra = load(".github/actions/release-matrix/action.yml")
for i in ("catch-up", "names", "channel", "token"):
    assert i in ra["inputs"], f"release-matrix takes no {i}"
assert ra["outputs"].get("count"), "release-matrix outputs no count"
pfa = load(".github/actions/release-preflight/action.yml")
assert pfa["inputs"].get("catch-up", {}).get("default") == "false", "release-preflight has no catch-up input"
rp = load(".github/actions/publish-rpms/action.yml")
pull = [s for s in rp["runs"]["steps"] if "channel-pull" in s.get("uses", "")][0]["with"]
assert "inputs.catch-up == 'true' && 'none'" in pull["strip"], "a catch-up rpm publish strips the served repodata it must keep"
print("ok   build-rpm.yml and build-deb.yml hand catch-up to the plan, the preflight and the publish; an empty plan builds nothing")
PY

# ---- sabotage: the subtraction taken out of matrix.sh
if [ -z "${MATRIX_SH:-}" ]; then
    cp "$(dirname "$matrix")/quick.txt" "$t/quick.txt"
    sed '/^    cells=(\${keep\[@\]+"\${keep\[@\]}"})$/d' "$matrix" > "$t/matrix-sab.sh"
    ! cmp -s "$matrix" "$t/matrix-sab.sh" || fail "the sabotage did not change matrix.sh"
    if MATRIX_SH=$t/matrix-sab.sh bash "$0" > "$t/sab.log" 2>&1; then cat "$t/sab.log"; fail "with the subtraction taken out, a served cell was planned and this test stayed green"; fi
    grep -q 'FAIL: the deb catch-up planned' "$t/sab.log" || { cat "$t/sab.log"; fail "the sabotage went red for another reason"; }
    ok "sabotage: matrix.sh without the subtraction plans the served trixie arm64 cell, and this test goes red"
fi
echo "catch-up-plan: the missing cells only, an empty plan builds nothing, refusals by name"
