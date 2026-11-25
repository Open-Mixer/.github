#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The testing channel carries the tested platforms alone (owner ruling 2026-11-23, .github#233). Proves, offline:
#   - staged-cells.sh accepts the packages of the quick set's cells (fc45 x86_64, its noarch and src; trixie arm64 and
#     its all) and refuses, by file and cell, fc45 aarch64, fc44 anything, an rpm without a dist tag, trixie amd64 and
#     bookworm anything;
#   - the first step of publish-rpms and publish-debs, run as the runner runs it with staging on, refuses a package of
#     another cell before anything is placed, accepts a tested one, and leaves a real publish (staging off) alone;
#   - the staging deb skeleton is the quick set's architectures, in the publish and in the purge;
#   - the run's set (MATRIX_SET, .github#273): quick (or empty) refuses an extra cell; full, a promotion candidate,
#     accepts every architecture of the releases the run built and still refuses another release; an unreadable set,
#     or full with no releases, is exit 2; the full deb skeleton adds the architectures the run built; sabotaged.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions
sc=$act/release-matrix/staged-cells.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

lay() { # <dir> <relative path>...: empty files with the package names
    local d=$1; shift
    rm -rf "$d"; mkdir -p "$d"
    for p in "$@"; do mkdir -p "$(dirname "$d/$p")"; : > "$d/$p"; done
}
accept() { # <kind> <what> <path>...
    local kind=$1 what=$2; shift 2
    lay "$t/p" "$@"
    "$sc" check "$kind" "$t/p" > "$t/log" 2>&1 || fail "$kind: $what refused: $(cat "$t/log")"
}
refuse() { # <kind> <what> <cell named> <path>...
    local kind=$1 what=$2 cell=$3; shift 3
    lay "$t/p" "$@"
    if "$sc" check "$kind" "$t/p" > "$t/log" 2>&1; then fail "$kind: $what accepted"; fi
    grep -q "($cell)" "$t/log" || fail "$kind: $what not refused by cell '$cell': $(cat "$t/log")"
}

accept rpm "fc45 x86_64, noarch and src" \
    a/omx-lib-3.14.0-1.git1794480000.99c23a5.fc45.x86_64.rpm a/omx-lib-data-3.14.0-1.fc45.noarch.rpm a/omx-lib-3.14.0-1.fc45.src.rpm
refuse rpm "fc45 aarch64" "fc45 aarch64" a/omx-lib-3.14.0-1.fc45.x86_64.rpm a/omx-lib-3.14.0-1.fc45.aarch64.rpm
refuse rpm "fc44 x86_64" "fc44 x86_64" a/omx-lib-3.14.0-1.fc44.x86_64.rpm
refuse rpm "fc44 noarch" "fc44 noarch" a/omx-lib-data-3.14.0-1.fc44.noarch.rpm
refuse rpm "an rpm with no dist tag" "no .fcNN dist tag" a/omx-lib-3.14.0-1.x86_64.rpm
accept deb "trixie arm64 and all" trixie/omx-lib_3.14.0+git1794480000.99c23a5_arm64.deb trixie/omx-lib-data_3.14.0_all.deb
refuse deb "trixie amd64" "trixie amd64" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb
refuse deb "bookworm arm64" "bookworm arm64" bookworm/omx-lib_3.14.0_arm64.deb
refuse deb "bookworm all" "bookworm all" bookworm/omx-lib-data_3.14.0_all.deb
[ "$("$sc" arches deb)" = arm64 ] || fail "the quick set's Debian architectures are '$("$sc" arches deb)', not arm64"
ok "staged-cells.sh: the quick set's cells pass, every other cell is refused by file and cell"

