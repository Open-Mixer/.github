#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The promotion of a staged version to the channel (promote-staged.yml, docs/release-operations.md), offline. Proves:
#   - collect.py, on a stub channel: one staged build is found by its version and commit, with its subpackages and its
#     source package, in every release and architecture, and its checksums name the paths of the channel root;
#   - it refuses, and copies nothing, a staged tree that lacks a distribution directory the matrix has, a release
#     with no source package, a version staging does not hold, two staged commits with none named, and a release the
#     channel root serves the package for and the promotion does not cover;
#   - the workflow, rendered: nothing in it builds; a dry run signs and pushes nothing, tags nothing and creates no
#     release; a real run publishes with staging off, in the live publish group, and tags only after the channel
#     serves the bytes staging served and the install checks passed.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
collect=$here/.github/actions/promote-staged/collect.py
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }

# a stub channel: omx-lib 3.14.0 staged twice (two commits), the real tree serving 3.13.0. T is the commit time part of
# the staged names (git<commit time>.<sha>); empty gives the names staged before it was there, still found by their sha
mk() { mkdir -p "$(dirname "$1")"; echo "$1" > "$1"; }
T=
channel() { # <dir>
    local c=$1 rel a suite sha
    for sha in 5f455d3 0badc0d; do
        for rel in 44 45; do
            mk "$c/staging/rpm/fedora/$rel/SRPMS/omx-lib-3.14.0-1.git$T$sha.fc$rel.src.rpm"
            mk "$c/staging/rpm/fedora/$rel/noarch/omx-lib-data-3.14.0-1.git$T$sha.fc$rel.noarch.rpm"
            for a in x86_64 aarch64; do
                mk "$c/staging/rpm/fedora/$rel/$a/omx-lib-3.14.0-1.git$T$sha.fc$rel.$a.rpm"
                mk "$c/staging/rpm/fedora/$rel/$a/omx-lib-devel-3.14.0-1.git$T$sha.fc$rel.$a.rpm"
            done
        done
        for suite in bookworm trixie; do
            mk "$c/staging/deb/debian/$suite/all/omx-lib-data_3.14.0+git$T${sha}_all.deb"
            for a in amd64 arm64; do
                mk "$c/staging/deb/debian/$suite/$a/libomx-lib0_3.14.0+git$T${sha}_$a.deb"
                mk "$c/staging/deb/debian/$suite/$a/libomx-lib-dev_3.14.0+git$T${sha}_$a.deb"
            done
        done
    done
    # another package and another version of this one, staged beside it
    mk "$c/staging/rpm/fedora/44/x86_64/omx-other-3.14.0-1.git1234567.fc44.x86_64.rpm"
    mk "$c/staging/rpm/fedora/44/x86_64/omx-lib-3.14.1-1.git7654321.fc44.x86_64.rpm"
    mk "$c/staging/deb/debian/trixie/amd64/libomx-other0_3.14.0+git1234567_amd64.deb"
    for rel in 44 45; do mk "$c/rpm/fedora/$rel/x86_64/omx-lib-3.13.0-1.fc$rel.x86_64.rpm"; done
    mk "$c/deb/debian/trixie/amd64/libomx-lib0_3.13.0_amd64.deb"
}
rpm_args=(rpm --name omx-lib --version 3.14.0 --binaries "omx-lib omx-lib-data" --releases "44 45" --arches "x86_64 aarch64")
deb_args=(deb --name omx-lib --version 3.14.0 --binaries "libomx-lib0 omx-lib-data" --releases "bookworm trixie" --arches "amd64 arm64")
refuses() { # <what> <pattern> <collect args>...
    local what=$1 pat=$2; shift 2
    rm -rf "$t/out" "$t/out.sha256"
    if python3 -I "$collect" "$@" --out "$t/out" > "$t/log" 2>&1; then fail "$what: accepted"; fi
    grep -qE "$pat" "$t/log" || fail "$what: refused without naming it: $(cat "$t/log")"
    [ ! -e "$t/out" ] || fail "$what: refused, and files were copied"
    ok "refused: $what"
}

