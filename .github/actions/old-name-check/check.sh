#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# old-name-check check.sh [ROOT [PATHSPEC...]] | --self-test
#
# The organisation is Open-Mixer and the product OpenMixer. A document a user or a developer reads names neither by
# the organisation's former name, and links to neither the former organisation on GitHub nor its former Pages site.
# Three patterns, read from every line of every document:
#
#   - the former name as a word, spelled as the name is spelled (capital F, capital M);
#   - a GitHub address under the former organisation (github.com/<former>/..., github.com:<former>/...), any case;
#   - the former Pages host (<former>.github.io), any case.
#
# A document is a README, a markdown, reStructuredText or AsciiDoc file, any file under a docs/, doc/ or man/ folder,
# a man page (name.N, name.N.in), debian/control, and an RPM spec above its %changelog; PATHSPEC adds more (a site's
# pages and catalogs), and an exclude pathspec (:!path) takes a path out, for a tree that holds copies of another
# repository's documents which that repository's own run reads. A changelog (CHANGELOG*, NEWS*, debian/changelog, a spec's %changelog) is history and is not
# read. The former name in lower case inside an identifier (a package scope, a plugin id, a runner label, a key file)
# is code, not prose, and passes: renaming an identifier is a code change of its own, never this check's.
#
# An issue cited under the former organisation is never rewritten to the same number under Open-Mixer: the Open-Mixer
# repositories are new repositories, not the former ones renamed, and the same number names another issue there
# (omx-dsp#41 is the bandwidth-to-Q law in the former repository and a curve family in the new one). A document states
# the fact instead of the citation.
set -euo pipefail

OLD=Free
OLD="${OLD}Mixer"
NAME="(^|[^A-Za-z0-9_])${OLD}([^A-Za-z0-9_]|$)"
ADDRESS="github\.com[:/]${OLD,,}/|${OLD,,}\.github\.io"
DOCUMENT='(^|/)README[^/]*$|\.(md|markdown|rst|adoc|asciidoc)$|(^|/)(docs|doc|man)/|\.[1-8](\.in)?$|(^|/)debian/control$|\.spec$'
HISTORY='(^|/)(CHANGELOG|NEWS|HISTORY)[^/]*$|(^|/)debian/changelog$'

check() { # <root> [pathspec...]
  local root=$1 bad=0 path n
  shift
  local files extra='' spec include=() exclude=()
  for spec in "$@"; do case $spec in ':!'* | ':(exclude)'*) exclude+=("$spec") ;; *) include+=("$spec") ;; esac; done
  files=$(git -c safe.directory="$root" -C "$root" ls-files -- . "${exclude[@]}") || { echo "old-name-check: git lists no file" >&2; return 1; }
  [ -n "$files" ] || { echo "old-name-check: git lists no file" >&2; return 1; }
  if [ "${#include[@]}" -gt 0 ]; then extra=$(git -c safe.directory="$root" -C "$root" ls-files -- "${include[@]}" "${exclude[@]}"); fi
  n=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [[ $path =~ $HISTORY ]] && continue
    [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || continue
    grep -I -q . "$root/$path" 2>/dev/null || continue # binary or empty: no prose
    n=$((n + 1))
    if [[ $path == *.spec ]]; then
      hits=$(NAME="$NAME" ADDRESS="$ADDRESS" awk '/^%changelog/ {exit} { if ($0 ~ ENVIRON["NAME"] || tolower($0) ~ ENVIRON["ADDRESS"]) printf "%d:%s\n", NR, $0 }' "$root/$path")
    else
      hits=$( { grep -n -E -- "$NAME" "$root/$path" || true; grep -n -i -E -- "$ADDRESS" "$root/$path" || true; } | sort -t: -k1,1n -u)
    fi
    if [ -n "$hits" ]; then
      while IFS= read -r h; do echo "old-name-check: $path:$h" >&2; done <<<"$hits"
      bad=1
    fi
  done < <({ grep -E -- "$DOCUMENT" <<<"$files" || true; [ -z "$extra" ] || printf '%s\n' "$extra"; } | sort -u)
  [ "$n" -gt 0 ] || { echo "old-name-check: no document to read" >&2; return 1; }
  [ "$bad" = 0 ] || { echo "old-name-check: a document names the former organisation; write Open-Mixer (the organisation) or OpenMixer (the product), and link github.com/Open-Mixer" >&2; return 1; }
  echo "old-name-check: $n documents, none names the former organisation"
}