# the run's set (#273): quick stays the default and refuses an extra cell; full accepts the releases the run built
accept_with() { # <env...> -- <kind> <what> <path>...
    local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
    local kind=$1 what=$2; shift 2
    lay "$t/p" "$@"
    env "${e[@]}" "$sc" check "$kind" "$t/p" > "$t/log" 2>&1 || fail "$kind ${e[*]}: $what refused: $(cat "$t/log")"
}
refuse_with() { # <env...> -- <kind> <what> <cell named> <path>...
    local -a e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
    local kind=$1 what=$2 cell=$3; shift 3
    lay "$t/p" "$@"
    if env "${e[@]}" "$sc" check "$kind" "$t/p" > "$t/log" 2>&1; then fail "$kind ${e[*]}: $what accepted"; fi
    grep -q "($cell)" "$t/log" || fail "$kind ${e[*]}: $what not refused by cell '$cell': $(cat "$t/log")"
}
full_arms() { # the arms, run against $sc
    refuse_with MATRIX_SET=quick RELEASES=45 -- rpm "a quick run's fc45 aarch64" "fc45 aarch64" a/omx-lib-3.14.0-1.fc45.x86_64.rpm a/omx-lib-3.14.0-1.fc45.aarch64.rpm
    refuse_with MATRIX_SET=quick SUITES=trixie -- deb "a quick run's trixie amd64" "trixie amd64" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb
    accept_with MATRIX_SET=full RELEASES=45 -- rpm "a full run's fc45 x86_64, aarch64, noarch and src" \
        a/omx-lib-3.14.0-1.fc45.x86_64.rpm a/omx-lib-3.14.0-1.fc45.aarch64.rpm a/omx-lib-data-3.14.0-1.fc45.noarch.rpm a/omx-lib-3.14.0-1.fc45.src.rpm
    accept_with MATRIX_SET=full RELEASES="44 45" -- rpm "a full run's fc44 and fc45" a/omx-lib-3.14.0-1.fc44.x86_64.rpm a/omx-lib-3.14.0-1.fc45.aarch64.rpm
    refuse_with MATRIX_SET=full RELEASES=45 -- rpm "a full run's fc44, a release it did not build" "fc44 x86_64" a/omx-lib-3.14.0-1.fc45.x86_64.rpm a/omx-lib-3.14.0-1.fc44.x86_64.rpm
    accept_with MATRIX_SET=full SUITES=trixie -- deb "a full run's trixie amd64, arm64 and all" \
        trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb trixie/omx-lib-data_3.14.0_all.deb
    refuse_with MATRIX_SET=full SUITES=trixie -- deb "a full run's bookworm amd64, a release it did not build" "bookworm amd64" bookworm/omx-lib_3.14.0_amd64.deb
}
full_arms
lay "$t/p" a/omx-lib-3.14.0-1.fc45.x86_64.rpm
rc=0; MATRIX_SET=some "$sc" check rpm "$t/p" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "MATRIX_SET=some gave $rc, not 2"
rc=0; MATRIX_SET=full RELEASES='' "$sc" check rpm "$t/p" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "MATRIX_SET=full with no releases gave $rc, not 2"
lay "$t/p" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb trixie/omx-lib-data_3.14.0_all.deb
[ "$(MATRIX_SET=full "$sc" arches deb "$t/p")" = "amd64 arm64" ] || fail "a full run's skeleton is '$(MATRIX_SET=full "$sc" arches deb "$t/p")', not 'amd64 arm64'"
[ "$("$sc" arches deb "$t/p")" = arm64 ] || fail "a quick run's skeleton widened to the files: '$("$sc" arches deb "$t/p")'"
ok "the run's set: quick refuses an extra cell; full accepts every architecture of the releases it built, refuses another release; unreadable is exit 2"
# SABOTAGE on copies: (1) the full branch ignored (always quick): the full arms are refused; (2) every set read as full:
# the quick arms accept the extra cell
real_sc=$sc
sed 's/if \[ "\$run_set" = full \]; then run_releases/if false; then run_releases/' "$real_sc" > "$t/sab1.sh"
sed 's/if \[ "\$run_set" = full \]; then run_releases/if true; then run_releases/' "$real_sc" > "$t/sab2.sh"
for n in 1 2; do chmod +x "$t/sab$n.sh"; [ "$(grep -c "if $([ $n = 1 ] && echo false || echo true); then run_releases" "$t/sab$n.sh")" = 2 ] || fail "sabotage $n setup"; done
sc=$t/sab1.sh; ( full_arms ) >/dev/null 2>&1 && fail "sabotage 1: with the full branch ignored the full arms still passed"
sc=$t/sab2.sh; ( RELEASES=45 SUITES=trixie full_arms ) >/dev/null 2>&1 && fail "sabotage 2: with every set read as full the quick arms still passed"
sc=$real_sc
ok "sabotage: the full branch ignored, and every set read as full, each turn their arm red"

