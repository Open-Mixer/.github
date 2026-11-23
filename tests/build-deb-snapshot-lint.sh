#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# What build-deb.sh hands lintian. A snapshot's version carries the commit time and sha by design, so for a source with a
# long name its .changes and .buildinfo file names draw package-has-long-file-name, which no package override can cover:
# a snapshot build suppresses that one tag and no other. A tag build has no suffix and lints in full. Needs no dpkg
# tools: dpkg-parsechangelog, apt-get, dpkg-buildpackage and lintian are stubs on PATH, lintian records its arguments.
#
#   tests/build-deb-snapshot-lint.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir bin
cat > bin/dpkg-parsechangelog <<'STUB'
#!/bin/bash
head=$(head -1 debian/changelog)
case $2 in
    Version) echo "$head" | sed 's/^[^(]*(\([^)]*\)).*/\1/' ;;
    Source) echo "${head%% *}" ;;
esac
STUB
cat > bin/apt-get <<'STUB'
#!/bin/bash
exit 0
STUB
cat > bin/dpkg-buildpackage <<'STUB'
#!/bin/bash
v=$(dpkg-parsechangelog -S Version)
n=$(dpkg-parsechangelog -S Source)
touch "../${n}_${v}_arm64.changes" "../${n}_${v}_arm64.deb"
STUB
cat > bin/lintian <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$LINTIAN_ARGS"
STUB
chmod +x bin/*
export PATH="$work/bin:$PATH"

long=plugin-db-qualification
git init -q -b main "$long"
mkdir "$long/debian"
printf '%s (1.0.0) unstable; urgency=medium\n\n  * x\n\n -- t <t@t>  Wed, 30 Sep 2026 12:00:00 +0000\n' "$long" > "$long/debian/changelog"
git -C "$long" add -A
GIT_COMMITTER_DATE=2026-09-30T12:00:00Z git -C "$long" commit -q -m "First version" --date 2026-09-30T12:00:00Z
git -C "$long" tag v1.0.0

fail=0
run() { # <name> <build-deb.sh args...>: build a fresh clone, lintian's arguments land in $work/<name>.args
    local name=$1
    shift
    rm -rf "t-$name"
    mkdir "t-$name"
    git clone -q "$long" "t-$name/$long"
    : > "$work/$name.args"
    LINTIAN_ARGS="$work/$name.args" "$here/.github/actions/build-deb/build-deb.sh" -C "t-$name/$long" "$@" "t-$name/out" > "$name.log" 2>&1 \
        || { tail -20 "$name.log"; echo "FAIL the $name build"; fail=1; }
}
run snapshot
run tag -t v1.0.0

[ "$(wc -l < snapshot.args)" = 1 ] || { echo "FAIL the snapshot build ran lintian $(wc -l < snapshot.args) times"; fail=1; }
grep -q -- '--fail-on error,warning' snapshot.args || { echo "FAIL the snapshot's lintian does not fail on warnings: $(cat snapshot.args)"; fail=1; }
grep -q -- '--suppress-tags package-has-long-file-name ' snapshot.args || { echo "FAIL the snapshot's lintian does not suppress package-has-long-file-name: $(cat snapshot.args)"; fail=1; }
[ "$(grep -o -- '--suppress-tags' snapshot.args | wc -l)" = 1 ] && [ "$(grep -o -- 'suppress-tags [^ ]*' snapshot.args)" = "suppress-tags package-has-long-file-name" ] \
    || { echo "FAIL the snapshot suppresses more than package-has-long-file-name: $(cat snapshot.args)"; fail=1; }
[ "$(wc -l < tag.args)" = 1 ] || { echo "FAIL the tag build ran lintian $(wc -l < tag.args) times"; fail=1; }
grep -q -- '--fail-on error,warning' tag.args || { echo "FAIL the tag's lintian does not fail on warnings: $(cat tag.args)"; fail=1; }
! grep -q -- '--suppress-tags' tag.args || { echo "FAIL the tag build suppresses a lintian tag: $(cat tag.args)"; fail=1; }
[ "$fail" = 0 ] && echo "ok: a snapshot suppresses package-has-long-file-name, a tag build lints in full"
exit "$fail"
