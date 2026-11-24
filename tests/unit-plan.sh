#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The plan of a unit run (.github/scripts/unit-plan.py), offline: the real units/plugins.txt plans every member at
# its branch commit, level by level; a manifest reship= and a heads= override win over the branch; the bootstrap
# entry names the source member's commit of this run; an empty field takes build-rpm.yml's own default; and a
# manifest out of build order, an unknown field, a level past the workflow's jobs and a head of a non-member are
# each refused by name.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
plan=$here/.github/scripts/unit-plan.py
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
heads=""
i=1
for r in $(sed -e 's/#.*//' "$here/units/plugins.txt" | awk 'NF{print $1}'); do
  heads+="$r=$(printf '%040x' "$i") "; i=$((i + 1))
done
export OFFLINE_HEADS=$heads
out=$(python3 -I "$plan" "$here" plugins devel)
get() { sed -n "s/^$1=//p" <<<"$out"; }
[ "$(get rpm-0 | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["repo"])')" = Open-Mixer/omx-contract ] &&
  ok "level 0 is omx-contract" || bad "level 0: $(get rpm-0)"
[ "$(get rpm-7 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 3 ] && ok "rpm level 7 holds three members" || bad "rpm-7"
[ "$(get deb-7 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 2 ] && ok "deb=- leaves plugin-hostd-full out of deb level 7" || bad "deb-7"
clap=$(sed -n 's/^omx-clap-core=//p' <<<"$(tr ' ' '\n' <<<"$heads")")
get rpm-2 | grep -q "\"bootstrap\": \"Open-Mixer/omx-clap-core@$clap:omx-clap-contract\"" &&
  ok "phdp bootstraps omx-clap-contract at omx-clap-core's commit of the run" || bad "bootstrap: $(get rpm-2)"
get rpm-3 | grep -q '"arches": "\[\\"x86_64\\", \\"aarch64\\"\]"' && ok "an empty rpm-arches takes build-rpm.yml's default" || bad "default arches: $(get rpm-3)"

# heads= and reship= win over the branch
h=$(printf '%040x' 999)
python3 -I "$plan" "$here" plugins devel "plugin-db=$h" | grep -q "\"plugin-db\": \"$h\"" && ok "heads= overrides a member" || bad "heads="
mkdir -p "$t/root/units" "$t/root/.github"; cp -r "$here/.github/workflows" "$t/root/.github/"
sed "s/^plugin-db level=3 /plugin-db level=3 reship=$h /" "$here/units/plugins.txt" > "$t/root/units/plugins.txt"
python3 -I "$plan" "$t/root" plugins devel | grep -q "plugin-db .*${h:0:12}  (reship)" && ok "a manifest reship= wins over devel" || bad "reship"

refuse() { # <label> <expected message> <manifest edit> [extra args]
  sed "$3" "$here/units/plugins.txt" > "$t/root/units/plugins.txt"
  if o=$(python3 -I "$plan" "$t/root" plugins devel "${@:4}"); then bad "$1 passed"
  elif grep -q -- "$2" <<<"$o"; then ok "refused: $1"; else bad "$1: $o"; fi
}
refuse "out of build order" "the manifest is in build order" 's/^omx-dsp level=1 /omx-dsp level=5 /'
refuse "an unknown field" "is not one of" 's/^omx-dsp level=1 /omx-dsp level=1 arch=x86_64 /'
refuse "a level past the workflow's jobs" "has jobs for levels 0-7" 's/^plugin-hostd-full level=7 /plugin-hostd-full level=8 /'
refuse "a head of a non-member" "is not a member" 's/x/x/' "mod-host=$h"
refuse "a short reship" "is not a full commit" 's/^omx-dsp level=1 /omx-dsp level=1 reship=abc /'

# the workflow has a job pair for every level the plan writes
n=$(python3 -I -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(sum(1 for j in d["jobs"] if j.startswith("rpm-")))' \
  "$here/.github/workflows/release-unit.yml")
grep -q -- "--levels=$n" "$here/.github/workflows/release-unit.yml" && ok "release-unit.yml plans the $n levels it has jobs for" || bad "levels: jobs $n"
[ "$fail" = 0 ] && echo "unit-plan: all passed" || exit 1