# the first step of each publish action, as the runner runs it
step() { # <action.yml> <name pattern> <out>
    python3 -I - "$@" <<'PY'
import re, sys, yaml
path, pat, out = sys.argv[1:4]
steps = yaml.safe_load(open(path))["runs"]["steps"]
hit = [s for s in steps if re.search(pat, s.get("name", ""))]
assert len(hit) == 1, f"{path}: {len(hit)} steps match {pat!r}"
open(out, "w").write(hit[0]["run"])
PY
}
first() { # <kind> <staging true|false> <dir>: 0 when the step passes
    local kind=$1 staging=$2 dir=$3
    step "$act/publish-${kind}s/action.yml" '^Prove the packages are there' "$t/first.sh"
    : > "$t/env"
    (cd "$t" && GITHUB_ACTION_PATH=$act/publish-${kind}s GITHUB_ENV=$t/env STAGING=$staging COMMITTED_KEYS=true \
        SIGNING_FPR='' RPM_DIR=$dir DEB_DIR=$dir RELEASES=45 SUITES=trixie \
        PATH="$t/bin:$PATH" bash -e "$t/first.sh") > "$t/step.log" 2>&1
}
# check-fingerprint.sh wants a fingerprint: a stub that accepts, the guard under test is the cells
mkdir -p "$t/bin"
cp -r "$act" "$t/actions"; act=$t/actions
printf '#!/bin/bash\nexit 0\n' > "$act/import-gpg-key/check-fingerprint.sh"; chmod +x "$act/import-gpg-key/check-fingerprint.sh"

lay "$t/r" omx-lib-3.14.0-1.fc45.x86_64.rpm omx-lib-3.14.0-1.fc45.aarch64.rpm
first rpm true "$t/r" && fail "publish-rpms staged an fc45 aarch64 package"
grep -q '(fc45 aarch64)' "$t/step.log" || fail "publish-rpms did not name the refused cell: $(cat "$t/step.log")"
first rpm false "$t/r" || fail "publish-rpms refused a real publish of fc45 aarch64: $(cat "$t/step.log")"
lay "$t/r" omx-lib-3.14.0-1.fc45.x86_64.rpm omx-lib-3.14.0-1.fc45.src.rpm
first rpm true "$t/r" || fail "publish-rpms refused a staged fc45 x86_64 package: $(cat "$t/step.log")"
ok "publish-rpms: a staged package of another cell is refused before anything is placed; a tested one and a real publish pass"

lay "$t/d" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb
first deb true "$t/d" && fail "publish-debs staged a trixie amd64 package"
grep -q '(trixie amd64)' "$t/step.log" || fail "publish-debs did not name the refused cell: $(cat "$t/step.log")"
first deb false "$t/d" || fail "publish-debs refused a real publish of trixie amd64: $(cat "$t/step.log")"
lay "$t/d" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib-data_3.14.0_all.deb
first deb true "$t/d" || fail "publish-debs refused a staged trixie arm64 package: $(cat "$t/step.log")"
grep -qx 'SKELETON_ARCHES=arm64' "$t/env" || fail "the staged deb publish does not make the skeleton of the quick set's architectures: $(cat "$t/env")"
ok "publish-debs: a staged package of another cell is refused before anything is placed; the skeleton is arm64"

# a staged promotion candidate through the publish steps (#273): MATRIX_SET=full, the step's own env
lay "$t/r" omx-lib-3.14.0-1.fc45.x86_64.rpm omx-lib-3.14.0-1.fc45.aarch64.rpm
MATRIX_SET=full first rpm true "$t/r" || fail "publish-rpms refused a full staged run's fc45 aarch64: $(cat "$t/step.log")"
lay "$t/d" trixie/omx-lib_3.14.0_arm64.deb trixie/omx-lib_3.14.0_amd64.deb
MATRIX_SET=full first deb true "$t/d" || fail "publish-debs refused a full staged run's trixie amd64: $(cat "$t/step.log")"
grep -qx 'SKELETON_ARCHES=amd64 arm64' "$t/env" || fail "a full staged deb publish's skeleton is not amd64 arm64: $(cat "$t/env")"
ok "publish-rpms, publish-debs: a full staged run publishes every architecture it built; its deb skeleton holds them"

# the purge makes the same skeleton
python3 -I - "$here/.github/actions/purge-staging/action.yml" <<'PY' || fail "the purge's deb skeleton is not the quick set's architectures"
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["runs"]["steps"]
assert any("staged-cells.sh\" arches deb" in (s.get("run") or "") or "staged-cells.sh arches deb" in (s.get("run") or "") for s in steps), "no step asks staged-cells.sh for the skeleton's architectures"
PY
ok "purge-staging: the deb skeleton is the quick set's architectures"
echo "staged-cells: all passed"
