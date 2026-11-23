#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The bootstrap input of build-rpm.yml and build-deb.yml (Open-Mixer/.github#230): a sibling's -contract data package
# built alone from its source at a named commit (actions/contract-bootstrap/bootstrap.sh), and contract-bootstrap.yml,
# which releases one such package ahead of the library that owns it.
#
#   contract-bootstrap.sh static     the workflow wiring and the line reader (no container)
#   contract-bootstrap.sh rpm|deb    the build, in a throwaway Fedora (rpm) or Debian (deb) container, as root
#
# static proves:
#   - build-rpm.yml and build-deb.yml take bootstrap and bootstrap-only, read them in the preflight, never check out the
#     calling repository's tree for bootstrap-only, and run contract-bootstrap before their own build;
#   - a dispatch publishes nothing: contract-bootstrap.yml passes publish exactly `github.event_name == 'push'` to both
#     builds and has a workflow_dispatch with no publish switch (sabotage: a copy passing publish: true is red);
#   - the line reader takes a tag bootstrap-<package>-<version> that matches a line, a dry run by package, and refuses
#     a tag that names no line, a short commit and a non-release version.
# rpm and deb prove, over a fixture library (a git repository served by file://):
#   - the package: its files are install-contract's less those another package claims (a language pack's catalog),
#     its dependencies are the packaging's, its version is the library's below its release;
#   - the versions: the bootstrap meets a consumer's floor (rpm: a consumer built with Requires >= <version> installs
#     with it; deb: >= <version>~) and sorts below the library's own release of the version (sabotage: a bootstrap.sh
#     whose rpm Release is 2, or whose deb version has no ~git, is red on that arm);
#   - the commit: a short sha, a sha the library does not have, and an annotated tag's object (whose checkout is another
#     commit) are refused before anything is built (sabotage: a bootstrap.sh without the checkout check lets the tag's
#     object through, so the check is what refuses it).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
boot=$root/.github/actions/contract-bootstrap/bootstrap.sh
mode=${1:?usage: contract-bootstrap.sh static|rpm|deb}
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

