#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# add-openmixer installs the release package it is told: the default is openmixer-release and its two repositories, freereac-release
# installs freereac-release and loads the one repository freereac; a name that is not <channel>-release is refused. One channel per
# call: the OpenMixer and FreeREAC channels are independent (owner ruling 2026-11-23, .github#224), so installing openmixer-release
# never brings FreeREAC's release package or repository, whatever the environment holds, and the action has no input that would.
# The dnf of the action is a recording stub, so this runs anywhere.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
w=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
python3 -I - "$here/../.github/actions/add-openmixer/action.yml" "$w/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
other = sorted(k for k in d.get("inputs", {}) if "freereac" in k.lower())
if other:
    sys.exit(f"FAIL: add-openmixer has inputs that reach another channel: {other}")
open(sys.argv[2], "w").write(d["runs"]["steps"][0]["run"])
PY
mkdir "$w/bin" "$w/etc"
cat > "$w/bin/dnf" <<STUB
#!/bin/bash
echo "dnf \$*" >> "$w/calls"
STUB
chmod +x "$w/bin/dnf"
run() { # <release package> <repo file name> <repo file content>
    : > "$w/calls"
    printf '%b' "$3" > "$w/etc/$2.repo"
    # the step reads /etc/yum.repos.d and /etc/dnf: point both at the scratch directory
    sed -e "s|/etc/yum.repos.d|$w/etc|g" -e "s|/etc/dnf/dnf.conf|$w/dnf.conf|g" "$w/step.sh" > "$w/run.sh"
    : > "$w/dnf.conf"
    PATH=$w/bin:$PATH BASE_URL=https://example.org SUITE= RELEASE_PACKAGE=$1 FREEREAC_URL=${FREEREAC_URL-} bash "$w/run.sh" > /dev/null
}
run openmixer-release openmixer '[openmixer]\n[openmixer-noarch]\n'
grep -q "install .*https://example.org/rpm/openmixer-release.noarch.rpm" "$w/calls" || fail "the default does not install openmixer-release: $(cat "$w/calls")"
grep -q "makecache --repo openmixer --repo openmixer-noarch" "$w/calls" || fail "the default does not load both OpenMixer repositories: $(cat "$w/calls")"
# openmixer-release comes alone, even with a FreeREAC URL in the environment (the input a caller of the old action passed)
FREEREAC_URL=https://fr.example.org run openmixer-release openmixer '[openmixer]\n[openmixer-noarch]\n'
! grep -q "freereac" "$w/calls" || fail "installing openmixer-release reached the FreeREAC channel: $(cat "$w/calls")"
grep -qx "dnf install -y --setopt=install_weak_deps=False https://example.org/rpm/openmixer-release.noarch.rpm" "$w/calls" ||
    fail "openmixer-release is not installed alone: $(cat "$w/calls")"
grep -qx "dnf -y --setopt=skip_if_unavailable=False makecache --repo openmixer --repo openmixer-noarch" "$w/calls" ||
    fail "more or other than the two OpenMixer repositories load: $(cat "$w/calls")"
# a build container of the FreeREAC channel never takes the OpenMixer package, whatever freereac-url says
FREEREAC_URL=https://fr.example.org run freereac-release freereac '[freereac]\n'
! grep -q "openmixer" "$w/calls" || fail "freereac-release pulled in openmixer: $(cat "$w/calls")"
run freereac-release freereac '[freereac]\n'
grep -q "install .*https://example.org/rpm/freereac-release.noarch.rpm" "$w/calls" || fail "freereac-release is not the package installed: $(cat "$w/calls")"
grep -q "makecache --repo freereac\$" "$w/calls" || fail "freereac loads more or other than the freereac repository: $(cat "$w/calls")"
if run 'evil;release' x '' 2>/dev/null; then fail "a release package that is not <channel>-release was accepted"; fi
echo "add-openmixer release-package: ok"
