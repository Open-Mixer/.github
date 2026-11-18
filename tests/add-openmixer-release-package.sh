#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# add-openmixer installs the release package it is told: the default is openmixer-release and its two repositories, freereac-release
# installs freereac-release and loads the one repository freereac; a name that is not <channel>-release is refused. The dnf of the
# action is a recording stub, so this runs anywhere.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
w=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
python3 -I - "$here/../.github/actions/add-openmixer/action.yml" "$w/step.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
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
    PATH=$w/bin:$PATH BASE_URL=https://example.org SUITE= RELEASE_PACKAGE=$1 bash "$w/run.sh" > /dev/null
}
run openmixer-release openmixer '[openmixer]\n[openmixer-noarch]\n'
grep -q "install .*https://example.org/rpm/openmixer-release.noarch.rpm" "$w/calls" || fail "the default does not install openmixer-release: $(cat "$w/calls")"
grep -q "makecache --repo openmixer --repo openmixer-noarch" "$w/calls" || fail "the default does not load both OpenMixer repositories: $(cat "$w/calls")"
run freereac-release freereac '[freereac]\n'
grep -q "install .*https://example.org/rpm/freereac-release.noarch.rpm" "$w/calls" || fail "freereac-release is not the package installed: $(cat "$w/calls")"
grep -q "makecache --repo freereac\$" "$w/calls" || fail "freereac loads more or other than the freereac repository: $(cat "$w/calls")"
if run 'evil;release' x '' 2>/dev/null; then fail "a release package that is not <channel>-release was accepted"; fi
echo "add-openmixer release-package: ok"