if [ "${1:-}" = --self-test ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
  tree() { # a clean tree, plus each <path>=<line> given
    rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/docs" "$t/r/src"
    printf '# Guide\n\nOpenMixer, from Open-Mixer: https://github.com/Open-Mixer/omx-dsp\n' > "$t/r/README.md"
    echo 'int main(void) { return 0; }' > "$t/r/src/main.c"
    local a p; for a in "$@"; do p=${a%%=*}; mkdir -p "$t/r/$(dirname "$p")"; printf '%s\n' "${a#*=}" >> "$t/r/$p"; done
    git -C "$t/r" add -A
  }
  run() { local what=$1 want=$2; shift 2; local spec=(); while [ "$#" -gt 0 ] && [ "$1" != -- ]; do spec+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
    tree "${spec[@]}"
    if check "$t/r" "$@" >/dev/null 2>&1; then got=green; else got=red; fi
    if [ "$got" = "$want" ]; then echo "ok   $what"; else echo "FAIL $what (wanted $want, got $got)"; fail=1; fi
  }
  run "a tree that names Open-Mixer and OpenMixer is green" green
  run "the former name in a README is red" red "README.md=the ${OLD} console"
  run "the former name in a guide is red" red "docs/guide.md=from ${OLD}/omx-dsp#41"
  run "a link to the former organisation is red, any case" red "docs/a.md=see https://github.com/${OLD,,}/omx-dsp"
  run "the former Pages host is red" red "doc/install.txt=https://${OLD,,}.github.io/rpm"
  run "a man page is read" red "man/omx.1=.SH ${OLD}"
  run "debian/control is read" red "debian/control=Description: the ${OLD} library"
  run "a spec above its %changelog is read" red "pkg/x.spec=%description" "pkg/x.spec=the ${OLD} library"
  run "a spec's %changelog is history" green "pkg/x.spec=%changelog" "pkg/x.spec=- ${OLD}/.github checks"
  run "a CHANGELOG is history" green "CHANGELOG.md=- the ${OLD} name"
  run "debian/changelog is history" green "debian/changelog=  * ${OLD}/.github workflow"
  run "an identifier in lower case passes" green "docs/b.md=\`@${OLD,,}/core\`, org.${OLD,,}.comp, arc-${OLD,,}, RPM-GPG-KEY-${OLD,,}"
  run "a word that only contains the name passes" green "docs/c.md=${OLD}s and Un${OLD}"
  run "code is not a document" green "src/x.c=/* ${OLD} */"
  run "a pathspec adds a site's pages" red "app/pages/index.v""ue=<p>${OLD}</p>" -- app/pages
  run "without the pathspec a site page is not read" green "app/pages/index.v""ue=<p>${OLD}</p>"
  run "an exclude pathspec takes a copied tree out" green "content/projects/x/README.md=the ${OLD} name" -- ':!content/projects'
  run "an exclude takes out only what it names" red "content/projects/x/README.md=ok" "docs/d.md=${OLD}" -- ':!content/projects'
  # sabotage: with the patterns gone, every planted line passes, so the patterns are what catch it
  sed -e "s/^NAME=.*/NAME='^\$NEVER'/" -e "s/^ADDRESS=.*/ADDRESS='^\$NEVER'/" "${BASH_SOURCE[0]}" > "$t/sab.sh"
  tree "README.md=the ${OLD} console" "docs/a.md=https://github.com/${OLD}/x" "doc/i.txt=${OLD,,}.github.io"
  if bash "$t/sab.sh" "$t/r" >/dev/null 2>&1; then echo "ok   sabotage: without its patterns the check passes every planted line"; else echo "FAIL sabotage: the patterns are not what catches a line"; fail=1; fi
  [ "$fail" = 0 ] && echo "old-name-check self-test: every case as wanted"
  exit "$fail"
fi
root=${1:-.}
[ "$#" -gt 0 ] && shift
check "$root" "$@"
