#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# private-refs-check.sh: a public repository's tracked files and commit messages state facts and never point into a
# private repository: no private repository name, no private issue or pull request number, no private branch name or
# file path, no name of a private specification file. They name no private machine or home directory and no tool
# vendor either. Say what the value is and why instead, and cite only public repositories. Product-name mentions of
# OpenMixer, and values such as the org.openmixer.* CLAP ids, the urn:openmixer:* LV2 URIs and the @openmixer npm
# scope, are not pointers and are not matched.
#
#   check.sh [ROOT]               the check, over every file ROOT (default: the current directory) tracks
#   check.sh --messages RANGE     the same patterns, over the message of every commit in RANGE
#   check.sh --self-test          each sabotage, in every kind of file, must go red
#
# Nothing is exempt, this script included: it builds every shape it looks for and plants from parts, so that no line
# of it spells one.
set -euo pipefail

# Extended regexps, matched case-insensitively. A new kind of pointer is one line here.
PATTERNS=(
  '(FreeMixer|Open-Mixer)/''openmixer([^A-Za-z0-9_-]|$)' # the private repository, under either organisation
  'openmixer''-ops'                                     # the private operations repository
  'openmixer ?#[0-9]'                                 # one of its issues or pull requests
  '[A-Za-z0-9_.]-dev#[0-9]'                           # an issue of a private *-dev repository
  'integration/[A-Za-z0-9]'                           # a private integration branch
  '(^|[^A-Za-z0-9_-])packages/[a-z][a-z0-9-]+'        # a path into the private repository's packages: the segment
                                                      # itself, never the tail of dist-packages or site-packages
  '\.''vue([^A-Za-z0-9_]|$)'                            # its web UI components
  "openmixer's"" spec"                                  # its specification files
  'docs/''design/'                                      # its design documents
  'harness''/'                                          # its test harness
  '20[0-9]{2}-[0-9]{2}-[0-9]{2}-[a-z][a-z0-9-]+\.md'  # a dated specification file name
  'spec 20[0-9]{2}-[0-9]{2}-[0-9]{2}'                 # a citation of one
  'zero''signage'                                     # another private project
  '/var/''home/'                                      # a home directory on the desk's layout
  '/home/''pau([^A-Za-z0-9_-]|$)'                     # the maintainer's home directory
  '\.local/share/omx/''(coord|third)'                 # private working state, not the product's own data directory
  'claude\.''ai'                                      # a tool vendor's links
  'anthro''pic'                                       # a tool vendor
  'co-authored''-by'                                  # any such trailer, whoever it names
)
# Matched with case, because R1 to R14 are registers of a public protocol. The word r1 is a coefficient and h2 a heading
# in code, so those two count only where they read as a machine: after a word that names a place, an @, or before :/.
HOSTS=(
  '(^|[^A-Za-z0-9_-])ms''i([^A-Za-z0-9_-]|$)'
  '(^|[^A-Za-z0-9_$./-])(on|from|to|via|ssh|host|desk|at) +(r1|h2)([^A-Za-z0-9_-]|$)'
  '@(r1|h2)([^A-Za-z0-9_.-]|$)'
  '(^|[ "])(r1|h2):/'
)
EXTRA_PATHSPEC=()                 # the self-test sets a bad one, to prove a git grep error is red

check() { # <root>
  local root="$1" fail=0 args=() hargs=() p hits rc=0
  for p in "${PATTERNS[@]}"; do args+=(-e "$p"); done
  for p in "${HOSTS[@]}"; do hargs+=(-e "$p"); done
  # a CI container checks the tree out as another user, and git refuses a tree it does not own unless told
  [ -n "$(git -c safe.directory="$root" -C "$root" ls-files)" ] || { echo "private-refs-check: git lists no file" >&2; return 1; }
  # git grep exits 1 for no match and 128 or more for an error; an error must not read as "no hits"
  hits=$(git -c safe.directory="$root" -C "$root" grep -nIiE "${args[@]}" -- . "${EXTRA_PATHSPEC[@]}") || rc=$?
  case "$rc" in 0|1) ;; *) echo "private-refs-check: git grep failed (exit $rc)" >&2; return 1 ;; esac
  rc=0
  hits+=$'\n'$(git -c safe.directory="$root" -C "$root" grep -nIE "${hargs[@]}" -- . "${EXTRA_PATHSPEC[@]}") || rc=$?
  case "$rc" in 0|1) ;; *) echo "private-refs-check: git grep failed (exit $rc)" >&2; return 1 ;; esac
  hits=$(printf '%s' "$hits" | sed '/^$/d' | cut -c1-200)
  [ -z "$hits" ] || { printf '%s\n' "$hits" >&2; fail=1; }
  [ "$fail" = 0 ] || { echo "private-refs-check: the lines above point into private repositories; state the fact instead" >&2; return 1; }
  echo "private-refs-check: no tracked file points into a private repository"
}

