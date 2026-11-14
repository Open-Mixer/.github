#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The installability step of publish-rpms and publish-debs, run as written in each action.yml with channel-installability
# stubbed: an architecture the run built no binary for is judged with --unbuilt-arch-pass (UNBUILT_ARCH_PASS=true)
# for a dry run, and for a release of the quick set, whose other cells the wave's full release builds; a full release
# judges every architecture strictly.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/actions/publish" "$work/actions/channel-installability"
cat > "$work/actions/channel-installability/run.sh" <<'EOF'
#!/bin/bash
echo "UNBUILT_ARCH_PASS=${UNBUILT_ARCH_PASS:-}"
EOF
chmod +x "$work/actions/channel-installability/run.sh"
fail=0
step() {  # step <action> -> the run script of its installability step
  python3 - "$here/.github/actions/$1/action.yml" <<'PY'
import sys, yaml
for s in yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]:
    if s.get("name") == "Check no package of the channel becomes uninstallable":
        print(s["run"]); break
else:
    sys.exit("no installability step")
PY
}
expect() {  # expect <action> <sign> <matrix set> <want> <name>
  local got
  got=$(cd "$work" && SIGN=$2 MATRIX_SET=$3 RPM_TREE=rpm DEB_TREE=debian PKG_DIR=pkgs SERVED=https://example.invalid \
    GITHUB_ACTION_PATH=$work/actions/publish bash -c "$(step "$1")" 2>&1 | tail -1)
  if [ "$got" = "UNBUILT_ARCH_PASS=$4" ]; then echo "ok   $1: $5"; else echo "FAIL $1: $5: $got"; fail=1; fi
}
for a in publish-rpms publish-debs; do
  expect $a false full true "a dry run judges the architectures it did not build with the pass"
  expect $a true quick true "a release of the quick set judges the cells it did not build with the pass"
  expect $a true full "" "a full release judges every architecture strictly"
  expect $a true "" "" "a release that names no set judges every architecture strictly"
done
[ $fail = 0 ] && echo "quick-unbuilt-pass: all passed" || exit 1
