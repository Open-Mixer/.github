#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# doc-gate doc-gate.sh [options] [--list | --update] | --self-test
#
# The one documentation gate of every OpenMixer C repository (and the Python beside it), run from the repository root.
# A repository keeps only its data: its Doxyfile, its baseline (the sorted set of doxygen's warnings it still carries,
# one row per undocumented declaration, keyed by file and text so a declaration that moves keeps its row), its pinned
# doxygen version, its ruff configuration and the Python paths ruff checks.
#
#   --doxyfile <file>     the Doxyfile (Doxyfile)                  --baseline <file>  the baseline (docs/doxygen-baseline.txt)
#   --pin <file>          the pinned doxygen version (docs/doxygen-version.txt)
#   --base <ref>          the base to shrink against, resolved by resolve-base (fetched, verified, refused by name;
#                         the base's files are read at the merge-base with HEAD); without it only the tree is judged
#   --py <path>           a Python path ruff checks (repeatable)    --ruff-config <file>  ruff's configuration (ruff.toml)
#   --ruff-version <v>    the pinned ruff version, required with --py (another ruff gives other findings)
#   --accept-config-change  the Doxyfile or the ruff configuration differs from the base's on purpose (this change);
#                         the flag is itself a finding when nothing differs, so it never stays in a workflow
#   --list                print the tree's rows and stop           --update  rewrite the baseline, only ever lower
#   DOXYGEN, RUFF         the binaries (doxygen, ruff)
#
# What doxygen says is only trusted when it provably read every header, so before the compare the gate refuses by name:
# a doxygen of another version than the pin (other versions give other rows); a Doxyfile, baseline or pin that is
# missing; a Doxyfile that silences what the gate counts, read back through `doxygen -x` (the effective settings,
# @INCLUDE resolved): EXTRACT_ALL, HIDE_UNDOC_*, WARNINGS, WARN_IF_UNDOCUMENTED, WARN_NO_PARAMDOC (it must be YES),
# WARN_IF_DOC_ERROR, WARN_IF_INCOMPLETE_DOC, WARN_AS_ERROR, WARN_FORMAT, a filter, EXCLUDE_PATTERNS; a tracked header of the
# Doxyfile's INPUT (FILE_PATTERNS, RECURSIVE, EXCLUDE honoured; git-tracked files only) with no @file in a doc comment
# (doxygen reports none of a file's undocumented members without one); an untracked header there (it would enter the
# reference unjudged); a header that hides code from doxygen (@cond, @internal, @private, @if); a warning log doxygen did not
# write; a header it wrote no HTML page for (it did not read it). The HTML is written to a throwaway directory,
# removed on exit: with every GENERATE_* off doxygen 1.9.8 never records @param and @return and warns on every
# function, documented or not. Every sort and comm runs under LC_ALL=C.
#
# The compare is a SET compare: a row the baseline does not carry is red by name (document the declaration, never
# extend the baseline), a baseline row nothing warns is red by name (strike it in the same change), a baseline that is
# not sorted and unique is red; --update rewrites the baseline from the tree only when that lowers it, and refuses by
# name otherwise. With --base: a baseline row the base's baseline does not carry is red (the list only shrinks); a
# watched Doxyfile setting that differs from the base's, each read through `doxygen -x` in its own tree, is red by
# key with both values unless --accept-config-change (the accepted change is then logged, key and both values); a
# setting read through doxygen -x_noenv, so an environment variable in it ($(VAR), which would read equal on both
# sides and differ at run time) is refused by key; a base
# without the gate's files is the change that brings it, and has nothing to compare. Watched means every setting but
# the ones that only shape the rendered output (PROJECT_*, OUTPUT_DIRECTORY, GENERATE_*, HTML_*, the graphs, the search).
#
# The Python half counts what ruff honours, with ruff itself: `ruff check` must be clean, and the suppressed findings
# (the count under --ignore-noqa minus the count without it: every form of noqa, file-level ones included) may not grow
# against the base, nor may the ruff configuration change without --accept-config-change.
#
# Exit 0 at the baseline; 1 a finding (the rows, the setting, the header, the suppression, an --update that would
# raise); 2 the gate cannot run (no doxygen, another version, a missing file, no log, a header not read, a base
# resolve-base refuses): never a pass.
#
# The limit that stays: a declaration under a preprocessor condition that is false with only the Doxyfile's PREDEFINED
# (an #ifdef X block) is not read, as a C compiler would not read it either; its rows are neither warned nor missed.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESOLVE_BASE=${RESOLVE_BASE:-$HERE/../resolve-base/resolve-base.sh}
DOXYGEN=${DOXYGEN:-doxygen}
RUFF=${RUFF:-ruff}

# the settings that only shape the rendered output and never a warning: free to change. Every other setting a Doxyfile
# carries (doxygen -x prints the ones that differ from the default) is compared with the base's and a change is red by
# key: a list of the keys that silence rows would always be one key short (EXTRACT_ALL, RECURSIVE and WARN_FORMAT were
# each found after such a list was written).
UNWATCHED='^(PROJECT_[A-Z_]+|OUTPUT_DIRECTORY|WARN_LOGFILE|QUIET|GENERATE_[A-Z_]+|HTML_[A-Z_]+|LATEX_[A-Z_]+|MAN_[A-Z_]+|RTF_[A-Z_]+|XML_[A-Z_]+|DOCBOOK_[A-Z_]+|HAVE_DOT|DOT_[A-Z_]+|[A-Z_]+_GRAPH|GRAPHICAL_HIERARCHY|SEARCHENGINE|SERVER_BASED_SEARCH|EXTERNAL_SEARCH|USE_MATHJAX|MATHJAX_[A-Z_]+)$'

cannot() { echo "doc-gate: $*" >&2; exit 2; }
finding() { echo "doc-gate: $*" >&2; RED=1; }
list() { sed 's/^/  /' >&2; }

# settings <doxyfile> <out>: the effective settings as doxygen reads them, one `KEY<TAB>VALUE` per line, continuations
# joined, runs of blanks folded; run in the directory the Doxyfile belongs to (its @INCLUDE paths)
settings() {
  "$DOXYGEN" -x_noenv "$1" 2>/dev/null | awk '
    /\\$/ { sub(/\\$/, ""); line = line $0; next }
    { line = line $0
      if (match(line, /^[A-Z_]+[ \t]*=/)) { key = substr(line, 1, RLENGTH - 1); sub(/[ \t]*$/, "", key)
        value = substr(line, RLENGTH + 1); gsub(/[ \t]+/, " ", value); sub(/^ /, "", value); sub(/ $/, "", value)
        print key "\t" value }
      line = "" }' > "$2"
}
setting() { awk -F '\t' -v k="$1" '$1 == k { print $2 }' "$2"; }