if [ "$mode" = static ]; then
  for k in rpm deb; do
    w=$root/.github/workflows/build-$k.yml
    for want in '      bootstrap:' '      bootstrap-only:' '      - name: Read the bootstrap' \
                'uses: Open-Mixer/.github/.github/actions/contract-bootstrap@openmixer-v1' \
                "        if: \${{ !inputs.bootstrap-only }}"; do
      grep -qF -- "$want" "$w" && pass "build-$k.yml: $want" || fail "build-$k.yml lacks: $want"
    done
    # every checkout of the calling repository's tree (the preflight's and the build's) is skipped for bootstrap-only
    m=$(awk '/^      - uses: actions\/checkout@v4$/ {c=1; g=0; next}
             c && /^        if: \$\{\{ !inputs.bootstrap-only \}\}$/ {g=1; next}
             c && /^          repository: \$\{\{ inputs.source-repository/ {n++; if (g) k++; c=0; next}
             END {print k+0 "/" n+0}' "$w")
    [ "$m" = 2/2 ] && pass "build-$k.yml: the preflight and build checkouts skip the tree for bootstrap-only" || fail "build-$k.yml: $m tree checkouts skip it for bootstrap-only"
    # the bootstrap step comes before the library's own build step
    a=$(grep -n -F 'actions/contract-bootstrap@openmixer-v1' "$w" | head -1 | cut -d: -f1)
    b=$(grep -n -F "actions/build-$k@openmixer-v1" "$w" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && pass "build-$k.yml: the bootstrap runs before the build" || fail "build-$k.yml: the bootstrap does not run before the build"
  done
  caller=$root/.github/workflows/contract-bootstrap.yml
  publishes_nothing_on_dispatch() { # <workflow>: every publish it passes is exactly the push condition, and it has a dispatch
    local c; c=$(grep -E '^[[:space:]]+publish:' "$1" | sed 's/^[[:space:]]*publish:[[:space:]]*//' | sort -u)
    [ "$c" = "\${{ github.event_name == 'push' }}" ] && [ "$(grep -cE '^[[:space:]]+publish:' "$1")" = 2 ] && grep -q '^  workflow_dispatch:' "$1" \
      && ! awk '/^  workflow_dispatch:/ {on=1; next} /^[^ ]/ || /^  [a-z]/ {on=0} on && /^      [A-Za-z_-]+:$/' "$1" | grep -qiE 'publish|release|sign'
  }
  publishes_nothing_on_dispatch "$caller" && pass "contract-bootstrap.yml: a dispatch publishes nothing" || fail "contract-bootstrap.yml: a dispatch could publish"
  sed 's/publish: ${{ github.event_name == .push. }}/publish: true/' "$caller" > "$t/sabotage.yml"
  publishes_nothing_on_dispatch "$t/sabotage.yml" && fail "sabotage: publish: true passes the dispatch check" || pass "sabotage: publish: true is red"
  grep -q "^    tags: \['bootstrap-\*'\]" "$caller" && pass "contract-bootstrap.yml: a bootstrap-* tag is the release" || fail "contract-bootstrap.yml: no bootstrap-* tag trigger"
  line=$root/.github/scripts/contract-bootstrap-line.sh
  sha=0123456789abcdef0123456789abcdef01234567
  printf '# a comment\nfx-contract 1.2.0 Open-Mixer/fx@%s\n' "$sha" > "$t/ok.txt"
  out=$("$line" push bootstrap-fx-contract-1.2.0 '' "$t/ok.txt")
  [ "$out" = "$(printf 'package=fx-contract\nversion=1.2.0\nentry=Open-Mixer/fx@%s:fx-contract' "$sha")" ] && pass "line: the tag names its line" || fail "line: tag read as: $out"
  out=$("$line" workflow_dispatch main fx-contract "$t/ok.txt") && pass "line: a dry run names the package" || fail "line: a dry run by package refused"
  "$line" push bootstrap-fx-contract-1.2.1 '' "$t/ok.txt" >/dev/null 2>&1 && fail "line: a tag naming no line passed" || pass "line: a tag naming no line is refused"
  printf 'fx-contract 1.2.0 Open-Mixer/fx@%s\n' "${sha:0:12}" > "$t/short.txt"
  "$line" push bootstrap-fx-contract-1.2.0 '' "$t/short.txt" >/dev/null 2>&1 && fail "line: a short commit passed" || pass "line: a short commit is refused"
  printf 'fx-contract 1.2.0-rc1 Open-Mixer/fx@%s\n' "$sha" > "$t/rc.txt"
  "$line" workflow_dispatch main fx-contract "$t/rc.txt" >/dev/null 2>&1 && fail "line: a non-release version passed" || pass "line: a non-release version is refused"
  "$line" push bootstrap-omx-clap-contract-0.34.0 '' >/dev/null && pass "line: the tracked file reads" || fail "line: the tracked file does not read"
  echo "contract-bootstrap static: $fails failure(s)"; exit $((fails > 0))
fi

case $mode in rpm | deb) ;; *) echo "contract-bootstrap.sh: static, rpm or deb, not '$mode'" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "contract-bootstrap.sh $mode installs packages: run it as root in a throwaway container" >&2; exit 2; }
if [ "$mode" = rpm ]; then dnf install -y -q git make rpm-build >/dev/null 2>&1
else apt-get update -qq && apt-get install -y -qq --no-install-recommends git make dpkg-dev ca-certificates >/dev/null; fi
git config --global user.name fixture; git config --global user.email fixture@invalid; git config --global init.defaultBranch main

# the fixture library: owner/fx with a noarch / all -contract package, a language pack that claims the catalogs, and a
# make install-contract that installs both
lib=$t/base/owner/fx; mkdir -p "$lib/packaging" "$lib/debian/source" "$lib/data" "$lib/catalogs"
cd "$lib"; git init -q
echo 1.2.0 > VERSION; echo GPL > COPYING; echo '# fx' > README.md
echo '{"a": 1}' > data/fx.json; echo '{"ca": 1}' > catalogs/ca.json
printf 'install-contract:\n\tinstall -D -m 644 data/fx.json $(DESTDIR)$(PREFIX)/share/omx-contract/contract.d/3/fx/fx.json\n\tinstall -D -m 644 catalogs/ca.json $(DESTDIR)$(PREFIX)/share/fx/catalogs/ca.json\n' > Makefile
cat > packaging/fx.spec <<'EOF'
Name: fx
Version: 1.2.0
Release: 1%{?dist}
License: GPL-3.0-or-later
Summary: fx
%description
fx.
%package -n fx-contract
Summary: fx's definitions
BuildArch: noarch
Requires: omx-contract-data >= 3.21.0
%description -n fx-contract
fx's definitions, as files.
%package langpack-ca
Summary: Catalan
%description langpack-ca
Catalan.
%files -n fx-contract
%license COPYING
%doc README.md
%{_datadir}/omx-contract/contract.d/3/fx/
%files langpack-ca
%{_datadir}/fx/catalogs/ca.json
EOF
cat > debian/control <<'EOF'
Source: fx
Section: sound
Priority: optional
Maintainer: Fixture <fixture@invalid>
Homepage: https://example.invalid/fx

Package: fx-contract
Architecture: all
Multi-Arch: foreign
Depends: omx-contract-data (>= 3.21.0~), ${misc:Depends}
Description: fx's definitions
 fx's definitions, as files.
EOF
echo 'usr/share/omx-contract/contract.d/3/fx' > debian/fx-contract.install
printf '# docs\nREADME.md\n' > debian/fx-contract.docs
echo 'GPL' > debian/copyright; echo '3.0 (native)' > debian/source/format
printf 'fx (1.2.0) unstable; urgency=medium\n\n  * fx.\n\n -- Fixture <fixture@invalid>  Mon, 23 Nov 2026 00:00:00 +0000\n' > debian/changelog
git add -A; git commit -qm fx; head=$(git rev-parse HEAD)
git tag -a -m 'annotated' v1.2.0; tagobj=$(git rev-parse v1.2.0)
git commit -q --allow-empty -m later
cd "$t"
export BOOTSTRAP_GIT_BASE=file://$t/base
git -C "$lib" config uploadpack.allowAnySHA1InWant true

# the package
mkdir -p out
log=$("$boot" "$mode" "owner/fx@$head:fx-contract" out) && pass "built: ${log#BOOTSTRAP }" || fail "the fixture did not build: $log"
if [ "$mode" = rpm ]; then
  bin=$(find out -name 'fx-contract-*.noarch.rpm' | head -1); src=$(find out -name 'fx-contract-*.src.rpm' | head -1)
  [ -n "$bin" ] && [ -n "$src" ] && pass "a noarch package and its source package" || fail "no noarch or no source package: $(ls out)"
  files=$(rpm -qpl "$bin")
  ver=$(rpm -qp --qf '%{version}-%{release}' "$bin")
  deps=$(rpm -qp --requires "$bin" | grep -v '^rpmlib')
else
  bin=$(find out -name 'fx-contract_*_all.deb' | head -1)
  [ -n "$bin" ] && pass "an Architecture: all package" || fail "no _all.deb: $(ls out)"
  files=$(dpkg-deb -c "$bin" | awk '{print substr($6, 2)}')
  ver=$(dpkg-deb -f "$bin" Version)
  deps=$(dpkg-deb -f "$bin" Depends)
fi
grep -qx '/usr/share/omx-contract/contract.d/3/fx/fx.json' <<< "$files" && pass "carries install-contract's file" || fail "lacks install-contract's file"
grep -q 'catalogs/ca.json' <<< "$files" && fail "carries the language pack's catalog" || pass "leaves the language pack's catalog out"
grep -q 'README.md' <<< "$files" && pass "carries its documentation" || fail "lacks its documentation"
grep -q 'omx-contract-data (\?>= 3.21.0' <<< "$deps" && ! grep -q 'misc:Depends' <<< "$deps" && pass "depends as its packaging says: $deps" || fail "dependencies: $deps"

# the versions: meets a consumer's floor, below the library's own release; each with its sabotage
below_release() { # <version-release or deb version>
  if [ "$mode" = rpm ]; then [ "$(rpm --eval "%{lua: print(rpm.vercmp('$1', '1.2.0-1$(rpm --eval '%{?dist}')'))}")" = -1 ]
  else dpkg --compare-versions "$1" lt 1.2.0 && dpkg --compare-versions "$1" lt 1.2.0-1; fi
}
meets_floor() { # <package file> <floor>: a consumer that requires fx-contract >= <floor> installs with it (and a stub of its own dependency)
  if [ "$mode" = rpm ]; then
    local c=$t/c$2; mkdir -p "$c/SPECS"
    stub() { printf 'Name: %s\nVersion: %s\nRelease: 1\nSummary: s\nLicense: GPL\nBuildArch: noarch\n%s\n%%description\ns.\n%%files\n' "$1" "$2" "$3" > "$c/SPECS/$1.spec"
      rpmbuild -bb --quiet --define "_topdir $c" "$c/SPECS/$1.spec" >/dev/null 2>&1; }
    stub consumer 1 "Requires: fx-contract >= $2"; stub omx-contract-data 3.21.0 ''
    # shellcheck disable=SC2046 # the package files, one word each
    rpm -i --test --nosignature "$1" $(find "$c/RPMS" -name '*.rpm') >/dev/null 2>&1
  else dpkg --compare-versions "$(dpkg-deb -f "$1" Version)" ge "$2~"; fi
}
meets_floor "$bin" 1.2.0 && pass "meets a consumer's floor on 1.2.0 ($ver)" || fail "does not meet a consumer's floor on 1.2.0 ($ver)"
meets_floor "$bin" 1.2.1 && fail "control: meets a floor on 1.2.1 too, so the floor arm cannot go red" || pass "control: a floor on 1.2.1 is not met"
below_release "$ver" && pass "sorts below the library's release of 1.2.0 ($ver)" || fail "does not sort below the library's release ($ver)"
mkdir -p sab
if [ "$mode" = rpm ]; then sed 's/Release: 0\.git/Release: 2.git/' "$boot" > sab/bootstrap.sh
else sed 's/ver=${ver%-\*}~git$ct.$short/ver=${ver%-*}+git$ct.$short/' "$boot" > sab/bootstrap.sh; fi
cmp -s "$boot" sab/bootstrap.sh && fail "sabotage: the version line was not found to break"
mkdir -p sabout
bash sab/bootstrap.sh "$mode" "owner/fx@$head:fx-contract" sabout >/dev/null 2>&1 || fail "sabotage: the broken bootstrap.sh did not build"
sv=$(if [ "$mode" = rpm ]; then rpm -qp --qf '%{version}-%{release}' sabout/*.noarch.rpm; else dpkg-deb -f sabout/*.deb Version; fi)
below_release "$sv" && fail "sabotage: a version above the release ($sv) passes the below-release arm" || pass "sabotage: a version above the release ($sv) is red"

# the commit
"$boot" "$mode" "owner/fx@${head:0:12}:fx-contract" out2 >/dev/null 2>&1 && fail "a short sha was built" || pass "a short sha is refused"
"$boot" "$mode" "owner/fx@0123456789abcdef0123456789abcdef01234567:fx-contract" out2 >/dev/null 2>&1 && fail "a sha the library lacks was built" || pass "a sha the library lacks is refused"
msg=$("$boot" "$mode" "owner/fx@$tagobj:fx-contract" out2 2>&1) && fail "an annotated tag's object was built" \
  || { grep -q "the checkout is $head, not $tagobj" <<< "$msg" && pass "an annotated tag's object is refused: the checkout is another commit" || fail "the tag's object was refused for another reason: $msg"; }
grep -v -F '[ "$got" = "$sha" ] ||' "$boot" > sab/nocheck.sh
cmp -s "$boot" sab/nocheck.sh && fail "sabotage: the checkout check was not found to remove"
bash sab/nocheck.sh "$mode" "owner/fx@$tagobj:fx-contract" out3 >/dev/null 2>&1 \
  && pass "sabotage: without the checkout check the tag's object is built, so the check is what refuses it" || fail "sabotage: without the check the tag's object is still refused"
echo "contract-bootstrap $mode: $fails failure(s)"; exit $((fails > 0))
