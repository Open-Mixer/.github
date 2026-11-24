#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# docs-site.sh of the docs-site action (docs/docs-publish.md) on planted trees, then each guard taken out again.
# Arms: assemble renders Markdown and man pages beside their sources and rewrites links to .md pages; a tree with no
# index page gets one listing every page once; a tree with no page, an empty tree and a symbolic link are refused by
# name. place writes reference/<repo>/<version>/, moves
# latest/ only for the highest version (0.10.0 above 0.9.0, a backport below it leaves latest alone), writes the
# version list and the repository list, refuses a version or repository name that is no name, and a second place of
# the same version is a no-op in git. Sabotage: plain sort instead of version sort, a directory's own index left out of
# the written index, the no-page guard and the symbolic-link guard removed: each must turn an arm red.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
script=$here/../.github/actions/docs-site/docs-site.sh
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
command -v pandoc >/dev/null || { echo "SKIP-REFUSED: pandoc is not installed; the arms cannot run" >&2; exit 2; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

run_arms() { # $1: the script under test; exit status 0 when every arm holds
  local s=$1 w
  w=$(mktemp -d "$work/arms.XXXX")
  # assemble: Markdown, a man page, a link to a .md page and one to an anchor of it
  mkdir -p "$w/site/api" "$w/site/man"
  printf '# Reference\n\nSee [the protocol](protocol.md#verbs) and [the API](api/index.html).\n' > "$w/site/index.md"
  printf '# Protocol\n\n## Verbs\n\nping\n' > "$w/site/protocol.md"
  printf '<html><body>api</body></html>\n' > "$w/site/api/index.html"
  printf '.TH TOOL 1\n.SH NAME\ntool \\- does a thing\n' > "$w/site/man/tool.1"
  bash "$s" assemble "$w/site" >/dev/null || { echo "assemble refused a good tree"; return 1; }
  [ -f "$w/site/index.html" ] && [ -f "$w/site/protocol.html" ] && [ -f "$w/site/man/tool.1.html" ] \
    || { echo "assemble did not render every page"; return 1; }
  grep -q 'href="protocol.html#verbs"' "$w/site/index.html" || { echo "the .md link was not rewritten"; return 1; }
  grep -q 'href="api/index.html"' "$w/site/index.html" || { echo "an .html link was changed"; return 1; }
  grep -q 'does a thing' "$w/site/man/tool.1.html" || { echo "the man page was not rendered"; return 1; }
  # assemble refusals
  # no index page: one is written, every page of the top two levels once, a directory with an index.html as itself
  mkdir -p "$w/noindex/api" "$w/noindex/docs"; printf '# Alpha\n' > "$w/noindex/a.md"; printf '# Beta\n' > "$w/noindex/docs/b.md"
  printf '<html><head><title>API</title></head></html>\n' > "$w/noindex/api/index.html"; cp "$w/noindex/api/index.html" "$w/noindex/api/x.html"
  mkdir -p "$w/noindex/docs/plugins"; printf '# Plugin pages\n' > "$w/noindex/docs/plugins/README.md"; printf '# One\n' > "$w/noindex/docs/plugins/one.md"
  bash "$s" assemble "$w/noindex" omx-test >/dev/null || { echo "assemble refused a tree with no index page"; return 1; }
  grep -q '<h1>omx-test</h1>' "$w/noindex/index.html" || { echo "the written index lacks its title"; return 1; }
  for l in 'href="a.html">Alpha' 'href="docs/b.html">Beta' 'href="api/">API' 'href="docs/plugins/">Plugin pages'; do
    grep -q "$l" "$w/noindex/index.html" || { echo "the written index lacks $l"; return 1; }
  done
  if grep -q 'api/x.html\|plugins/one.html' "$w/noindex/index.html"; then echo "the written index lists a page of a directory that has its own index"; return 1; fi
  mkdir -p "$w/nopage"; printf 'x\n' > "$w/nopage/notes.txt"
  if bash "$s" assemble "$w/nopage" 2>"$w/err"; then echo "a tree with no page was accepted"; return 1; fi
  grep -q 'no page to index' "$w/err" || { echo "the no-page refusal names nothing"; return 1; }
  mkdir -p "$w/empty"
  if bash "$s" assemble "$w/empty" 2>"$w/err"; then echo "an empty tree was accepted"; return 1; fi
  mkdir -p "$w/link"; printf '# I\n' > "$w/link/index.md"; ln -s /etc/hostname "$w/link/host"
  if bash "$s" assemble "$w/link" 2>"$w/err"; then echo "a symbolic link was accepted"; return 1; fi
  grep -q 'symbolic link' "$w/err" || { echo "the symbolic-link refusal names nothing"; return 1; }
  # place: three versions in an order where plain sort and version sort disagree, then a backport
  local ch=$w/channel v
  mkdir -p "$ch"; git -C "$ch" init -q; git -C "$ch" commit -q --allow-empty -m init
  for v in 0.9.0 0.10.0 0.9.1; do
    rm -rf "$w/s-$v"; mkdir -p "$w/s-$v"; printf '<p>%s</p>\n' "$v" > "$w/s-$v/index.html"
    bash "$s" place "$w/s-$v" "$ch" omx-dsp "$v" >/dev/null || { echo "place refused $v"; return 1; }
  done
  for v in 0.9.0 0.10.0 0.9.1; do grep -q "<p>$v</p>" "$ch/reference/omx-dsp/$v/index.html" || { echo "$v not placed"; return 1; }; done
  grep -q '<p>0.10.0</p>' "$ch/reference/omx-dsp/latest/index.html" || { echo "latest is not the highest version"; return 1; }
  grep -q 'href="0.10.0/"' "$ch/reference/omx-dsp/index.html" || { echo "the version list lacks a version"; return 1; }
  grep -q 'href="omx-dsp/latest/"' "$ch/reference/index.html" || { echo "the repository list lacks the repository"; return 1; }
  git -C "$ch" add -A; git -C "$ch" commit -q -m one
  bash "$s" place "$w/s-0.9.1" "$ch" omx-dsp 0.9.1 >/dev/null
  git -C "$ch" add -A; git -C "$ch" diff --cached --quiet || { echo "a second place of one version changed the tree"; return 1; }
  for v in 1 v0.1.0 '0.1.0/../x' 'latest'; do
    if bash "$s" place "$w/s-0.9.0" "$ch" omx-dsp "$v" 2>/dev/null; then echo "version '$v' was accepted"; return 1; fi
  done
  for v in 'Omx' '../x' ''; do
    if bash "$s" place "$w/s-0.9.0" "$ch" "$v" 0.1.0 2>/dev/null; then echo "repository '$v' was accepted"; return 1; fi
  done
  return 0
}

bash "$script" --self-test >/dev/null || fail "the script's own self-test is red"
ok "self-test"
out=$(run_arms "$script") || fail "$out"
ok "every arm holds on the script"

# sabotage: each guard taken out must turn an arm red
sab() { # $1: name, $2: sed expression
  cp "$script" "$work/sab.sh"
  sed -i "$2" "$work/sab.sh"
  cmp -s "$script" "$work/sab.sh" && fail "sabotage '$1' did not apply"
  if out=$(run_arms "$work/sab.sh"); then fail "sabotage '$1' left every arm green"; fi
  ok "sabotage '$1' is red: $out"
}
sab "plain sort for the highest version" 's/sort -V/sort/g'
# shellcheck disable=SC2016 # sed expressions: $p and $pages are matched, never expanded
sab "a directory's own index left out of the written index" 's/^\( *\)\*\/index.html) echo "\$p" ;;/\1*\/index.html) ;;/'
# shellcheck disable=SC2016
sab "a directory's README not taken as its index" 's/cp "\$f" "\${f%\/README.html}\/index.html"/true/'
# shellcheck disable=SC2016
sab "the no-page guard removed" 's/^\( *\)\[ -n "\$pages" \] || die.*$/\1true/'
sab "the symbolic-link guard removed" 's/^\( *\)links=.*$/\1links=/'
echo "docs-site: $pass passed"