# headers <settings> <out>: the git-tracked files the Doxyfile's INPUT names (FILE_PATTERNS, RECURSIVE, EXCLUDE),
# and the untracked ones beside them in $out.untracked
headers() {
  local cfg=$1 out=$2 patterns recursive entry f rest p excluded
  patterns=$(setting FILE_PATTERNS "$cfg"); recursive=$(setting RECURSIVE "$cfg"); excluded=$(setting EXCLUDE "$cfg")
  [ -n "$patterns" ] || patterns='*.c *.cc *.cxx *.cpp *.c++ *.h *.hh *.hxx *.hpp *.h++'
  : > "$out"; : > "$out.untracked"
  set -f # the patterns are matched by case, never expanded
  for entry in $(setting INPUT "$cfg"); do
    for which in tracked untracked; do
      if [ "$which" = tracked ]; then git ls-files -- "$entry"; else git ls-files --others --exclude-standard -- "$entry"; fi |
      while IFS= read -r f; do
        if [ -d "$entry" ]; then
          rest=${f#"${entry%/}"/}
          case "$rest" in */*) [ "$recursive" = YES ] || continue ;; esac
          for p in $patterns; do
            # shellcheck disable=SC2254 # a pattern, matched as one
            case "${f##*/}" in $p) echo "$f"; break ;; esac
          done
        else
          echo "$f"
        fi
      done | while IFS= read -r f; do
        for p in $excluded; do
          case "$f" in "${p%/}" | "${p%/}"/*) continue 2 ;; esac
        done
        echo "$f"
      done >> "$([ "$which" = tracked ] && echo "$out" || echo "$out.untracked")"
    done
  done
  set +f
  sort -u -o "$out" "$out"; sort -u -o "$out.untracked" "$out.untracked"
}

# page <header>: the HTML page doxygen 1.9.8 writes for a file: its name, or, when another header shares the name, the
# path below the directory they have in common; _ written __, . written _8, / written _2
pages() { # <headers> -> "<header> <page>" lines
  awk '
    { path[NR] = $0; n = split($0, part, "/"); base[NR] = b = part[n]; count[b]++
      dir = substr($0, 1, length($0) - length(b))
      if (!(b in common)) common[b] = dir
      while (common[b] != "" && index(dir, common[b]) != 1) sub(/[^\/]*\/$/, "", common[b]) }
    END { for (i = 1; i <= NR; i++) {
            name = count[base[i]] > 1 ? substr(path[i], length(common[base[i]]) + 1) : base[i]
            gsub(/_/, "__", name); gsub(/\./, "_8", name); gsub(/\//, "_2", name)
            print path[i] " " name ".html" } }' "$1"
}

# rows <log> <root> <out>: doxygen's warnings as rows `file: text`, the root stripped, the line number dropped,
# continuation lines (the parameters a warning lists) joined, sorted unique; an error line is fatal
rows() {
  local log=$1 root=$2 out=$3
  sed "s#^$root/##" "$log" | awk '
    /^[^ \t]/ { if (r != "") print r; r = $0; next } { sub(/^[ \t]+/, ""); r = r " " $0 } END { if (r != "") print r }' > "$out.raw"
  if grep -q ': error: ' "$out.raw"; then grep ': error: ' "$out.raw" | list; cannot "doxygen reported an error: its warnings are not trusted"; fi
  sed -n 's/^\([^:]*\):[0-9][0-9]*: warning: /\1: /p' "$out.raw" | sort -u > "$out"
}

# suppressed <dir> <ruff-config> <paths...>: findings and suppressed findings as "<findings> <suppressed>"; what ruff
# honours, by ruff: the count under --ignore-noqa minus the count without
suppressed() {
  local dir=$1 cfg=$2 all with; shift 2
  count() { { (cd "$dir" && "$RUFF" check --config "$cfg" --output-format json "$@" -- "${paths[@]}" 2>/dev/null) || true; } |
    python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null; }
  local -a paths=()
  local p; for p in "$@"; do [ -e "$dir/$p" ] && paths+=("$p"); done
  [ "${#paths[@]}" -gt 0 ] || { echo "0 0"; return; }
  with=$(count) || cannot "ruff could not read $dir with $cfg"
  all=$(count --ignore-noqa) || cannot "ruff could not read $dir with $cfg under --ignore-noqa"
  if [ -z "$with" ] || [ -z "$all" ]; then cannot "ruff gave no JSON for $dir with $cfg: is ruff installed and the configuration readable?"; fi
  echo "$with $((all - with))"
}

gate() {
  local doxyfile=Doxyfile baseline=docs/doxygen-baseline.txt pin=docs/doxygen-version.txt base='' ruff_config=ruff.toml ruff_version=''
  local mode=check accept=0 base_given=0 root want have h page nofile hidden new stale grown changed mb key now_v base_v py_now py_base
  local -a py=()
  while [ $# -gt 0 ]; do
    case $1 in
      --doxyfile) doxyfile=$2; shift 2 ;;
      --baseline) baseline=$2; shift 2 ;;
      --pin) pin=$2; shift 2 ;;
      --base) base=$2; base_given=1; shift 2 ;;
      --py) py+=("$2"); shift 2 ;;
      --ruff-config) ruff_config=$2; shift 2 ;;
      --ruff-version) ruff_version=$2; shift 2 ;;
      --accept-config-change) accept=1; shift ;;
      --list) mode=list; shift ;;
      --update) mode=update; shift ;;
      *) cannot "unknown argument $1" ;;
    esac
  done
  RED=0
  root=$(pwd -P)
  [ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || cannot "$root is not the root of a git checkout: the gate reads the tracked headers from the repository root"
  command -v "$DOXYGEN" >/dev/null 2>&1 || cannot "doxygen ($DOXYGEN) is not installed"
  [ -f "$doxyfile" ] || cannot "no Doxyfile at $doxyfile"
  [ -f "$pin" ] || cannot "no pinned doxygen version at $pin"
  [ -f "$baseline" ] || cannot "no baseline at $baseline (a repository adopting the gate commits one, empty or by --update)"
  want=$(tr -d ' \n\r\t' < "$pin"); [ -n "$want" ] || cannot "$pin pins no doxygen version"
  have=$("$DOXYGEN" --version 2>/dev/null | head -n 1 | cut -d' ' -f1)
  [ "$have" = "$want" ] || cannot "doxygen is $have, $pin pins $want: other versions give other rows, run the gate with doxygen $want"
  if [ "${#py[@]}" -gt 0 ]; then
    command -v "$RUFF" >/dev/null 2>&1 || cannot "ruff ($RUFF) is not installed, and Python paths were given"
    [ -f "$ruff_config" ] || cannot "no ruff configuration at $ruff_config"
    [ -n "$ruff_version" ] || cannot "no ruff version pinned (--ruff-version): another ruff gives other findings"
    have=$("$RUFF" --version 2>/dev/null | head -n 1 | sed 's/^ruff //')
    [ "$have" = "$ruff_version" ] || cannot "ruff is $have, the pin is $ruff_version: other versions give other findings, run the gate with ruff $ruff_version"
  fi
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

  # the Doxyfile as doxygen reads it
  settings "$doxyfile" "$tmp/cfg"
  [ -s "$tmp/cfg" ] || cannot "doxygen -x could not read $doxyfile"
  for key in EXTRACT_ALL HIDE_UNDOC_MEMBERS HIDE_UNDOC_CLASSES FILTER_SOURCE_FILES; do
    [ "$(setting $key "$tmp/cfg")" != YES ] || finding "$doxyfile sets $key = YES, which hides what the gate counts"
  done
  for key in WARNINGS WARN_IF_UNDOCUMENTED WARN_IF_DOC_ERROR WARN_IF_INCOMPLETE_DOC; do
    [ "$(setting $key "$tmp/cfg")" != NO ] || finding "$doxyfile sets $key = NO, which silences what the gate counts"
  done
  [ "$(setting WARN_NO_PARAMDOC "$tmp/cfg")" = YES ] || finding "$doxyfile does not set WARN_NO_PARAMDOC = YES: a parameter without @param would not be counted"
  [ -z "$(setting WARN_AS_ERROR "$tmp/cfg")" ] || [ "$(setting WARN_AS_ERROR "$tmp/cfg")" = NO ] || finding "$doxyfile sets WARN_AS_ERROR: the gate reads the log, doxygen must write it whole"
  for key in INPUT_FILTER FILTER_PATTERNS EXCLUDE_PATTERNS; do
    [ -z "$(setting $key "$tmp/cfg")" ] || finding "$doxyfile sets $key = $(setting $key "$tmp/cfg"): a filter hides what the gate counts (EXCLUDE names a path, and is compared with the base)"
  done
  for key in $(cut -f1 "$tmp/cfg" | grep -Ev "$UNWATCHED" || true); do
    # shellcheck disable=SC2016 # the literal $( is matched
    case $(setting "$key" "$tmp/cfg") in *'$('*) finding "$doxyfile sets $key from an environment variable ($(setting "$key" "$tmp/cfg")): it would read equal against the base and differ at run time, write the value" ;; esac
  done
  for key in WARN_FORMAT WARN_LINE_FORMAT; do
    [ -z "$(setting $key "$tmp/cfg")" ] || finding "$doxyfile sets $key: the gate reads doxygen's own warning format, another one reads as no rows"
  done
  [ "$RED" = 0 ] || exit 1

  # the headers doxygen is to read: tracked, each documenting itself, none hiding code
  headers "$tmp/cfg" "$tmp/headers"
  [ -s "$tmp/headers" ] || cannot "the INPUT of $doxyfile names no git-tracked header: nothing would be checked"
  if grep -q '[[:space:]]' "$tmp/headers"; then grep '[[:space:]]' "$tmp/headers" | list; cannot "a header path carries whitespace: doxygen's INPUT cannot name it"; fi
  if [ -s "$tmp/headers.untracked" ]; then list < "$tmp/headers.untracked"; finding "untracked headers under the INPUT of $doxyfile would enter the reference unjudged: track or remove them"; fi
  nofile=$(while IFS= read -r h; do
    awk '/\/\*\*/ { doc = 1 } /^[ \t]*\/\/\// { doc = 1; line = 1 } doc && /[@\\]file([^A-Za-z_]|$)/ { found = 1 } /\*\// || line { doc = 0; line = 0 } END { exit !found }' "$h" || echo "$h"
  done < "$tmp/headers")
  if [ -n "$nofile" ]; then echo "$nofile" | list; finding "a header with no @file in a doc comment (/** @file or /// @file): doxygen reports none of its undocumented members without one"; fi
  hidden=$(xargs grep -nHE '[@\\](cond|endcond|internal|endinternal|private|privatesection|if|ifnot|endif)([^A-Za-z]|$)' < "$tmp/headers" || true)
  if [ -n "$hidden" ]; then echo "$hidden" | list; finding "a header hides code from doxygen (@cond, @internal, @private, @if): document it instead"; fi
  [ "$RED" = 0 ] || exit 1

  # doxygen over exactly those headers, its HTML thrown away, its warnings to a log of the gate's
  mkdir "$tmp/out"
  { cat "$doxyfile"
    echo "INPUT = $(tr '\n' ' ' < "$tmp/headers")"
    printf '%s\n' 'EXCLUDE =' "OUTPUT_DIRECTORY = $tmp/out" 'GENERATE_HTML = YES' 'GENERATE_LATEX = NO' 'GENERATE_MAN = NO' \
      'GENERATE_RTF = NO' 'GENERATE_XML = NO' 'GENERATE_DOCBOOK = NO' 'HAVE_DOT = NO' 'SEARCHENGINE = NO' 'QUIET = YES' \
      "WARN_LOGFILE = $tmp/warnings.log"
  } | "$DOXYGEN" - > /dev/null 2> "$tmp/doxygen.err" || { list < "$tmp/doxygen.err"; cannot "doxygen failed"; }
  [ -f "$tmp/warnings.log" ] || cannot "doxygen wrote no warning log: its warnings are unknown"
  while read -r h page; do
    [ -f "$tmp/out/html/$page" ] || finding "doxygen wrote no page for $h (html/$page): it did not read the header"
  done < <(pages "$tmp/headers")
  [ "$RED" = 0 ] || exit 2
  rows "$tmp/warnings.log" "$root" "$tmp/now"
  if [ "$mode" = list ]; then cat "$tmp/now"; exit 0; fi

  # the compare, as sets
  sort -c -u "$baseline" 2>/dev/null || finding "$baseline is not sorted and unique (LC_ALL=C sort -u)"
  [ "$RED" = 0 ] || exit 1
  sort -u "$baseline" > "$tmp/baseline"
  new=$(comm -23 "$tmp/now" "$tmp/baseline")
  if [ "$mode" = update ]; then
    if [ -n "$new" ]; then echo "$new" | list; echo "doc-gate: --update only lowers the baseline; these rows are not in it (document the declaration)" >&2; exit 1; fi
    cp "$tmp/now" "$baseline"
    echo "doc-gate: $baseline written, $(wc -l < "$tmp/now") rows ($(wc -l < "$tmp/baseline") before)"
    exit 0
  fi
  if [ -n "$new" ]; then echo "$new" | list; finding "rows the baseline does not carry (document the declaration, never extend the baseline)"; fi
  stale=$(comm -13 "$tmp/now" "$tmp/baseline")
  if [ -n "$stale" ]; then echo "$stale" | list; finding "baseline rows nothing warns now (strike them from $baseline)"; fi

  # the Python half: clean under ruff, and what ruff honours counted by ruff
  if [ "${#py[@]}" -gt 0 ]; then
    if ! (cd "$root" && "$RUFF" check --config "$ruff_config" --output-format concise -- "${py[@]}") > "$tmp/ruff.out" 2>&1; then
      list < "$tmp/ruff.out"; finding "ruff check finds what the Python does not document"
    fi
    py_now=$(suppressed "$root" "$ruff_config" "${py[@]}")
    echo "doc-gate: ${py_now#* } suppressed ruff findings (noqa, every form ruff honours) in ${py[*]}"
  fi

  # the base: its files at the merge-base, through resolve-base
  if [ "$base_given" = 1 ]; then
    mb=$(bash "$RESOLVE_BASE" "$base" | sed -n 's/^merge-base=//p') || exit $?
    [ -n "$mb" ] || cannot "resolve-base gave no merge-base for $base"
    mkdir "$tmp/base"
    git archive "$mb" | tar -x -C "$tmp/base" || cannot "could not read the tree at the merge-base ${mb:0:12} with $base"
    changed=0
    if [ -f "$tmp/base/$baseline" ]; then
      sort -u "$tmp/base/$baseline" > "$tmp/baseline.base"
      grown=$(comm -23 "$tmp/baseline" "$tmp/baseline.base")
      if [ -n "$grown" ]; then echo "$grown" | list; finding "the baseline only shrinks; rows added against $base (${mb:0:12}): document the declarations instead"; fi
      echo "doc-gate: baseline $(wc -l < "$tmp/baseline") rows, $(wc -l < "$tmp/baseline.base") at the merge-base with $base"
    else
      echo "doc-gate: $base has no $baseline at the merge-base (this change brings the gate): nothing to compare"
    fi
    if [ -f "$tmp/base/$doxyfile" ]; then
      (cd "$tmp/base" && settings "$doxyfile" "$tmp/cfg.base")
      for key in $(cut -f1 "$tmp/cfg" "$tmp/cfg.base" | sort -u | grep -Ev "$UNWATCHED" || true); do
        now_v=$(setting "$key" "$tmp/cfg"); base_v=$(setting "$key" "$tmp/cfg.base")
        if [ "$now_v" != "$base_v" ]; then
          changed=1
          if [ "$accept" = 1 ]; then echo "doc-gate: accepted: $doxyfile changes $key against $base: '${base_v:-(default)}' there, '${now_v:-(default)}' here"
          else finding "$doxyfile changes $key against $base: '${base_v:-(default)}' there, '${now_v:-(default)}' here (a narrowed reference is no lower baseline; --accept-config-change when it is meant)"; fi
        fi
      done
    else
      echo "doc-gate: $base has no $doxyfile at the merge-base (this change brings the gate): nothing to compare"
    fi
    if [ "${#py[@]}" -gt 0 ]; then
      if [ -f "$tmp/base/$ruff_config" ]; then
        if ! cmp -s "$ruff_config" "$tmp/base/$ruff_config"; then
          changed=1
          if [ "$accept" = 1 ]; then echo "doc-gate: accepted: $ruff_config differs from the base's at $base"; diff -u "$tmp/base/$ruff_config" "$ruff_config" | sed 's/^/  /' || true
          else finding "$ruff_config differs from the base's at $base: a changed configuration is no fewer findings (--accept-config-change when it is meant)"; fi
        fi
        py_base=$(suppressed "$tmp/base" "$ruff_config" "${py[@]}")
        if [ "${py_now#* }" -gt "${py_base#* }" ]; then
          finding "the suppressed ruff findings grew from ${py_base#* } to ${py_now#* } against $base: fix the finding instead of a noqa"
        fi
      else
        echo "doc-gate: $base has no $ruff_config at the merge-base (this change brings the gate): nothing to compare"
      fi
    fi
    if [ "$accept" = 1 ] && [ "$changed" = 0 ]; then finding "--accept-config-change given, but neither $doxyfile nor $ruff_config differs from the base's: drop the flag"; fi
  fi

  [ "$RED" = 0 ] || exit 1
  echo "doc-gate: $(wc -l < "$tmp/now") undocumented declarations, all in $baseline, none new, none stale"
}

