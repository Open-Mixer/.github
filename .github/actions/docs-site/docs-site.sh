#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# docs-site docs-site.sh assemble <site> [title] | place <site> <channel> <repo> <version> | --self-test
#
# The one renderer and the one placer of every OpenMixer repository's generated reference (docs/docs-publish.md).
# A repository's `make docs-site DOCS_OUT=<site>` writes what its own generators produce (doxygen's html, Markdown its
# tools render from source, its man pages); nothing here generates content, and nothing is ever written by hand.
#
#   assemble <site>   every *.md becomes *.html beside it and every man page *.[1-8] becomes *.[1-8].html (pandoc),
#                     a link to a .md page is rewritten to its .html page. With no index.html, one is written (its
#                     heading [title], default the directory's name): every page of the top two levels by its own
#                     <title>, a directory that has an index.html once.
#                     Refused by name: no such directory, an empty tree, a symbolic link (it would publish whatever it
#                     points at), a tree with no page at all.
#   place <site> <channel> <repo> <version>
#                     copies the site to <channel>/reference/<repo>/<version>/ (replacing that version only), and to
#                     reference/<repo>/latest/ only when <version> is the highest the channel holds (version order, so
#                     0.10.0 is above 0.9.0 and a backport release leaves latest alone); writes the version list
#                     reference/<repo>/index.html and the repository list reference/index.html from the tree, so a
#                     place repeated on a newer channel tip (a lost push race) writes the same bytes. Refused by name:
#                     a repository that is no lower-case name, a version that is no release number.
#   --self-test       one planted tree through assemble and two places: the action runs it before reading a tree.
set -euo pipefail

die() { echo "docs-site: $*" >&2; exit 1; }

page() { # $1 title, then the body on stdin: a deterministic page, no date and no run id
  printf '<!DOCTYPE html>\n<html lang="en">\n<head><meta charset="utf-8"><title>%s</title></head>\n<body>\n<h1>%s</h1>\n' "$1" "$1"
  cat
  printf '</body>\n</html>\n'
}

assemble() {
  local site=${1:-} f title links filter
  [ -n "$site" ] && [ -d "$site" ] || die "assemble: no such directory: '${site}'"
  [ -n "$(find "$site" -mindepth 1 -print -quit)" ] || die "assemble: $site is empty: the docs-site target wrote nothing"
  links=$(find "$site" -type l)
  [ -z "$links" ] || { printf '%s\n' "$links" >&2; die "assemble: a symbolic link would publish what it points at (above)"; }
  filter=$(mktemp --suffix=.lua)
  # a relative link to a .md page, with or without an anchor, points at the page this run renders beside it
  cat > "$filter" <<'LUA'
function Link(el)
  if not el.target:match('^%a[%w+.-]*:') and not el.target:match('^//') then
    local path, anchor = el.target:match('^(.-)%.md(#.*)$')
    if path then el.target = path .. '.html' .. anchor
    else
      path = el.target:match('^(.-)%.md$')
      if path then el.target = path .. '.html' end
    end
  end
  return el
end
LUA
  while IFS= read -r -d '' f; do
    title=$(grep -m1 -E '^# ' "$f" | sed 's/^# *//') || true
    [ -n "$title" ] || title=$(basename "$f" .md)
    pandoc -f gfm -t html5 -s --lua-filter "$filter" --metadata pagetitle="$title" -o "${f%.md}.html" "$f"
  done < <(find "$site" -type f -name '*.md' -print0 | sort -z)
  while IFS= read -r -d '' f; do
    pandoc -f man -t html5 -s --metadata pagetitle="$(basename "$f")" -o "$f.html" "$f"
  done < <(find "$site" -type f -regex '.*\.[1-8]$' -print0 | sort -z)
  rm -f "$filter"
  [ -f "$site/index.html" ] || index "$site" "${2:-$(basename "$site")}"
  echo "docs-site: assembled $(find "$site" -type f -name '*.html' | wc -l) html page(s) in $site"
}

