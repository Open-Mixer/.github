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
 {"path":"rpm/fedora/45/x86_64/foo-devel-1.4.0-1.fc45.x86_64.rpm"}]}
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
# sabotage: already-served.sh without the per-release filter refuses the fc45 release again
mkdir -p "$tmp/sab"
sed '/^  if \[ -n "\${RELEASES:-}" \]; then$/,/^  fi$/d' "$act/already-served.sh" > "$tmp/sab/already-served.sh"
! cmp -s "$act/already-served.sh" "$tmp/sab/already-served.sh" || fail "sabotage: the per-release filter was not found"
chmod +x "$tmp/sab/already-served.sh"
ACT_PATH=$tmp/sab run true tag v1.2.3 foo false rpm 45 && fail "sabotage: without the per-release filter the fc45 release still passed"
grep -q 'foo-1.2.3-1.fc44.x86_64.rpm' "$tmp/out" || { cat "$tmp/out"; fail "sabotage: the red does not name the fc44 rpm"; }
echo "ok   sabotage: without the per-release filter the fc45 release is red"
echo "ok   release-preflight-served: 26 arms"