channel "$t/c"
# ---- one staged build, found whole
python3 -I "$collect" "$t/c" "${rpm_args[@]}" --commit 5f455d3 --out "$t/rpm" > "$t/log" || fail "the rpm collect failed: $(cat "$t/log")"
[ "$(find "$t/rpm" -name '*.rpm' | wc -l)" = 12 ] || fail "rpm: $(find "$t/rpm" -name '*.rpm' | wc -l) files, not the 12 of the commit"
! find "$t/rpm" -name '*0badc0d*' -o -name 'omx-other*' -o -name '*3.14.1*' | grep -q . || fail "rpm: a file of another commit, package or version went along"
[ "$(tail -1 "$t/log")" = "commit 5f455d3" ] || fail "rpm: the commit is not the last line"
grep -q "  rpm/fedora/45/aarch64/omx-lib-devel-3.14.0-1.git5f455d3.fc45.aarch64.rpm$" "$t/rpm.sha256" || fail "rpm: the checksums do not name the channel root"
(cd "$t/c/staging" && sha256sum -c --quiet "$t/rpm.sha256") || fail "rpm: a checksum is not that of the staged file"
ok "rpm: the 12 files of one commit, with checksums by their path in the channel root"
python3 -I "$collect" "$t/c" "${deb_args[@]}" --commit 5f455d3c0ffee --out "$t/deb" > "$t/log" || fail "the deb collect failed: $(cat "$t/log")"
[ "$(find "$t/deb" -name '*.deb' | wc -l)" = 10 ] || fail "deb: $(find "$t/deb" -name '*.deb' | wc -l) files, not the 10 of the commit"
[ -f "$t/deb/bookworm/omx-lib-data_3.14.0+git5f455d3_all.deb" ] && [ -f "$t/deb/trixie/libomx-lib-dev_3.14.0+git5f455d3_arm64.deb" ] ||
    fail "deb: not laid out <suite>/<file>"
ok "deb: the 10 files of one commit, laid out by suite; a full commit names its short one"

# ---- the same with the commit time before the sha, rpm and deb
T=1794480000. channel "$t/n"
python3 -I "$collect" "$t/n" "${rpm_args[@]}" --commit 5f455d3 --out "$t/nrpm" > "$t/log" || fail "the rpm collect of the names with a commit time failed: $(cat "$t/log")"
[ "$(find "$t/nrpm" -name '*.git1794480000.5f455d3.*' | wc -l)" = 12 ] || fail "rpm: not the 12 files of the commit under the names with a commit time"
python3 -I "$collect" "$t/n" "${deb_args[@]}" --commit 5f455d3 --out "$t/ndeb" > "$t/log" || fail "the deb collect of the names with a commit time failed: $(cat "$t/log")"
[ "$(find "$t/ndeb" -name '*+git1794480000.5f455d3_*' | wc -l)" = "$(find "$t/n/staging/deb" -name '*+git1794480000.5f455d3_*' | wc -l)" ] || fail "deb: not every file of the commit under the names with a commit time"
refuses "two staged commits with a commit time, none named" 'of 2 commits \(0badc0d 5f455d3\)' "$t/n" "${rpm_args[@]}"
ok "the staged names with a commit time before the sha are found by their sha"
# ---- the refusals
refuses "two staged commits, none named" 'of 2 commits \(0badc0d 5f455d3\)' "$t/c" "${rpm_args[@]}"
refuses "a version staging does not hold" 'holds no omx-lib 3.15.0' "$t/c" rpm --name omx-lib --version 3.15.0 --releases 44 --arches x86_64
refuses "a commit staging does not hold" 'holds no omx-lib 3.14.0 of commit abcdef0' "$t/c" "${rpm_args[@]}" --commit abcdef0
channel "$t/d"; rm -rf "$t/d/staging/rpm/fedora/45/aarch64" "$t/d/staging/deb/debian/bookworm/arm64"
refuses "rpm: a missing distribution directory" 'staging/rpm/fedora/45/aarch64 holds no omx-lib 3.14.0 of 5f455d3' "$t/d" "${rpm_args[@]}" --commit 5f455d3
refuses "deb: a missing distribution directory" 'staging/deb/debian/bookworm/arm64 holds no libomx-lib0 3.14.0 of 5f455d3' "$t/d" "${deb_args[@]}" --commit 5f455d3
channel "$t/e"; rm "$t/e/staging/rpm/fedora/44/SRPMS/omx-lib-3.14.0-1.git5f455d3.fc44.src.rpm" "$t/e/staging/deb/debian/trixie/all/omx-lib-data_3.14.0+git5f455d3_all.deb"
refuses "rpm: a release with no source package" 'fedora/44/SRPMS holds no source package' "$t/e" "${rpm_args[@]}" --commit 5f455d3
refuses "deb: an all package missing from one suite" 'debian/trixie/amd64 holds no omx-lib-data' "$t/e" "${deb_args[@]}" --commit 5f455d3
channel "$t/f"; mk "$t/f/rpm/fedora/43/x86_64/omx-lib-3.12.0-1.fc43.x86_64.rpm"; mk "$t/f/deb/debian/forky/amd64/libomx-lib0_3.12.0_amd64.deb"
refuses "rpm: a release the channel serves and the promotion lacks" 'serves omx-lib in rpm/fedora/43' "$t/f" "${rpm_args[@]}" --commit 5f455d3
refuses "deb: a suite the channel serves and the promotion lacks" 'serves libomx-lib0 in deb/debian/forky' "$t/f" "${deb_args[@]}" --commit 5f455d3

# ---- the workflow, rendered
wf=$here/.github/workflows/promote-staged.yml
cat > "$t/wf.py" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1])); jobs = d["jobs"]
text = lambda j: yaml.safe_dump(jobs[j])
def uses(j, what): return [s for s in jobs[j]["steps"] if f"/{what}@" in s.get("uses", "")]
for j in jobs:
    assert not re.search(r"rpmbuild|dpkg-buildpackage|debuild|\bmock\b|workflows/build-(rpm|deb)\.yml|actions/(rpm|deb)-deps@|rpmsign|--addsign", text(j)), \
        f"job {j} builds or signs a package"