messages() { # <range>, in the current directory
  local range="$1" args=() hargs=() p shas sha bad=0 n=0 text
  for p in "${PATTERNS[@]}"; do args+=(-e "$p"); done
  for p in "${HOSTS[@]}"; do hargs+=(-e "$p"); done
  shas=$(git -c safe.directory="$PWD" rev-list "$range") || { echo "private-refs-check: git cannot read $range" >&2; return 1; }
  [ -n "$shas" ] || { echo "private-refs-check: no commit in $range, so nothing was read" >&2; return 1; }
  # what the default branch already published is not this change's to answer for: a merge of main brings it in again
  if git -c safe.directory="$PWD" rev-parse -q --verify origin/main >/dev/null; then
    shas=$(git -c safe.directory="$PWD" rev-list "$range" --not origin/main) || { echo "private-refs-check: git cannot read $range" >&2; return 1; }
    [ -n "$shas" ] || { echo "private-refs-check: every commit in $range is on main already"; return 0; }
  fi
  while IFS= read -r sha; do
    n=$((n + 1))
    text=$(git -c safe.directory="$PWD" log -1 --format=%B "$sha") || { echo "private-refs-check: git cannot read $sha" >&2; return 1; }
    if grep -iE "${args[@]}" <<<"$text" >&2 || grep -E "${hargs[@]}" <<<"$text" >&2; then
      echo "private-refs-check: commit ${sha:0:12} points into a private repository; the lines above" >&2; bad=1
    fi
  done <<<"$shas"
  [ "$bad" = 0 ] || return 1
  echo "private-refs-check: $n commit messages read, none points into a private repository"
}