self_test() {
  local fail=0 script t main_c ckey rkey
  script=$HERE/${BASH_SOURCE[0]##*/}
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null
  ok() { echo "ok   $1"; }
  no() { echo "FAIL $1"; fail=1; echo "--- output:"; cat "$work/out"; }

  # the stand-in doxygen: --version answers $STANDIN/version; -x prints a Doxyfile's settings (one @INCLUDE followed);
  # a run reads the piped config, writes $STANDIN/warnings as the log (each row `path: text` at line 1; a row with
  # ` || ` is a warning with a continuation line) unless $STANDIN/nolog exists, and a page for every INPUT file but
  # those $STANDIN/nopage lists
  local standin=$work/standin; mkdir -p "$standin"; echo 1.9.8 > "$standin/version"
  cat > "$work/doxygen" <<'SH'
#!/bin/bash
S=${STANDIN:?}
if [ "${1:-}" = --version ]; then cat "$S/version"; exit 0; fi
if [ "${1:-}" = -x ] || [ "${1:-}" = -x_noenv ]; then
  awk '/^@INCLUDE[ \t]*=/ { f = $3; while ((getline l < f) > 0) print l; next } /^[A-Z_]+[ \t]*\+?=/' "$2"; exit 0
fi
cfg=$(cat)
get() { printf '%s\n' "$cfg" | sed -n "s/^$1[ \t]*=[ \t]*//p" | tail -n 1; }
out=$(get OUTPUT_DIRECTORY); log=$(get WARN_LOGFILE); mkdir -p "$out/html"
[ -f "$S/nolog" ] || sed "s#^\([^:]*\): #$PWD/\1:1: warning: #; s# || #\n  #g" "$S/warnings" > "$log"
for h in $(get INPUT); do
  grep -qx "$h" "$S/nopage" 2>/dev/null && continue
  : > "$out/html/$(basename "$h" | sed 's/_/__/g; s/\./_8/g').html"
done
SH
  chmod +x "$work/doxygen"
  # the fixtures' bases are local branches with no upstream, and the fixture is their authority (resolve-base, .github#121)
  export STANDIN=$standin DOXYGEN=$work/doxygen RESOLVE_BASE=$HERE/../resolve-base/resolve-base.sh RESOLVE_BASE_LOCAL_AUTHORITY=1

  # the scratch repository: `before` has no gate; `main` brings it; `topic` is one commit on, the tree the arms edit
  t=$work/tree; mkdir -p "$t/src" "$t/docs" "$t/py"
  git init -q -b main "$t"
  echo '# t' > "$t/README.md"; git -C "$t" add -A; git -C "$t" commit -qm before; git -C "$t" branch before
  printf 'INPUT = src\nFILE_PATTERNS = *.h\nWARN_NO_PARAMDOC = YES\nEXTRACT_STATIC = YES\nPREDEFINED = X=\n' > "$t/Doxyfile"
  echo 1.9.8 > "$t/docs/doxygen-version.txt"
  printf '/** @file\n * @brief A.\n */\nint A;\nint B;\n' > "$t/src/a.h"
  printf 'src/a.h: Member A is not documented.\nsrc/a.h: Member B is not documented.\n' > "$standin/warnings"
  cp "$standin/warnings" "$t/docs/doxygen-baseline.txt"
  printf '[lint]\nselect = ["D"]\n' > "$t/ruff.toml"
  printf '"""M."""\n\n\ndef f():  # noqa: D103\n    return 1\n' > "$t/py/m.py"
  git -C "$t" add -A; git -C "$t" commit -qm gate
  git -C "$t" checkout -qb topic; echo topic >> "$t/README.md"; git -C "$t" commit -qam topic
  main_c=$(git -C "$t" rev-parse main)

  # run <args...>: the gate in the tree, output to $work/out, the status returned
  run() { (cd "$t" && bash "$script" "$@") > "$work/out" 2>&1; }
  G=(--doxyfile Doxyfile --baseline docs/doxygen-baseline.txt --pin docs/doxygen-version.txt)
  local ruff_real; ruff_real=$(ruff --version 2>/dev/null | head -n 1 | sed 's/^ruff //')
  B=(--base main --py py --ruff-config ruff.toml --ruff-version "${ruff_real:-none}")
  green() { local what=$1; shift; if run "$@"; then ok "$what"; else no "$what"; fi; }
  # red <what> <exit> <text> <args...>: the status and the text, in the output
  red() { local what=$1 want=$2 text=$3 got=0; shift 3; run "$@" || got=$?
    if [ "$got" = "$want" ] && grep -qF -- "$text" "$work/out"; then ok "$what"; else no "$what (exit $got, wanted $want naming '$text')"; fi; }
  reset() { git -C "$t" reset -q --hard && git -C "$t" clean -qfd; rm -f "$standin/nolog" "$standin/nopage"; echo 1.9.8 > "$standin/version"
    printf 'src/a.h: Member A is not documented.\nsrc/a.h: Member B is not documented.\n' > "$standin/warnings"; }

  green "the tree at its baseline" "${G[@]}"
  green "the tree at its baseline, against the base, with the Python" "${G[@]}" "${B[@]}"
  echo 'src/a.h: Member C is not documented.' >> "$standin/warnings"
  red "a row the baseline does not carry is red, by name" 1 "src/a.h: Member C" "${G[@]}"
  red "--update refuses to raise the baseline, by name" 1 "--update only lowers" "${G[@]}" --update
  if [ "$(wc -l < "$t/docs/doxygen-baseline.txt")" = 2 ]; then ok "the refused --update left the baseline"; else no "the refused --update wrote the baseline"; fi
  reset; sed -i '1d' "$standin/warnings"
  red "a baseline row nothing warns is red, by name" 1 "src/a.h: Member A" "${G[@]}"
  green "--update lowers the baseline when a listed row is gone" "${G[@]}" --update
  if [ "$(wc -l < "$t/docs/doxygen-baseline.txt")" = 1 ]; then ok "the baseline is one row after --update"; else no "the baseline after --update"; fi
  reset; printf 'src/a.h: Member A is not documented.\nsrc/a.h: Member C is not documented.\n' > "$standin/warnings"
  red "a swapped row: the compare is a set, the dropped row named" 1 "src/a.h: Member B" "${G[@]}"
  red "a swapped row: the compare is a set, the new row named" 1 "src/a.h: Member C" "${G[@]}"
  reset; echo 'src/a.h: Member A is not documented.' >> "$t/docs/doxygen-baseline.txt"
  red "a duplicated baseline row is red" 1 "not sorted and unique" "${G[@]}"
  reset; printf 'src/a.h: Member A is not documented.\nsrc/a.h: Member B is not documented.' > "$t/docs/doxygen-baseline.txt"
  green "a baseline without its last newline is the same set" "${G[@]}"
  reset; printf 'src/a.h: The following parameters of f(int a, int b) are not documented: || parameter a || parameter b\n' > "$standin/warnings"
  red "a warning with continuation lines is one row, joined" 1 "src/a.h: The following parameters of f(int a, int b) are not documented: parameter a parameter b" "${G[@]}"
  reset
  if run "${G[@]}" --list && [ "$(cat "$work/out")" = "$(cat "$standin/warnings")" ]; then ok "--list prints the tree's rows"; else no "--list"; fi

  rm "$t/Doxyfile"; red "no Doxyfile is refused by name" 2 "no Doxyfile at Doxyfile" "${G[@]}"; reset
  rm "$t/docs/doxygen-baseline.txt"; red "no baseline is refused by name" 2 "no baseline at docs/doxygen-baseline.txt" "${G[@]}"; reset
  rm "$t/docs/doxygen-version.txt"; red "no pin is refused by name" 2 "no pinned doxygen version at docs/doxygen-version.txt" "${G[@]}"; reset
  : > "$t/docs/doxygen-version.txt"; red "an empty pin is refused by name" 2 "pins no doxygen version" "${G[@]}"; reset
  echo 1.18.0 > "$standin/version"; red "a doxygen of another version is refused, both named" 2 "doxygen is 1.18.0, docs/doxygen-version.txt pins 1.9.8" "${G[@]}"; reset
  DOXYGEN=$work/none red "no doxygen is refused by name" 2 "doxygen ($work/none) is not installed" "${G[@]}"
  : > "$standin/nolog"; red "a doxygen that writes no log is refused by name" 2 "wrote no warning log" "${G[@]}"; reset
  echo src/a.h > "$standin/nopage"; red "a header doxygen wrote no page for is refused by name" 2 "no page for src/a.h" "${G[@]}"; reset
  if (cd "$t/src" && bash "$script" "${G[@]}") > "$work/out" 2>&1; then no "from a subdirectory"; elif grep -q "not the root" "$work/out"; then ok "a subdirectory is refused: the gate runs from the repository root"; else no "subdirectory message"; fi

  printf 'int C;\n' > "$t/src/b.h"; git -C "$t" add src/b.h
  red "a tracked header with no @file is red, by name" 1 "src/b.h" "${G[@]}"; reset
  printf '/* @file not a doc comment */\nint C;\n' > "$t/src/b.h"; git -C "$t" add src/b.h
  red "an @file outside a doc comment is red, by name" 1 "src/b.h" "${G[@]}"; reset
  printf '/// @file\n/// @brief B.\nint C;\n' > "$t/src/b.h"; git -C "$t" add src/b.h
  echo 'src/b.h: Member C is not documented.' >> "$standin/warnings"; sort -o "$standin/warnings" "$standin/warnings"
  cp "$standin/warnings" "$t/docs/doxygen-baseline.txt"
  green "a /// @file line is a doc comment" "${G[@]}"; reset
  printf '/** @file */\nint C;\n' > "$t/src/b.h"
  red "an untracked header under INPUT is red, by name" 1 "src/b.h" "${G[@]}"; reset
  printf '/** @file\n * @brief A.\n */\n/// @cond HIDE\nint A;\n/// @endcond\nint B;\n' > "$t/src/a.h"
  red "a header hiding code with @cond is red, by name" 1 "src/a.h:4" "${G[@]}"; reset
  printf '/** @file\n * @brief A.\n * @internal\n */\nint A;\nint B;\n' > "$t/src/a.h"
  red "a header hiding code with @internal is red, by name" 1 "src/a.h:3" "${G[@]}"; reset
  printf '/** @file\n * @brief A.\n */\nint A;\n/** @private */\nint B;\n' > "$t/src/a.h"
  red "a header hiding a declaration with @private is red, by name" 1 "src/a.h:5" "${G[@]}"; reset
  printf '/** @file\n * @brief A.\n */\nint A;\n/** \\private*/\nint B;\n' > "$t/src/a.h"
  red "a \\private closed by the comment end with no blank is red, by name" 1 "src/a.h:5" "${G[@]}"; reset
  # shellcheck disable=SC2016 # the Doxyfile line is literal
  printf 'EXCLUDE_SYMBOLS = $(HIDE)\n' >> "$t/Doxyfile"
  red "a compared setting read from an environment variable is red, by key" 1 "sets EXCLUDE_SYMBOLS from an environment variable" "${G[@]}"; reset
  echo 'EXTRACT_ALL = YES' >> "$t/Doxyfile"; red "EXTRACT_ALL = YES is red, by key" 1 "Doxyfile sets EXTRACT_ALL = YES" "${G[@]}"; reset
  echo 'HIDE_UNDOC_MEMBERS = YES' >> "$t/Doxyfile"; red "HIDE_UNDOC_MEMBERS = YES is red, by key" 1 "sets HIDE_UNDOC_MEMBERS = YES" "${G[@]}"; reset
  echo 'WARN_IF_UNDOCUMENTED = NO' >> "$t/Doxyfile"; red "WARN_IF_UNDOCUMENTED = NO is red, by key" 1 "sets WARN_IF_UNDOCUMENTED = NO" "${G[@]}"; reset
  sed -i '/WARN_NO_PARAMDOC/d' "$t/Doxyfile"; red "a Doxyfile without WARN_NO_PARAMDOC = YES is red, by key" 1 "does not set WARN_NO_PARAMDOC = YES" "${G[@]}"; reset
  echo 'INPUT_FILTER = cat' >> "$t/Doxyfile"; red "a filter is red, by key" 1 "sets INPUT_FILTER = cat" "${G[@]}"; reset
  echo 'EXCLUDE_PATTERNS = */a.h' >> "$t/Doxyfile"; red "EXCLUDE_PATTERNS is red, by key" 1 "sets EXCLUDE_PATTERNS = */a.h" "${G[@]}"; reset
  echo 'WARN_FORMAT = "file"' >> "$t/Doxyfile"; red "WARN_FORMAT set is red, by key" 1 "sets WARN_FORMAT" "${G[@]}"; reset
  sed -i 's/^INPUT = src$/INPUT = nowhere/' "$t/Doxyfile"; red "an INPUT with no tracked header is refused by name" 2 "names no git-tracked header" "${G[@]}"; reset
  printf 'INPUT = src\n' > "$t/inc.dox"; sed -i 's/^INPUT = src$/@INCLUDE = inc.dox/' "$t/Doxyfile"
  green "a setting behind @INCLUDE is read as doxygen reads it" "${G[@]}"; reset

  # against the base
  echo 'EXCLUDE = src/b.h' >> "$t/Doxyfile"
  red "a watched Doxyfile setting changed against the base is red, by key, both values" 1 "Doxyfile changes EXCLUDE against main: '(default)' there, 'src/b.h' here" "${G[@]}" "${B[@]}"
  # the acceptance is bound to the change (.github#120): the red names the change's key, and only that key accepts it
  ckey=$(sed -n 's/.*--accept-config-change \([0-9a-f]\{16\}\).*/\1/p' "$work/out" | head -n 1)
  if [ -n "$ckey" ]; then ok "and names the change's key ($ckey)"; else no "the red does not name the change's key"; fi
  green "the same change, accepted by its key" "${G[@]}" "${B[@]}" --accept-config-change "$ckey"
  if grep -q "accepted: Doxyfile changes EXCLUDE against main: '(default)' there, 'src/b.h' here" "$work/out" && grep -q "accepted change $ckey" "$work/out"; then ok "and the accepted change is logged, key and both values, and the change's key"; else no "the accepted change is not logged"; fi
  red "a key that is not this change's (true) is red, naming the change's key" 1 "the key true is not this change's: $ckey" "${G[@]}" "${B[@]}" --accept-config-change true
  if grep -q "Doxyfile changes EXCLUDE against main" "$work/out"; then ok "and every changed setting is red again, by key"; else no "a wrong key does not name the changed setting"; fi
  echo 'ALIASES = "x=y"' >> "$t/Doxyfile"
  red "a later configuration change under the same key is red again, by key" 1 "Doxyfile changes ALIASES against main" "${G[@]}" "${B[@]}" --accept-config-change "$ckey"
  if grep -q "the key $ckey is not this change's" "$work/out"; then ok "and the key is named as another change's"; else no "the stale key is not named"; fi
  red "a bare --accept-config-change (no key) is refused by name" 2 "--accept-config-change needs the change's key" "${G[@]}" "${B[@]}" --accept-config-change
  reset; red "the accept flag with nothing changed is itself red: it never stays" 1 "drop the flag" "${G[@]}" "${B[@]}" --accept-config-change "$ckey"
  sed -i 's/^PREDEFINED = X=$/PREDEFINED = X= Y=/' "$t/Doxyfile"
  red "PREDEFINED changed against the base is red, by key" 1 "Doxyfile changes PREDEFINED against main" "${G[@]}" "${B[@]}"; reset
  echo 'ALIASES = "x=y"' >> "$t/Doxyfile"
  red "any setting but the output ones changed against the base is red, by key (ALIASES)" 1 "Doxyfile changes ALIASES against main" "${G[@]}" "${B[@]}"; reset
  echo 'PROJECT_NUMBER = 2' >> "$t/Doxyfile"
  green "a setting that only shapes the output (PROJECT_NUMBER) may change" "${G[@]}" "${B[@]}"; reset
  echo 'src/a.h: Member C is not documented.' >> "$standin/warnings"; cp "$standin/warnings" "$t/docs/doxygen-baseline.txt"
  green "a baseline row added, no base: the tree agrees with itself" "${G[@]}"
  red "the same row against the base is red: the baseline only shrinks, the row named" 1 "src/a.h: Member C" "${G[@]}" "${B[@]}"
  reset; sed -i '1d' "$standin/warnings"; cp "$standin/warnings" "$t/docs/doxygen-baseline.txt"
  green "a baseline row struck against the base" "${G[@]}" "${B[@]}"; reset
  green "a base without the gate's files is the change that brings it" "${G[@]}" --base before --py py --ruff-config ruff.toml --ruff-version "${ruff_real:-none}"
  if grep -q "before has no Doxyfile at the merge-base" "$work/out" && grep -q "before has no docs/doxygen-baseline.txt" "$work/out" && grep -q "before has no ruff.toml" "$work/out"; then ok "and says so, each file by name"; else no "the files the base lacks are not named"; fi
  red "an empty base is refused by name (resolve-base)" 1 "the base is empty" "${G[@]}" --base ''
  red "a base this clone does not hold is refused by name (resolve-base)" 2 "no-such does not resolve" "${G[@]}" --base no-such
  git -C "$t" remote add origin "file://$work/gone"; git -C "$t" update-ref refs/remotes/origin/main "$main_c"
  red "a stale remote base whose fetch fails is refused by name, never read (resolve-base)" 2 "could not fetch origin/main from origin" "${G[@]}" --base origin/main
  git -C "$t" remote remove origin

  # the Python half
  printf '\n\ndef g():\n    return 2\n' >> "$t/py/m.py"
  red "a ruff finding is red, by name" 1 "D103" "${G[@]}" "${B[@]}"; reset
  for form in '# noqa' '#noqa: D103' '# NOQA' '# noqa:D103' '#   noqa : D103' '# noqa D103' '# noqa: D103 # second' '# NoQA'; do
    printf '\n\ndef g():  %s\n    return 2\n' "$form" >> "$t/py/m.py"
    red "a suppression added ($form) is red: the suppressed findings grew" 1 "suppressed ruff findings grew from 1 to 2" "${G[@]}" "${B[@]}"; reset
  done
  printf '# ruff: noqa\n"""N."""\n\n\ndef h():\n    return 3\n' > "$t/py/n.py"
  red "a file-level ruff: noqa is counted" 1 "suppressed ruff findings grew from 1 to 2" "${G[@]}" "${B[@]}"; reset
  printf '# flake8: noqa\n"""N."""\n\n\ndef h():\n    return 3\n' > "$t/py/n.py"
  red "a file-level flake8: noqa is counted" 1 "suppressed ruff findings grew from 1 to 2" "${G[@]}" "${B[@]}"; reset
  printf '"""M."""\n\n\ndef f():\n    """F."""\n    return 1\n' > "$t/py/m.py"
  green "a suppression removed with the function documented" "${G[@]}" "${B[@]}"; reset
  printf '\n[lint.per-file-ignores]\n"py/*" = ["D103"]\n' >> "$t/ruff.toml"
  red "a changed ruff configuration against the base is red, by name" 1 "ruff.toml differs from the base's" "${G[@]}" "${B[@]}"
  rkey=$(sed -n 's/.*--accept-config-change \([0-9a-f]\{16\}\).*/\1/p' "$work/out" | head -n 1)
  [ "$rkey" != "$ckey" ] && [ -n "$rkey" ] && ok "the ruff change has its own key ($rkey)" || no "the ruff change's key ($rkey)"
  green "the same change, accepted by its key" "${G[@]}" "${B[@]}" --accept-config-change "$rkey"
  if grep -q "accepted: ruff.toml differs from the base's at main" "$work/out" && grep -q '^  +\[lint.per-file-ignores\]' "$work/out"; then ok "and the accepted change is logged, with its diff"; else no "the accepted ruff change is not logged"; fi
  reset
  red "a ruff of another version than the pin is refused, both named" 2 "ruff is $ruff_real, the pin is 0.0.1" "${G[@]}" --base main --py py --ruff-config ruff.toml --ruff-version 0.0.1
  red "no ruff pin with Python paths given is refused by name" 2 "no ruff version pinned" "${G[@]}" --base main --py py --ruff-config ruff.toml
  RUFF=$work/none red "no ruff with Python paths given is refused by name" 2 "ruff ($work/none) is not installed" "${G[@]}" "${B[@]}"
  rm "$t/ruff.toml"; red "no ruff configuration is refused by name" 2 "no ruff configuration at ruff.toml" "${G[@]}" "${B[@]}"; reset

  # sabotage: the set compare turned into a count compare passes the swap; the settings check removed passes EXTRACT_ALL
  # shellcheck disable=SC2016 # the script's own text is matched
  sed '/^gate()/,/^}/s/new=$(comm -23 "$tmp\/now" "$tmp\/baseline")/new=$([ "$(wc -l < "$tmp\/now")" -gt "$(wc -l < "$tmp\/baseline")" ] \&\& cat "$tmp\/now" || true)/; /^gate()/,/^}/s/stale=$(comm -13 "$tmp\/now" "$tmp\/baseline")/stale=/' "$script" > "$work/count.sh"
  printf 'src/a.h: Member A is not documented.\nsrc/a.h: Member C is not documented.\n' > "$standin/warnings"
  if (cd "$t" && bash "$work/count.sh" "${G[@]}") > "$work/out" 2>&1; then ok "sabotage: a count compare passes the swap, so the set compare is what catches it"; else no "sabotage: the set compare"; fi
  reset
  sed '/^gate()/,/^}/s/^  for key in EXTRACT_ALL .*/  for key in; do/' "$script" > "$work/nocheck.sh"
  echo 'EXTRACT_ALL = YES' >> "$t/Doxyfile"
  if (cd "$t" && bash "$work/nocheck.sh" "${G[@]}") > "$work/out" 2>&1; then ok "sabotage: without the settings check EXTRACT_ALL passes, so the check is what catches it"; else no "sabotage: the settings check"; fi
  reset
  # shellcheck disable=SC2016 # the script's own text is matched
  sed '/^gate()/,/^}/s/grown=$(comm -23 "$tmp\/baseline" "$tmp\/baseline.base")/grown=/' "$script" > "$work/nogrown.sh"
  echo 'src/a.h: Member C is not documented.' >> "$standin/warnings"; cp "$standin/warnings" "$t/docs/doxygen-baseline.txt"
  if (cd "$t" && bash "$work/nogrown.sh" "${G[@]}" "${B[@]}") > "$work/out" 2>&1; then ok "sabotage: without the base compare an added row passes, so the compare is what catches it"; else no "sabotage: the base compare"; fi
  reset
  # shellcheck disable=SC2016 # the script's own text is matched
  sed '/^gate()/,/^}/s/if \[ "$now_v" != "$base_v" \]; then/if false; then/' "$script" > "$work/nodoxyfile.sh"
  echo 'EXCLUDE = src/b.h' >> "$t/Doxyfile"
  if (cd "$t" && bash "$work/nodoxyfile.sh" "${G[@]}" "${B[@]}") > "$work/out" 2>&1; then ok "sabotage: without the Doxyfile compare a changed EXCLUDE passes, so the compare is what catches it"; else no "sabotage: the Doxyfile compare"; fi
  reset
  # shellcheck disable=SC2016 # the script's own text is matched
  sed '/^gate()/,/^}/s/if \[ "${py_now#\* }" -gt "${py_base#\* }" \]; then/if false; then/' "$script" > "$work/nonoqa.sh"
  printf '\n\ndef g():  # noqa\n    return 2\n' >> "$t/py/m.py"
  if (cd "$t" && bash "$work/nonoqa.sh" "${G[@]}" "${B[@]}") > "$work/out" 2>&1; then ok "sabotage: without the suppression compare a noqa added passes, so the compare is what catches it"; else no "sabotage: the suppression compare"; fi
  reset

  # the real doxygen: a fully documented function gives no row (the throwaway HTML: with every GENERATE_* off, 1.9.8
  # warns on every @param and @return); with its @return dropped it warns, by name, so doxygen read it; two headers of
  # one name are both paged; a planted EXTRACT_ALL is read back through doxygen -x
  local real=${DOXYGEN_REAL:-doxygen} r=$work/real
  if command -v "$real" > /dev/null 2>&1; then
    mkdir -p "$r/src" "$r/sub" "$r/docs"; git init -q -b main "$r"
    printf 'INPUT = src sub\nFILE_PATTERNS = *.h\nWARN_NO_PARAMDOC = YES\nEXTRACT_STATIC = YES\n' > "$r/Doxyfile"
    "$real" --version | head -n 1 | cut -d' ' -f1 > "$r/docs/doxygen-version.txt"; : > "$r/docs/doxygen-baseline.txt"
    printf '/** @file\n * @brief A.\n */\n\n/**\n * @brief The sum.\n * @param a One addend.\n * @param b The other.\n * @return a + b.\n */\nint add(int a, int b);\n' > "$r/src/a.h"
    printf '/** @file\n * @brief The other a.h.\n */\n\n/**\n * @brief One.\n * @return 1.\n */\nint one(void);\n' > "$r/sub/a.h"
    git -C "$r" add -A
    rr() { (cd "$r" && DOXYGEN=$real bash "$script" "${G[@]}") > "$work/out" 2>&1; }
    if rr; then ok "the real doxygen: two fully documented headers of one name give no row"; else no "the real doxygen on documented headers"; fi
    sed -i '/@return/d' "$r/src/a.h"
    if ! rr && grep -q 'src/a.h: return type of member add' "$work/out"; then ok "the real doxygen read the header: its @return dropped warns, by name"; else no "the real doxygen: @return dropped"; fi
    git -C "$r" checkout -q -- src/a.h; echo 'EXTRACT_ALL = YES' >> "$r/Doxyfile"
    if ! rr && grep -q 'sets EXTRACT_ALL = YES' "$work/out"; then ok "the real doxygen -x: a planted EXTRACT_ALL is read back"; else no "the real doxygen -x"; fi
  else
    echo "doxygen ($real) is not installed" > "$work/out"; no "the real doxygen arm: $real is not installed (DOXYGEN_REAL names it)"
  fi

  [ "$fail" = 0 ] && echo "doc-gate self-test: every arm as wanted"
  return "$fail"
}

if [ "${1:-}" = --self-test ]; then self_test; exit $?; fi
gate "$@"