index() { # $1 site, $2 title: the entry page, every page of the tree's top two levels by its own <title>
  local site=$1 title=$2 pages p t
  pages=$( (cd "$site" && find . -mindepth 1 -maxdepth 2 -type f -name '*.html' -printf '%P\n') \
    | while IFS= read -r p; do
        case $p in
          */index.html) echo "$p" ;;
          */*) [ -f "$site/${p%/*}/index.html" ] || echo "$p" ;;
          *) echo "$p" ;;
        esac
      done | LC_ALL=C sort)
  [ -n "$pages" ] || die "assemble: $site has no page to index: the docs-site target wrote no html, Markdown or man page"
  printf '%s\n' "$pages" | while IFS= read -r p; do
      t=$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$site/$p" | head -n 1)
      printf '<li><a href="%s">%s</a></li>\n' "${p%index.html}" "${t:-$p}"
    done | { echo '<ul>'; cat; echo '</ul>'; } | page "$title" > "$site/index.html"
}

place() {
  local site=${1:-} channel=${2:-} repo=${3:-} version=${4:-} ref dest highest d
  [[ "$repo" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "place: '$repo' is no repository name (lower case, digits and -)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~-][0-9A-Za-z.+~-]*)?$ ]] \
    || die "place: '$version' is no release number (x.y.z, then an optional suffix)"
  [ -f "$site/index.html" ] || die "place: $site has no index.html: assemble it first"
  [ -d "$channel" ] || die "place: no channel checkout at '$channel'"
  ref=$channel/reference
  dest=$ref/$repo/$version
  rm -rf "$dest"; mkdir -p "$dest"; cp -a "$site/." "$dest/"
  highest=$(find "$ref/$repo" -mindepth 1 -maxdepth 1 -type d ! -name latest -printf '%f\n' | sort -V | tail -n 1)
  if [ "$highest" = "$version" ]; then
    rm -rf "$ref/$repo/latest"; mkdir -p "$ref/$repo/latest"; cp -a "$site/." "$ref/$repo/latest/"
    echo "docs-site: $repo $version is the highest version: latest/ follows it"
  else
    echo "docs-site: $repo $version is below $highest: latest/ stays at $highest"
  fi
  find "$ref/$repo" -mindepth 1 -maxdepth 1 -type d ! -name latest -printf '%f\n' | sort -V -r \
    | { echo '<ul>'; echo '<li><a href="latest/">latest</a></li>'; while IFS= read -r d; do printf '<li><a href="%s/">%s</a></li>\n' "$d" "$d"; done; echo '</ul>'; } \
    | page "$repo: generated reference" > "$ref/$repo/index.html"
  find "$ref" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort \
    | { echo '<ul>'; while IFS= read -r d; do printf '<li><a href="%s/latest/">%s</a> (<a href="%s/">every version</a>)</li>\n' "$d" "$d" "$d"; done; echo '</ul>'; } \
    | page "OpenMixer: generated reference" > "$ref/index.html"
  echo "docs-site: placed $repo $version at reference/$repo/$version/"
}

self_test() {
  local w; w=$(mktemp -d); trap 'rm -rf "$w"' RETURN
  mkdir -p "$w/site" "$w/channel"
  printf '# T\n\n[p](p.md)\n' > "$w/site/index.md"; printf '# P\n' > "$w/site/p.md"
  assemble "$w/site" >/dev/null
  grep -q 'href="p.html"' "$w/site/index.html" || die "self-test: the .md link was not rewritten"
  place "$w/site" "$w/channel" t 0.10.0 >/dev/null
  printf '<p>old</p>\n' > "$w/site/index.html"
  place "$w/site" "$w/channel" t 0.9.0 >/dev/null
  grep -q 'href="p.html"' "$w/channel/reference/t/latest/index.html" || die "self-test: latest moved to a lower version"
  if (place "$w/site" "$w/channel" t latest) 2>/dev/null; then die "self-test: the version 'latest' was accepted"; fi
  echo "docs-site: self-test passed"
}

case ${1:-} in
  assemble) shift; assemble "$@" ;;
  place) shift; place "$@" ;;
  --self-test) self_test ;;
  *) die "usage: docs-site.sh assemble <site> [title] | place <site> <channel> <repo> <version> | --self-test" ;;
esac
