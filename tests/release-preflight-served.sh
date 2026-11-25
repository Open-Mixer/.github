#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# release-preflight refuses a release of a version the channel already serves, naming the file: the step is read out
# of the action file and run against a stub curl that answers the repository and its tree. Arms: a new version passes;
# the same rpm version, the same deb version (with and without a revision) and a glob name are refused with the file
# named; another package at that version passes; republish lets it through; a dry run and a branch run never ask;
# a deb release passes over the rpms of its own version (its rpm job published them) and refuses its own debs, and the
# same the other way round. Per release: an rpm release for fc45 passes over the same version served for fc44 only and
# is refused once fc45 holds it, a release for fc44 and fc45 is refused by the fc44 file, a deb release for bookworm
# passes over the trixie deb and one for trixie is refused; and with the per-release filter taken out of
# already-served.sh, the fc45 arm goes red. A catch-up (catch-up: true) is not refused by the version it catches up: its
# plan holds only cells the channel lacks and its publish refuses to write any file the channel holds; catch-up with
# republish is refused, since one never rewrites a served file and the other does; a dry-run catch-up never reads the
# tree.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/release-preflight
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
python3 -I - "$act/action.yml" "$tmp/step.sh" <<'PY'
import sys
t = open(sys.argv[1]).read()
body = t.split("      run: |\n", 1)[1]
open(sys.argv[2], "w").write("".join(l[8:] if l.startswith("        ") else l for l in body.splitlines(True)))
PY
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/bash
out= url=${@: -1}
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
echo "$url" >> "$TREE_DIR/asked"
case $url in
  */git/trees/*) cp "$TREE_DIR/tree.json" "$out" ;;
  */contents/staging/rpm/built/foo/1.5.0.commit) cat "$TREE_DIR/record" > "$out" ;;
  */contents/*) echo '{"message":"Not Found"}' > "$out"; printf 404; exit 0 ;;
  *) echo '{"permissions":{"push":true},"visibility":"public","default_branch":"main"}' > "$out" ;;
esac
printf 200
STUB
chmod +x "$tmp/bin/curl"
cat > "$tmp/tree.json" <<'J'
{"truncated":false,"tree":[
 {"path":"rpm/fedora/44/x86_64/foo-1.2.3-1.fc44.x86_64.rpm"},
 {"path":"rpm/fedora/44/x86_64/foo-devel-1.4.0-1.fc44.x86_64.rpm"},
 {"path":"deb/debian/trixie/amd64/bar_2.0.0-1_amd64.deb"},
 {"path":"deb/debian/trixie/amd64/libbaz-dev_3.1.0_amd64.deb"},
 {"path":"rpm/fedora/44/x86_64/repodata/repomd.xml"},
 {"path":"rpm/fedora/44/noarch/qux-devel-0.5.0-1.fc44.noarch.rpm"},
 {"path":"rpm/fedora/45/x86_64/foo-devel-1.4.0-1.fc45.x86_64.rpm"},
 {"path":"staging/rpm/fedora/45/x86_64/foo-1.5.0-1.fc45.x86_64.rpm"},
 {"path":"staging/rpm/built/foo/1.5.0.commit"},
 {"path":"staging/rpm/fedora/45/x86_64/foo-1.6.0-1.git1700000000.0123abc.fc45.x86_64.rpm"},
 {"path":"staging/deb/debian/trixie/amd64/foo_1.6.0+git1700000000.0123abc_amd64.deb"}]}
J
export TREE_DIR=$tmp
run() { # run <publish> <ref-type> <tag> <packages> [republish] [kind] [releases]
  PATH=$tmp/bin:$PATH PUBLISH=$1 TARGET=Open-Mixer/open-mixer.github.io GPG_KEY=k PAGES_TOKEN=t REF=refs/tags/$3 \
    REF_TYPE=$2 REQUIRE_TAG=true TAG=$3 PACKAGES=$4 REPUBLISH=${5:-false} KIND=${6:-} RELEASES=${7:-} CATCH_UP=${CATCH_UP:-false} \
    GITHUB_ACTION_PATH=${ACT_PATH:-$act} bash "$tmp/step.sh" > "$tmp/out" 2>&1
}
run true tag v1.2.4 foo || { cat "$tmp/out"; fail "a new version was refused"; }
run true tag v1.2.3 foo && fail "an rpm version the channel serves passed"
grep -q 'rpm/fedora/44/x86_64/foo-1.2.3-1.fc44.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "the refusal does not name the rpm"; }
run true tag v2.0.0 bar && fail "a deb version the channel serves passed"
grep -q 'bar_2.0.0-1_amd64.deb' "$tmp/out" || fail "the refusal does not name the deb"
run true tag v3.1.0 'libbaz-*' && fail "a deb without a revision, named by glob, passed"
grep -q 'libbaz-dev_3.1.0_amd64.deb' "$tmp/out" || fail "the glob refusal does not name the deb"
run true tag v1.4.0 foo || fail "another package at that version was refused (foo-devel is not foo)"
run true tag v1.2.3 foo true || fail "republish was refused"
run false tag v1.2.3 foo || fail "a dry run was refused"
: > "$tmp/asked"; run false tag v1.2.3 foo; ! grep -q git/trees "$tmp/asked" || fail "a dry run read the tree"
run true tag v1.2.3 '' || fail "no package list must skip the check"
run true tag v1.2.3 foo false deb || { cat "$tmp/out"; fail "a deb release was refused by the rpms of its own version"; }
run true tag v1.2.3 foo false rpm && fail "an rpm release passed over its own served rpm"
run true tag v2.0.0 bar false rpm || { cat "$tmp/out"; fail "an rpm release was refused by the debs of its own version"; }
run true tag v2.0.0 bar false deb && fail "a deb release passed over its own served deb"
grep -q 'bar_2.0.0-1_amd64.deb' "$tmp/out" || fail "the deb-kind refusal does not name the deb"
run true tag v1.2.3 foo false rpm 45 || { cat "$tmp/out"; fail "an fc45 release was refused by the fc44 rpm of its version"; }
run true tag v0.5.0 'qux-*' false rpm 45 || { cat "$tmp/out"; fail "an fc45 release was refused by the fc44 noarch rpm of its version"; }
run true tag v1.4.0 foo-devel false rpm 45 && fail "an fc45 release passed over the fc45 rpm of its version"
grep -q 'rpm/fedora/45/x86_64/foo-devel-1.4.0-1.fc45.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "the fc45 refusal does not name the fc45 rpm"; }
run true tag v1.2.3 foo false rpm '44 45' && fail "a release for fc44 and fc45 passed over the fc44 rpm"
grep -q 'rpm/fedora/44/x86_64/foo-1.2.3-1.fc44.x86_64.rpm' "$tmp/out" || fail "the fc44+fc45 refusal does not name the fc44 rpm"
run true tag v2.0.0 bar false deb bookworm || { cat "$tmp/out"; fail "a bookworm release was refused by the trixie deb"; }
run true tag v2.0.0 bar false deb 'bookworm trixie' && fail "a release for trixie passed over the trixie deb"
CATCH_UP=true run true tag v1.2.3 foo false rpm 44 || { cat "$tmp/out"; fail "a catch-up was refused by the version it catches up"; }
grep -q 'catch-up of v1.2.3' "$tmp/out" || { cat "$tmp/out"; fail "a catch-up does not say why the already-served check is not run"; }
CATCH_UP=true run true tag v1.2.3 foo true rpm 44 && fail "catch-up with republish passed"
grep -q 'catch-up and republish' "$tmp/out" || { cat "$tmp/out"; fail "catch-up with republish is not refused by name"; }
: > "$tmp/asked"; CATCH_UP=true run false tag v1.2.3 foo || fail "a dry-run catch-up was refused"
! grep -q git/trees "$tmp/asked" || fail "a dry-run catch-up read the tree"
# a merge to devel (devel-version, require-tag false): its check runs first and a catch-up never skips it (F6a). The
# tree's foo 1.2.3 is served; a merge to devel carrying it with catch-up set must not take the catch-up branch.
# the caller's checkout a merge to devel runs in: A built foo 1.5.0 (the record names it), B changes .github/ alone after
# it, C changes src/ (R1)
repo=$tmp/repo; mkdir -p "$repo/src"; echo a > "$repo/src/a.c"
gitr() { git -C "$repo" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }
gitr init -q; gitr add -A; gitr commit -q -m built; A=$(gitr rev-parse HEAD); echo "$A" > "$tmp/record"
mkdir -p "$repo/.github"; echo w > "$repo/.github/ci.yml"; gitr add -A; gitr commit -q -m workflow; B=$(gitr rev-parse HEAD)
echo c > "$repo/src/a.c"; gitr commit -q -am code; C=$(gitr rev-parse HEAD); gitr checkout -q "$B"
rundevel() { # rundevel <devel version> [catch-up] [releases]
  cd "$repo" && PATH=$tmp/bin:$PATH NAME=foo EXEMPT=${EXEMPT_IN:-} BEFORE=${BEFORE:-} PUBLISH=true TARGET=Open-Mixer/open-mixer.github.io GPG_KEY=k PAGES_TOKEN=t REF=refs/heads/devel \
    REF_TYPE=branch REQUIRE_TAG=false TAG=devel PACKAGES=foo REPUBLISH=false KIND=rpm RELEASES=${3-44} CATCH_UP=${2:-false} \
    DEVEL_VERSION=$1 GITHUB_OUTPUT=$tmp/gh-out GITHUB_ACTION_PATH=${ACT_PATH:-$act} bash "$tmp/step.sh" > "$tmp/out" 2>&1; local rc=$?; cd "$here"; return $rc
}
rundevel 1.2.3 true && { cat "$tmp/out"; fail "a merge to devel with catch-up set skipped its version check"; }
grep -q 'a merge to devel never catches up' "$tmp/out" || { cat "$tmp/out"; fail "catch-up on a merge to devel is not refused by name"; }
rundevel 1.2.9 true && { cat "$tmp/out"; fail "a merge to devel of a new version passed with catch-up set"; }
grep -q 'catch-up of' "$tmp/out" && { cat "$tmp/out"; fail "a merge to devel took the catch-up branch"; }
echo "ok   a merge to devel never takes catch-up, and its version check runs first"
# a merge to devel of a version published already publishes nothing and stays GREEN only when nothing since the recorded
# build changes a package (.github/ alone): a notice names the served file and skip=true. A change to a package since it
# is RED, naming each path and the served version; a served version with no record of its build is red by name; a new
# version gives skip=false (F5, R1)
: > "$tmp/gh-out"; rundevel 1.5.0 false 45 || { cat "$tmp/out"; fail "a merge to devel changing .github/ alone since the build of a served version is red"; }
grep -qx 'skip=true' "$tmp/gh-out" || { cat "$tmp/out" "$tmp/gh-out"; fail "a merge to devel of a published version does not output skip=true"; }
grep -q '::notice::v1.5.0 is published already: staging/rpm/fedora/45/x86_64/foo-1.5.0-1.fc45.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "the skip does not name the served file in a notice"; }
grep -q '::error::' "$tmp/out" && { cat "$tmp/out"; fail "a merge to devel that skips printed an error"; }
gitr checkout -q "$C"
: > "$tmp/gh-out"; rundevel 1.5.0 false 45 && { cat "$tmp/out"; fail "a merge to devel changing src/ since the build of the served v1.5.0 skipped green"; }
grep -q "::error::src/a.c changes the package since $A, the build of the served v1.5.0" "$tmp/out" || { cat "$tmp/out"; fail "the red does not name the changed path and the served version"; }
grep -q 'skip=true' "$tmp/gh-out" && fail "a red merge to devel said skip=true"
gitr checkout -q "$B"
# B1: a served version with no record (1.2.3) is judged by the push itself, github.event.before..HEAD: .github/ alone is
# green with a notice naming the missing record; src/ is red by name; no readable before is red by name
rundevel 1.2.3 && { cat "$tmp/out"; fail "a merge to devel of a served version with no record and no before skipped green"; }
grep -q "::error::v1.2.3 is served, staging/rpm/built/foo/1.2.3.commit does not record the commit that built it, and this push (github.event.before..HEAD) cannot be read (its base is 'none')" "$tmp/out" || { cat "$tmp/out"; fail "a served version without a record and no before is not red by name"; }
BEFORE=0000000000000000000000000000000000000000 rundevel 1.2.3 && { cat "$tmp/out"; fail "a push whose before is all zeros skipped green"; }
: > "$tmp/gh-out"; BEFORE=$A rundevel 1.2.3 || { cat "$tmp/out"; fail "a push changing .github/ alone at a served version with no record is red"; }
grep -qx 'skip=true' "$tmp/gh-out" || { cat "$tmp/out"; fail "a push changing .github/ alone at a served version with no record does not skip"; }
grep -q '::notice::v1.2.3 is served and staging/rpm/built/foo/1.2.3.commit does not record the commit that built it; this push (github.event.before..HEAD) changes no package' "$tmp/out" || { cat "$tmp/out"; fail "the green skip does not name the missing record"; }
# GATE: a bump-exempt over every path is refused by the preflight before it judges anything
EXEMPT_IN='**' BEFORE=$A rundevel 1.2.3 && { cat "$tmp/out"; fail "the preflight took bump-exempt '**'"; }
grep -qF "::error::bump-exempt glob '**' covers every path" "$tmp/out" || { cat "$tmp/out"; fail "the preflight's refusal of '**' is not named"; }
gitr checkout -q "$C"
BEFORE=$B rundevel 1.2.3 && { cat "$tmp/out"; fail "a push changing src/ at a served version with no record skipped green"; }
grep -q '::error::src/a.c changes the package in this push (github.event.before..HEAD), and the served v1.2.3 has no build record' "$tmp/out" || { cat "$tmp/out"; fail "the red of a push without a record does not name src/a.c"; }
gitr checkout -q "$B"
echo 0000000000000000000000000000000000000000 > "$tmp/record"
rundevel 1.5.0 false 45 && { cat "$tmp/out"; fail "a record naming a commit the checkout cannot reach skipped green"; }
echo "$A" > "$tmp/record"
: > "$tmp/gh-out"; rundevel 1.2.9 || { cat "$tmp/out"; fail "a merge to devel of a new version was refused"; }
grep -qx 'skip=false' "$tmp/gh-out" || { cat "$tmp/out" "$tmp/gh-out"; fail "a merge to devel of a new version does not output skip=false"; }
echo "ok   a merge to devel of a published version is green, publishes nothing, and names what is served"
# a dispatched staged run (staged-version, not a merge to devel): a snapshot of a version the channel root or staging
# holds as a REAL build is refused, naming the file; one whose only builds are snapshots, or that nothing holds, passes (F3)
runstaged() { # runstaged <version> [kind] [releases]
  PATH=$tmp/bin:$PATH PUBLISH=true TARGET=Open-Mixer/open-mixer.github.io GPG_KEY=k PAGES_TOKEN=t REF=refs/heads/feature \
    REF_TYPE=branch REQUIRE_TAG=false TAG=feature PACKAGES=foo REPUBLISH=false KIND=${2:-rpm} RELEASES=${3:-} CATCH_UP=false \
    STAGED_VERSION=$1 GITHUB_OUTPUT=$tmp/gh-out GITHUB_ACTION_PATH=${ACT_PATH:-$act} bash "$tmp/step.sh" > "$tmp/out" 2>&1
}
runstaged 1.5.0 && { cat "$tmp/out"; fail "a staged snapshot of a version staging holds as a real build passed"; }
grep -q 'staging/rpm/fedora/45/x86_64/foo-1.5.0-1.fc45.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "the staged refusal does not name the real staged file"; }
grep -q 'a snapshot of a published version is retired: bump the version on devel' "$tmp/out" || { cat "$tmp/out"; fail "the staged refusal does not say to bump the version on devel"; }
runstaged 1.2.3 && { cat "$tmp/out"; fail "a staged snapshot of a version the channel root holds passed"; }
grep -q 'rpm/fedora/44/x86_64/foo-1.2.3-1.fc44.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "the staged refusal does not name the channel root's file"; }
runstaged 1.6.0 || { cat "$tmp/out"; fail "a staged snapshot was refused by an earlier snapshot of its version"; }
runstaged 1.6.0 deb || { cat "$tmp/out"; fail "a staged deb snapshot was refused by an earlier +git snapshot of its version"; }
runstaged 1.7.0 || { cat "$tmp/out"; fail "a staged snapshot of a version nothing holds was refused"; }
mkdir -p "$tmp/trunc"; jq '.truncated = true' "$tmp/tree.json" > "$tmp/trunc/tree.json"
TREE_DIR=$tmp/trunc runstaged 1.7.0 && { cat "$tmp/out"; fail "a staged run passed over a truncated tree"; }
grep -q 'is truncated: cannot prove v1.7.0 unpublished' "$tmp/out" || { cat "$tmp/out"; fail "a truncated tree is not refused by name for a staged run"; }
echo "ok   a staged snapshot of a version published as a real build is refused by name; snapshots alone do not refuse"
# sabotage: already-served.sh without the per-release filter refuses the fc45 release again
mkdir -p "$tmp/sab"
sed '/^  if \[ -n "\${RELEASES:-}" \]; then$/,/^  fi$/d' "$act/already-served.sh" > "$tmp/sab/already-served.sh"
! cmp -s "$act/already-served.sh" "$tmp/sab/already-served.sh" || fail "sabotage: the per-release filter was not found"
chmod +x "$tmp/sab/already-served.sh"
ACT_PATH=$tmp/sab run true tag v1.2.3 foo false rpm 45 && fail "sabotage: without the per-release filter the fc45 release still passed"
grep -q 'foo-1.2.3-1.fc44.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "sabotage: the red does not name the fc44 rpm"; }
echo "ok   sabotage: without the per-release filter the fc45 release is red"
echo "ok   release-preflight-served: 44 arms"
