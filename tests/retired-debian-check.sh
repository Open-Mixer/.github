#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The retired-debian-check action (Debian is trixie only, owner ruling 2026-11-28): its self-test is green, it is red on the
# three lines today's devel branches still carried (libdiginet's image list, omx-contract's full deb-releases, omx-plugins'
# deb-releases) and on the openmixer-release apt sources, green on comments and history, wired into public-sources-check as
# a job no input switches off, and a guard blind to one rule is caught: each sabotaged copy (no workflow rule, no action
# rule, no debian/ rule, no spec rule, the changelog read as a promise, comments read) goes red on its own arm and on the
# script's own self-test.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/retired-debian-check
chk=$act/retired-debian-check.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$chk" --self-test | grep -q 'self-test green (25 arms)' || fail "self-test not green"

plant() { # script name path body -> rc
  local d=$tmp/$2; mkdir -p "$d/.github/workflows" "$(dirname "$d/$3")"; printf 'jobs: {}\n' > "$d/.github/workflows/clean.yml"
  printf '%s\n' "$4" > "$d/$3"
  local rc=0; "$1" "$d" >/dev/null 2>&1 || rc=$?; echo "$rc"
}
want() { [ "$3" = "$2" ] || fail "$1: rc $3, want $2"; }

# the red first: the lines the devel branches of 2026-11-28 carried, as they were
want "libdiginet ci.yml:21" 1 "$(plant "$chk" diginet .github/workflows/ci.yml "        image: ['fedora:45', 'debian:bookworm', 'debian:trixie']")"
want "omx-contract ci.yml:77" 1 "$(plant "$chk" contract .github/workflows/ci.yml "          deb-releases: \${{ vars.OMX_RELEASE_MATRIX == 'full' && '[\"bookworm\", \"trixie\"]' || '[\"trixie\"]' }}")"
want "omx-plugins ci.yml:500" 1 "$(plant "$chk" plugins .github/workflows/ci.yml "          deb-releases: '[\"bookworm\", \"trixie\"]'")"
want "openmixer-release rules" 1 "$(plant "$chk" release packaging/openmixer-release/debian/rules 'SUITES = bookworm trixie')"
want "openmixer-release control" 1 "$(plant "$chk" releasectl packaging/openmixer-release/debian/control ' names the Debian release of the system it is installed on (bookworm or')"
# green on what is not a promise
want "a comment" 0 "$(plant "$chk" comment .github/workflows/ci.yml '          # trixie alone: Debian bookworm is dropped (owner 2026-11-27)')"
want "debian/changelog" 0 "$(plant "$chk" changelog debian/changelog '    bookworm package cells (#99)')"
want "a spec %changelog" 0 "$(plant "$chk" spechist packaging/x.spec "$(printf 'Name: x\n%%changelog\n- no bookworm\n')")"
want "a doc outside packaging" 0 "$(plant "$chk" doc README.md 'Debian bookworm and trixie')"
mkdir -p "$tmp/none/src"; echo x > "$tmp/none/src/a.c"; rc=0; "$chk" "$tmp/none" >/dev/null 2>&1 || rc=$?; want "nothing to check" 2 "$rc"
# a git work tree is read by its tracked files: an untracked file is not the repository's
g=$tmp/git; mkdir -p "$g/.github/workflows"; printf 'jobs: {}\n' > "$g/.github/workflows/ci.yml"
git -C "$g" init -q; git -C "$g" add .github/workflows/ci.yml
printf "image: debian:bookworm\n" > "$g/.github/workflows/untracked.yml"
rc=0; "$chk" "$g" >/dev/null 2>&1 || rc=$?; want "an untracked workflow" 0 "$rc"
git -C "$g" add .github/workflows/untracked.yml
rc=0; "$chk" "$g" >/dev/null 2>&1 || rc=$?; want "the same workflow tracked" 1 "$rc"

# wired: public-sources-check runs it in every caller, no if:, no input
w=$here/.github/workflows/public-sources-check.yml
sed -n '/^  retired-debian:/,/^  [a-z-]*:$/p' "$w" > "$tmp/job"
grep -q 'retired-debian-check@openmixer-v1' "$tmp/job" || fail "public-sources-check has no retired-debian job calling the action"
grep -q '^    if:' "$tmp/job" && fail "the retired-debian job has a condition: it runs in every caller"
grep -q 'retired-debian' <(sed -n '/^on:/,/^permissions:/p' "$w") && fail "public-sources-check has an input that names the check"
grep -q '^inputs:' "$act/action.yml" && fail "the action takes an input: there is no bookworm to allow"

# sabotage: a guard blind to one rule must go red on its own arm and on its own self-test
sab() { # rule-tag want-rc arm-name path body
  sed "/# rule:$1\$/d" "$chk" > "$tmp/sab-$1.sh"; chmod +x "$tmp/sab-$1.sh"
  cmp -s "$chk" "$tmp/sab-$1.sh" && fail "sabotage $1: nothing removed (the rule tag moved)"
  want "sabotaged $1: arm $3" "$2" "$(plant "$tmp/sab-$1.sh" "sab$1" "$4" "$5")"
  rc=0; "$tmp/sab-$1.sh" --self-test >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "sabotaged $1: the script's own self-test stayed green"
}
sab workflows 2 matrix .github/workflows/ci.yml "deb-releases: '[\"bookworm\", \"trixie\"]'"
sab actions 0 action .github/actions/build/action.yml 'default: bookworm'
sab debian 0 rules debian/rules 'SUITES = bookworm trixie'
sab spec 0 spec packaging/x.spec '%global suites bookworm trixie'
sab changelog 1 changelog debian/changelog '  * built for bookworm and trixie'
sab comment 1 comment .github/workflows/ci.yml '# bookworm is dropped'
# this repository: no workflow, action or packaging line names bookworm (frozen.txt and the check itself exempt by path)
rc=0; "$chk" "$here" >/dev/null 2>&1 || rc=$?; want "this repository" 0 "$rc"
echo "retired-debian-check: GREEN (self-test, 5 red-first lines, 4 green, tracked files, wiring, 6 sabotages, this repository clean)"