if [ "${1:-}" = --self-test ]; then
  scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
  fail=0
  # a clean tree with one file of each kind a repository tracks; every sabotage writes one private pointer into one
  mk() { rm -rf "$scratch/t"; mkdir -p "$scratch/t/src" "$scratch/t/tools" "$scratch/t/docs"
    git -C "$scratch" init -q t
    printf 'rdfs:comment "The OpenMixer console x." ;\nlv2:binary <x.so> ; # urn:openmixer:x\n' > "$scratch/t/src/x.ttl"
    printf '// org.openmixer.x, @openmixer/x\n' > "$scratch/t/tools/gen.mjs"
    printf '# Docs\n\nOpenMixer plugins.\n' > "$scratch/t/docs/a.md"
    printf '/* x */\n' > "$scratch/t/src/x.h"; printf '#!/bin/sh\n# x\n' > "$scratch/t/tools/x.sh"; }
  sab() { # <name> <file> <line>
    mk; printf '%s\n' "$3" >> "$scratch/t/$2"; git -C "$scratch/t" add -A
    if check "$scratch/t" >/dev/null 2>&1; then echo "SABOTAGE $1: STAYED GREEN"; fail=1; else echo "SABOTAGE $1: red"; fi; }
  mk; git -C "$scratch/t" add -A
  check "$scratch/t" >/dev/null || { echo "self-test: the clean tree is not green" >&2; exit 1; }
  sab repo-in-header src/x.h                         '/* as Open-Mixer/''openmixer draws it */'
  sab repo-old-org   src/y.h                         '/* as FreeMixer/''openmixer drew it */'
  sab branch-in-sh   tools/x.sh                      '# drawn on integration''/lean-engine'
  sab issue-in-md    docs/a.md                       'see openmixer''#1580'
  sab path-in-md     docs/a.md                       'packages''/web-ui/Foo.v''ue'
  sab default-path   tools/x.sh                      'plugin=${P:-$root/../openmixer/packages''/omx-plugins/bin/omx-delay.clap}'
  sab ops-in-mjs     tools/gen.mjs                   '// see openmixer''-ops'
  sab dev-in-mjs     tools/gen.mjs                   '// omx-dsp-dev''#32'
  sab spec-in-mjs    tools/gen.mjs                   "// openmixer's"" sp""ec 20""26-10-09-plugin-from-contract"".md"
  sab dated-filename tools/gen.mjs                   '// the layout in 2026-10-09-plugin-from-contract''.md'
  sab dated-citation tools/gen.mjs                   '// as laid out in spec ''2026-10-09'
  sab ttl            src/x.ttl       'rdfs:comment "see Open-Mixer/''openmixer''#12" ;'
  sab header         src/x.h         '/* packages''/core/src/x.ts */'
  sab path-quoted    docs/a.md                       'the server in `packages''/server/src/x`'
  sab path-in-path   tools/x.sh                      'ls ../packages''/server/src/x'
  sab design-dir     docs/a.md                       'the notes in docs/''design/specs'
  sab harness-dir    tools/gen.mjs                   '// harness''/dsp-check.sh'
  sab other-project  docs/a.md                       'see zero''signage/platform'
  sab var-home       tools/x.sh                      'cd /var/''home/someone/x'
  sab maintainer     tools/x.sh                      'cd /home/''pau/x'
  sab private-state  docs/a.md                       '~/.local/share/omx/''coord/state'
  sab vendor-link    docs/a.md                       'see https://claude.''ai/x'
  sab vendor-name    src/x.h                         '/* Anthro''pic */'
  sab trailer        docs/a.md                       'Co-Authored''-By: Someone <a@example.invalid>'
  sab host-msi       docs/a.md                       'built on ms''i overnight'
  sab host-json      tools/gen.mjs                   '"rig": "ms''i",'
  sab host-prose     docs/a.md                       'built on r''1 overnight'
  sab host-ssh       tools/x.sh                      'ssh h''2 true'
  sab host-at        tools/x.sh                      'scp a pau@r''1:b'
  sab host-path      tools/x.sh                      'rsync r''1:/tmp/a b'
  # what the patterns leave alone, each a line a public repository really carries
  mk; { printf '%s\n' 'R1 and R14 are open questions' 'double r1 = 0.5, h2 = x;' '<h2 class="omx-section-title">Comp</h2>' \
        'at $r1, the rate' 'const f = { r1: rot(3, 1024) };' '"id": "ms''i-20261017"' '/home/u/.clap' '/home/user/.lv2/a.ttl' \
        '/home/u/.local/share/omx/qualified' 'usr/lib/python3/dist-packages/plugin_hostd' 'lib/python3.14/site-packages/plugin_hostd/client.py' \
        >> "$scratch/t/docs/a.md"; }; git -C "$scratch/t" add -A
  if check "$scratch/t" >/dev/null 2>&1; then echo "LEGAL lines: green"; else echo "LEGAL lines: RED"; check "$scratch/t" 2>&1 | sed 's/^/  /'; fail=1; fi
  # the same patterns over commit messages
  mk; git -C "$scratch/t" add -A; g() { git -C "$scratch/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
  g commit -q -m base; g tag base
  g commit -q --allow-empty -m 'clean, R1 and R14 stay legal'
  if ( cd "$scratch/t" && messages base..HEAD >/dev/null 2>&1 ); then echo "MESSAGES clean: green"; else echo "MESSAGES clean: RED"; fail=1; fi
  if ( cd "$scratch/t" && messages HEAD..HEAD >/dev/null 2>&1 ); then echo "SABOTAGE messages-empty-range: STAYED GREEN"; fail=1; else echo "SABOTAGE messages-empty-range: red"; fi
  if ( cd "$scratch/t" && messages no-such-ref..HEAD >/dev/null 2>&1 ); then echo "SABOTAGE messages-bad-range: STAYED GREEN"; fail=1; else echo "SABOTAGE messages-bad-range: red"; fi
  # a commit main already carries is not read again, and one beside it still is
  g commit -q --allow-empty -m 'older' -m 'built on r''1 overnight'; g update-ref refs/remotes/origin/main HEAD
  if ( cd "$scratch/t" && messages base..HEAD >/dev/null 2>&1 ); then echo "MESSAGES on main: green"; else echo "MESSAGES on main: RED"; fail=1; fi
  g commit -q --allow-empty -m 'newer' -m 'built on r''1 overnight'
  if ( cd "$scratch/t" && messages base..HEAD >/dev/null 2>&1 ); then echo "SABOTAGE message beside main: STAYED GREEN"; fail=1; else echo "SABOTAGE message beside main: red"; fi
  g reset -q --hard HEAD~1; g update-ref -d refs/remotes/origin/main; g reset -q --hard HEAD~1
  for line in 'see openmixer''#1580' 'built on r''1 overnight' 'Fix the parser (zero''signage#3)' 'cd /var/''home/someone' 'Co-Authored''-By: Someone <a@example.invalid>'; do
    g commit -q --allow-empty -m 'a change' -m "$line"
    if ( cd "$scratch/t" && messages base..HEAD >/dev/null 2>&1 ); then echo "SABOTAGE message [$line]: STAYED GREEN"; fail=1; else echo "SABOTAGE message: red"; fi
    g reset -q --hard HEAD~1
  done
  # one message, as the commit-msg hook hands it over: git's comment lines are not part of it
  printf 'a change\n\nclean, R1 and R14 stay legal\n# a comment git drops: see openmixer''#1580\n' > "$scratch/msg-clean"
  if ( bash "$0" --msg-file "$scratch/msg-clean" >/dev/null 2>&1 ); then echo "MSG-FILE clean: green"; else echo "MSG-FILE clean: RED"; fail=1; fi
  for line in 'the check in harness''/pins-check.sh' 'see openmixer''#1580' 'built on r''1 overnight'; do
    printf 'a change\n\n%s\n' "$line" > "$scratch/msg-bad"
    if ( bash "$0" --msg-file "$scratch/msg-bad" >/dev/null 2>&1 ); then echo "SABOTAGE msg-file [$line]: STAYED GREEN"; fail=1; else echo "SABOTAGE msg-file: red"; fi
  done
  rc=0; bash "$0" --msg-file "$scratch/no-such-file" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then echo "SABOTAGE msg-file unreadable: red (2)"; else echo "SABOTAGE msg-file unreadable: exit $rc, not 2"; fail=1; fi
  mk; git -C "$scratch/t" add -A
  if ( EXTRA_PATHSPEC=(":(bogus)x"); check "$scratch/t" >/dev/null 2>&1 ); then echo "SABOTAGE git-grep-error: STAYED GREEN"; fail=1; else echo "SABOTAGE git-grep-error: red"; fi
  # nothing is exempt: a file that lists exemptions exempts nothing, and is itself no reason to look away
  mk; printf '// see openmixer''-ops\n' >> "$scratch/t/tools/gen.mjs"
  printf 'tools/gen.mjs   # reads a checkout the caller supplies\n' > "$scratch/t/tools/private-refs-allow.txt"; git -C "$scratch/t" add -A
  if check "$scratch/t" >/dev/null 2>&1; then echo "SABOTAGE allow-file: STAYED GREEN"; fail=1; else echo "SABOTAGE allow-file: red"; fi
  # reading nothing is red, and a checkout another user owns is read
  rm -rf "$scratch/t"; git -C "$scratch" init -q t
  if check "$scratch/t" >/dev/null 2>&1; then echo "SABOTAGE empty-tree: STAYED GREEN"; fail=1; else echo "SABOTAGE empty-tree: red"; fi
  rm -rf "$scratch/t"; mkdir -p "$scratch/t"
  if check "$scratch/t" >/dev/null 2>&1; then echo "SABOTAGE not-a-tree: STAYED GREEN"; fail=1; else echo "SABOTAGE not-a-tree: red"; fi
  mk; printf '// see openmixer''-ops\n' >> "$scratch/t/tools/gen.mjs"; git -C "$scratch/t" add -A
  # red for the planted line, not for a git that refused the tree: that would read nothing and say the same
  if out=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 check "$scratch/t" 2>&1); then echo "SABOTAGE another-owner: STAYED GREEN"; fail=1
  elif grep -q 'tools/gen.mjs' <<<"$out"; then echo "SABOTAGE another-owner: red"; else echo "SABOTAGE another-owner: red for another reason: $out"; fail=1; fi
  [ "$fail" = 0 ] || exit 1
  echo "private-refs-check self-test: every sabotage red"
  exit 0
fi
if [ "${1:-}" = --messages ]; then
  [ -n "${2:-}" ] || { echo "usage: check.sh --messages RANGE" >&2; exit 2; }
  messages "$2"
  exit
fi
root="${1:-.}"
check "$(cd "$root" && pwd)"
