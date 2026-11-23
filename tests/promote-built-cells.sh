#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# promote-staged's built-cells.py, on stub packages (docs/release-operations.md, "Promoting a staged version"). Proves:
#   - a missing cell built from the staged commit is published; the built noarch and source packages of a release whose
#     tested cell is kept are dropped, so the kept staged copies are never replaced;
#   - a cell whose build or install check failed is not published and is named FAILED; the healthy cell beside it is
#     published all the same, and the exit status is 3 (the caller publishes, then ends red);
#   - a cell built from another commit is FAILED, named, and none of it goes out;
#   - a built file of a kept cell is refused outright and nothing is copied;
#   - a re-run, after collect.py found the root serving every cell but the failed one, publishes only that cell and no
#     file the root already serves.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bc=$here/.github/actions/promote-staged/built-cells.py
collect=$here/.github/actions/promote-staged/collect.py
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }
mk() { mkdir -p "$(dirname "$1")"; echo "$1" > "$1"; }
T=1794480000.
run() { # <out> <args>...: built-cells.py's exit status in $rc, its stdout in $t/log
    local out=$1; shift
    rm -rf "$out"
    rc=0; python3 -I "$bc" "$@" --out "$out" > "$t/log" 2>&1 || rc=$?
}

# ---- rpm: the tested fc45 x86_64 kept from staging, fc45 aarch64 missing and built
mk "$t/kept/omx-lib-3.14.0-1.git${T}5f455d3.fc45.x86_64.rpm"
mk "$t/kept/omx-lib-data-3.14.0-1.git${T}5f455d3.fc45.noarch.rpm"
mk "$t/kept/omx-lib-3.14.0-1.git${T}5f455d3.fc45.src.rpm"
echo "45 aarch64" > "$t/rpm.missing"
mk "$t/b1/omx-lib-3.14.0-1.git${T}5f455d3.fc45.aarch64.rpm"
mk "$t/b1/omx-lib-devel-3.14.0-1.git${T}5f455d3.fc45.aarch64.rpm"
mk "$t/b1/omx-lib-data-3.14.0-1.git${T}5f455d3.fc45.noarch.rpm"
mk "$t/b1/omx-lib-3.14.0-1.git${T}5f455d3.fc45.src.rpm"
r=(rpm --version 3.14.0 --commit 5f455d3 --missing "$t/rpm.missing" --kept "$t/kept")
run "$t/o1" "${r[@]}" --built "$t/b1"
[ "$rc" = 0 ] || fail "rpm: a healthy missing cell exits $rc: $(cat "$t/log")"
grep -qx 'published 45 aarch64' "$t/log" || fail "rpm: 45 aarch64 not published: $(cat "$t/log")"
[ "$(cd "$t/o1" && ls | sort | tr '\n' ' ')" = "omx-lib-3.14.0-1.git${T}5f455d3.fc45.aarch64.rpm omx-lib-devel-3.14.0-1.git${T}5f455d3.fc45.aarch64.rpm " ] ||
    fail "rpm: the publish takes $(ls "$t/o1"), not the two aarch64 packages alone"
grep -q 'dropped omx-lib-data-.*noarch.rpm: 45 keeps the staged copy' "$t/log" || fail "rpm: the built noarch is not dropped by name"
ok "rpm: the missing cell is published from the staged commit; the built noarch and source never replace the kept copies"

# a failed install check: nothing of the cell goes out, it is named, exit 3
run "$t/o2" "${r[@]}" --built "$t/b1" --failed "45 aarch64"
[ "$rc" = 3 ] || fail "rpm: a failed cell exits $rc, not 3"
grep -qx 'FAILED 45 aarch64: its build or install check failed' "$t/log" || fail "rpm: the failed cell is not named: $(cat "$t/log")"
[ -z "$(ls -A "$t/o2")" ] || fail "rpm: a failed cell published $(ls "$t/o2")"
ok "rpm: a cell whose install check failed publishes nothing, is named FAILED, and the run ends 3"

# another commit: FAILED, named, nothing out
mk "$t/b3/omx-lib-3.14.0-1.git${T}0badc0d.fc45.aarch64.rpm"
run "$t/o3" "${r[@]}" --built "$t/b3"
[ "$rc" = 3 ] && grep -q '^FAILED 45 aarch64: built from another commit or version than 3.14.0 of 5f455d3' "$t/log" ||
    fail "rpm: a cell built from 0badc0d is not refused by name (exit $rc): $(cat "$t/log")"
