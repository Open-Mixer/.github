#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# public-layout-check check.sh [ROOT] | --self-test
#
# A public OpenMixer repository holds its code, its data and the documents a user or a developer reads: a guide, a
# specification or reference, a developer document. The record of how work went (a dated note, a run's raw evidence, a
# folder of notes) belongs in the project's records, not in a public tree. Three rules, read from every tracked path:
#
#   - no folder named evidence or notes, at any depth;
#   - no folder whose name carries a date (YYYY-MM-DD or YYYYMMDD): a dated folder is one run's record;
#   - no document (markdown, plain text, reStructuredText, AsciiDoc) whose name carries a date: a dated document is a note.
#
# A data file named by its date or by a run id (a benchmark run, a catalogue run, a fixture, a key) is data and passes;
# a date inside a file's content is never read. No path is exempted: there is no list.
set -euo pipefail

DATE='(^|[^0-9])(20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])|20[0-9]{2}(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01]))([^0-9]|$)'
RECORDS='^(evidence|notes)$'
DOCUMENT='\.(md|markdown|txt|text|rst|adoc|asciidoc)$'

check() { # <root>
  local root=$1 bad=0 path dir name parts i
  local files
  files=$(git -c safe.directory="$root" -C "$root" ls-files) || { echo "public-layout-check: git lists no file" >&2; return 1; }
  [ -n "$files" ] || { echo "public-layout-check: git lists no file" >&2; return 1; }
  declare -A seen=()
  while IFS= read -r path; do
    IFS=/ read -r -a parts <<<"$path"
    dir=
    for ((i = 0; i < ${#parts[@]} - 1; i++)); do
      dir=${dir:+$dir/}${parts[i]}
      [ -z "${seen[$dir]:-}" ] || continue
      seen[$dir]=1
      if [[ ${parts[i]} =~ $RECORDS ]]; then echo "public-layout-check: $dir/ is a folder of ${parts[i]}" >&2; bad=1; fi
      if [[ ${parts[i]} =~ $DATE ]]; then echo "public-layout-check: $dir/ is a dated folder" >&2; bad=1; fi
    done
    name=${parts[${#parts[@]} - 1]}
    if [[ $name =~ $DOCUMENT ]] && [[ $name =~ $DATE ]]; then echo "public-layout-check: $path is a dated document" >&2; bad=1; fi
  done <<<"$files"
  [ "$bad" = 0 ] || return 1
  echo "public-layout-check: no dated document, no dated folder, no evidence or notes folder"
}

if [ "${1:-}" = --self-test ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
  tree() { # a clean tree, plus each path given
    rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/src" "$t/r/docs"
    echo 'int main(void) { return 0; }' > "$t/r/src/main.c"; echo '# Guide' > "$t/r/docs/guide.md"
    local p; for p in "$@"; do mkdir -p "$t/r/$(dirname "$p")"; echo x > "$t/r/$p"; done
    git -C "$t/r" add -A
  }
  red() { # <what> <path>...
    local what=$1; shift; tree "$@"
    if check "$t/r" >/dev/null 2>&1; then echo "FAIL $what"; fail=1; else echo "ok   $what"; fi
  }
  green() { # <what> <path>...
    local what=$1; shift; tree "$@"
    if check "$t/r" >/dev/null 2>&1; then echo "ok   $what"; else echo "FAIL $what"; fail=1; fi
  }
  green "a tree of code and guides is green"
  red "a dated note is red" docs/bench-chain-2026-10-21.md
  red "a compact date in a document's name is red" docs/report-20261102.txt
  red "a dated folder is red" docs/pi5-matrix-2026-11-02/run.json
  red "a dated folder under another is red" bench/runs/20261028/log.csv
  red "an evidence folder is red" doc/evidence/verbs.tsv
  red "a notes folder at any depth is red" docs/"de"sign/notes/chains.md
  red "a top-level notes folder is red" notes/x.json
  green "a data file named by its date passes" plugin-catalog/runs/2026-10-26.json
  green "a run id carrying a date passes" benchmarks/runs/rpi5-20261102-1.json
  green "a version is no date" test/fixtures/omx-contract-2.10.0/limits.h
  green "a long number is no date" data/ids/202611021234567.json
  green "a folder whose name only contains the word passes" docs/footnotes/a.md
  # sabotage: with the three rules gone, every planted record passes, so the rules are what catch them
  sed -e "s/^DATE=.*/DATE='^\$NEVER'/" -e "s/^RECORDS=.*/RECORDS='^\$NEVER'/" "${BASH_SOURCE[0]}" > "$t/sab.sh"
  tree docs/bench-chain-2026-10-21.md doc/evidence/v.tsv docs/pi5-2026-11-02/r.json
  if bash "$t/sab.sh" "$t/r" >/dev/null 2>&1; then echo "ok   sabotage: without its rules the check passes every record"; else echo "FAIL sabotage: the rules are not what catches a record"; fail=1; fi
  [ "$fail" = 0 ] && echo "public-layout-check self-test: every case as wanted"
  exit "$fail"
fi
check "${1:-.}"