for j, pub in (("rpm", "publish-rpms"), ("deb", "publish-debs")):
    steps = jobs[j]["steps"]
    names = [s.get("uses", "").split("/")[-1].split("@")[0] for s in steps]
    assert "promote-staged" in names and pub in names and names.index("promote-staged") < names.index(pub), f"job {j}: the publish is not after the collect"
    c = uses(j, "promote-staged")[0]["with"]
    assert c.get("vouch", "true") == "true", f"job {j} publishes without the signature check"
    assert c["commit"] == "${{ needs.find.outputs.short }}", f"job {j} does not promote the commit the find job checked"
    w = uses(j, pub)[0]["with"]
    assert w["staging"] is False, f"job {j} publishes to staging"
    assert w["sign"] == "${{ !inputs.dry-run }}", f"job {j}: a dry run signs and pushes"
    assert w[f"{j}-dir"] == c["out"], f"job {j} publishes another directory than the collected one"
    assert jobs[j]["concurrency"] == {"group": "publish-${{ inputs.target-repo }}-${{ !inputs.dry-run && 'live' || github.run_id }}",
                                      "cancel-in-progress": False}, f"job {j} is not in the publish group of the channel"
    after = steps[names.index(pub) + 1]
    assert "sha256sum -c" in after.get("run", ""), f"job {j} does not compare the tree with the staged checksums right after the publish"
need = lambda j: set(jobs[j]["needs"] if isinstance(jobs[j]["needs"], list) else [jobs[j]["needs"]])
assert {"rpm", "deb"} <= need("served") and "!inputs.dry-run" in jobs["served"]["if"], "the served check does not follow both publishes, or runs on a dry run"
for j in ("verify-rpm", "verify-deb"):
    assert "served" in need(j) and "needs.served.result == 'success'" in jobs[j]["if"], f"{j} runs without the served bytes"
    assert all("staging" not in (s.get("with") or {}) for s in uses(j, "add-openmixer")), f"{j} adds the staging channel"
r = jobs["release"]
assert {"served", "verify-rpm", "verify-deb"} <= need("release"), "the tag does not wait for the served bytes and the install checks"
want = ["!cancelled()", "!inputs.dry-run", "needs.served.result == 'success'",
        "(needs.verify-rpm.result == 'success' || needs.verify-rpm.result == 'skipped')",
        "(needs.verify-deb.result == 'success' || needs.verify-deb.result == 'skipped')"]
got = [c.strip() for c in re.sub(r"^\$\{\{|\}\}$", "", r["if"].strip()).split("&&")]
assert sorted(got) == sorted(want), f"the release job runs on another condition than the five this test knows: {r['if']}"
for j in jobs:
    writes = (jobs[j].get("permissions") or {}).get("contents") == "write"
    assert writes == (j == "release"), f"job {j}: contents write is for the release job alone"
    if j != "release":
        assert not re.search(r"git/refs|gh release (create|upload)|git (tag|push)", text(j)), f"job {j} tags or releases"
assert d["permissions"] == {"contents": "read"}
tag = [s for s in r["steps"] if "git/refs" in s.get("run", "")]
assert len(tag) == 1 and "needs.find.outputs.commit" in tag[0]["env"]["COMMIT"], "the tag is not on the commit the find job resolved"
find = text("find")
assert "merge-base --is-ancestor" in find and "secrets." not in find, "the find job does not check the commit, or reads a secret"
PY
python3 -I "$t/wf.py" "$wf" || fail "the workflow is not the promotion its header describes"
ok "workflow: nothing builds or signs a package; a dry run pushes, tags and releases nothing; the tag waits for the served bytes and the install checks"
sab() { # <what> <sed expression>
    sed "$2" "$wf" > "$t/sab.yml"
    ! cmp -s "$wf" "$t/sab.yml" || fail "sabotage: $1 changed nothing"
    if python3 -I "$t/wf.py" "$t/sab.yml" >/dev/null 2>&1; then fail "sabotage: $1 passes"; fi
    ok "sabotage: $1 is red"
}
sab "a release job that runs on a dry run" '/^  release:/,$ s/ && !inputs.dry-run//'
sab "a publish that signs on a dry run" 's/sign: ${{ !inputs.dry-run }}/sign: true/'
sab "a publish to staging" 's/staging: false/staging: true/'
sab "a tag that does not wait for the install checks" 's/needs: \[find, served, verify-rpm, verify-deb\]/needs: [find, served]/'
sab "a publish without the signature check" "s/^          out: promote\/rpm$/&\n          vouch: 'false'/"
sab "a publish outside the channel's group" "s/&& 'live' || github.run_id/\&\& 'promote' || github.run_id/"
sab "a find job that skips the default branch check" '/merge-base --is-ancestor/d'
echo "promote-staged: all passed"