[ -z "$(ls -A "$t/o3")" ] || fail "rpm: a cell of another commit published $(ls "$t/o3")"
ok "rpm: a cell built from another commit than the staged one is FAILED, named, and publishes nothing"

# a kept cell rebuilt: refused outright
mk "$t/b4/omx-lib-3.14.0-1.git${T}5f455d3.fc45.aarch64.rpm"
mk "$t/b4/omx-lib-3.14.0-1.git${T}5f455d3.fc45.x86_64.rpm"
run "$t/o4" "${r[@]}" --built "$t/b4"
[ "$rc" = 2 ] && grep -q 'not missing (kept or served, never rebuilt)' "$t/log" || fail "rpm: a rebuilt kept cell is not refused (exit $rc): $(cat "$t/log")"
[ ! -e "$t/o4" ] || [ -z "$(ls -A "$t/o4")" ] || fail "rpm: a refused run copied files"
ok "rpm: a built file of a kept cell is refused and nothing is copied"

# ---- deb: two missing cells, one healthy, one with no build: the healthy one is published, the other FAILED
printf 'trixie amd64\nforky amd64\n' > "$t/deb.missing"
mk "$t/kd/trixie/libomx-lib0_3.14.0+git${T}5f455d3_arm64.deb"
mk "$t/kd/trixie/omx-lib-data_3.14.0+git${T}5f455d3_all.deb"
mk "$t/bd/trixie/libomx-lib0_3.14.0+git${T}5f455d3_amd64.deb"
mk "$t/bd/trixie/omx-lib-data_3.14.0+git${T}5f455d3_all.deb"
run "$t/od" deb --version 3.14.0 --commit 5f455d3 --missing "$t/deb.missing" --kept "$t/kd" --built "$t/bd"
[ "$rc" = 3 ] || fail "deb: one healthy and one failed cell exit $rc, not 3"
grep -qx 'published trixie amd64' "$t/log" && grep -qx 'FAILED forky amd64: no package was built' "$t/log" || fail "deb: $(cat "$t/log")"
[ "$(cd "$t/od" && find . -type f | sort | tr '\n' ' ')" = "./trixie/libomx-lib0_3.14.0+git${T}5f455d3_amd64.deb " ] ||
    fail "deb: the publish takes $(cd "$t/od" && find . -type f)"
ok "deb: the healthy cell is published, laid out by suite; the cell with no build is FAILED; the kept all is not replaced"

# ---- the re-run: the root serves every cell but the one that failed; only that one is missing and published
c=$t/ch
mk "$c/staging/rpm/fedora/45/x86_64/omx-lib-3.14.0-1.git${T}5f455d3.fc45.x86_64.rpm"
mk "$c/staging/rpm/fedora/45/noarch/omx-lib-data-3.14.0-1.git${T}5f455d3.fc45.noarch.rpm"
mk "$c/staging/rpm/fedora/45/SRPMS/omx-lib-3.14.0-1.git${T}5f455d3.fc45.src.rpm"
mk "$c/rpm/fedora/45/x86_64/omx-lib-3.14.0-1.git${T}5f455d3.fc45.x86_64.rpm"
mk "$c/rpm/fedora/45/noarch/omx-lib-data-3.14.0-1.git${T}5f455d3.fc45.noarch.rpm"
python3 -I "$collect" "$c" rpm --name omx-lib --version 3.14.0 --binaries "omx-lib omx-lib-data" --releases 45 \
    --arches "x86_64 aarch64" --commit 5f455d3 --out "$t/rk" > "$t/clog" 2>&1 || fail "re-run: collect failed: $(cat "$t/clog")"
[ "$(cat "$t/rk.missing")" = "45 aarch64" ] || fail "re-run: missing is '$(cat "$t/rk.missing")'"
run "$t/or" rpm --version 3.14.0 --commit 5f455d3 --missing "$t/rk.missing" --kept "$t/rk" --built "$t/b1"
[ "$rc" = 0 ] || fail "re-run: exit $rc: $(cat "$t/log")"
for f in "$t"/or/*; do
    [ -z "$(find "$c/rpm" -name "$(basename "$f")")" ] || fail "re-run: $(basename "$f") is already served and would be published again"
done
ok "a re-run builds and publishes only the cell that failed, never a file the root serves"
echo "promote-built-cells: all passed"
