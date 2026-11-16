#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# deps-render.sh: the dependency floors AND CEILINGS of a repository come from ONE file, packaging/deps.txt, and are
# rendered into every place that states one: the RPM spec's Requires and BuildRequires, debian/control's
# Build-Depends and Depends, and the release-tag variables of the workflows.
#
#   render.sh --write [ROOT]      rewrite every floor to what deps.txt says
#   render.sh --check [ROOT]      refuse when any of them says something else (default)
#   render.sh --floor NAME [ROOT] print the floor of the dependency whose RPM name is NAME
#   render.sh --self-test         each drift, planted in each file, must go red
#
# packaging/deps.txt, one dependency per line, blank and # lines ignored:
#   <rpm name>  <deb name>  <floor>  [<ceiling> | -]  [<VARIABLE>]
# VARIABLE names a workflow variable (env: VARIABLE: v<floor>) that pins the release tag of the same
# dependency. A dependency has a floor AND a ceiling (the house rule: below 1.0 the ceiling is the next minor, from 1.0
# the next major): the spec states `<name> >= floor` and `<name> < ceiling`, debian/control `(>= floor~)` and
# `(<< ceiling~)`. A ceiling that is not a version or not above the floor is refused; so is a spec or control file that
# does not state the ceiling or states another one. No exact pin is written.
# A FLOOR-ONLY row (no ceiling, or `-`; Open-Mixer/.github#102) is how a consumer declares one of OUR packages: the
# owner's rule is floors only on our packages, and a breaking release declares its own Breaks/Conflicts. It renders
# `>= floor` and no upper bound: a spec or control file that states a ceiling for it is drift, and --write removes it.
# Third-party rows keep their floor and ceiling as before.
# A versioned requirement in the spec or the control file whose package deps.txt does not list is drift too.
set -euo pipefail

DEPS=packaging/deps.txt

load() { # <root>: fills RPM[] DEB[] FLOOR[] CEIL[] VAR[] from deps.txt
  RPM=(); DEB=(); FLOOR=(); CEIL=(); VAR=()
  local f="$1/$DEPS" r d v c x
  [ -f "$f" ] || { echo "deps-render: $f is missing" >&2; return 1; }
  while read -r r d v c x _; do
    case "$r" in ''|'#'*) continue ;; esac
    # floor-only: no ceiling, `-`, or the 4th field is already the VARIABLE
    if [ "$c" = - ]; then c=""; elif [ -z "$x" ] && [[ "$c" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then x="$c"; c=""; fi
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "deps-render: $DEPS: '$r' has no numeric floor ('$v')" >&2; return 1; }
    [ -n "$d" ] || { echo "deps-render: $DEPS: '$r' has no deb name" >&2; return 1; }
    if [ -n "$c" ]; then
    [[ "$c" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "deps-render: $DEPS: '$r' has no numeric ceiling ('$c')" >&2; return 1; }
    [ "$(printf '%s\n%s\n' "$v" "$c" | sort -V | head -n1)" = "$v" ] && [ "$v" != "$c" ] ||
      { echo "deps-render: $DEPS: the ceiling of '$r' ($c) is not above its floor ($v)" >&2; return 1; }
    fi
    RPM+=("$r"); DEB+=("$d"); FLOOR+=("$v"); CEIL+=("$c"); VAR+=("${x:-}")
  done < "$f"
  [ "${#RPM[@]}" -gt 0 ] || { echo "deps-render: $f lists no dependency" >&2; return 1; }
}

esc() { printf '%s' "$1" | sed 's/[.+*?^$\[\]/\\&/g'; }

# the files of each kind that exist in the tree
spec_files()  { ls "$1"/packaging/*.spec 2>/dev/null || true; }
wf_files()    { ls "$1"/.github/workflows/*.yml 2>/dev/null || true; }

# lines of a spec that state a versioned requirement: "<name> >= <floor>" after Requires: or BuildRequires:
spec_names() { grep -E '^(Build)?Requires:' "$1" | grep -oE '[A-Za-z0-9_.+()-]+ *>= *[0-9][0-9.]*' | sed 's/ *>=.*//' || true; }
ctl_names()  { grep -E '^(Build-Depends|Depends|Pre-Depends):' "$1" | grep -oE '[a-z0-9.+-]+ \(>= [0-9][0-9.]*\)' | sed 's/ .*//' || true; }

run() { # <mode> <root>
  local mode="$1" root="$2" i n bad=0 f e spec ctl
  load "$root" || return 1
  ctl="$root/debian/control"
  for i in "${!RPM[@]}"; do
    n="${RPM[$i]}"
    # spec
    local seen=0
    for f in $(spec_files "$root"); do
      e="$(esc "$n")"
      if grep -qE "^(Build)?Requires:.*[ ,]$e *>= *[0-9]" "$f"; then seen=1
        if [ "$mode" = write ]; then sed -i -E "/^(Build)?Requires:/ s/([ ,]$e *>= *)[0-9][0-9.]*/\1${FLOOR[$i]}/" "$f"
        elif grep -E "^(Build)?Requires:" "$f" | grep -E "[ ,]$e *>= *[0-9]" | grep -qvE "[ ,]$e *>= *${FLOOR[$i]}( |,|\$)"; then
          echo "deps-render: $f states $n at a floor other than ${FLOOR[$i]}" >&2; bad=1; fi
      fi
    done
    [ "$seen" = 1 ] || { echo "deps-render: no spec in packaging/ requires $n >= ${FLOOR[$i]}" >&2; bad=1; }
    # spec ceiling: a `< ceiling` on the same package, at least one, and every one the same; none on a floor-only row
    local cseen=0
    if [ -z "${CEIL[$i]}" ]; then
      for f in $(spec_files "$root"); do
        e="$(esc "$n")"
        if grep -qE "^(Build)?Requires:.*[ ,]$e *< *[0-9]" "$f"; then
          if [ "$mode" = write ]; then
            sed -i -E "/^(Build)?Requires: *$e *< *[0-9][0-9.]* *\$/d; /^(Build)?Requires:/ s/,? *$e *< *[0-9][0-9.]*//" "$f"
          else echo "deps-render: $f states a ceiling for $n, which $DEPS declares floor-only" >&2; bad=1; fi
        fi
      done
    else
    for f in $(spec_files "$root"); do
      e="$(esc "$n")"
      if grep -qE "^(Build)?Requires:.*[ ,]$e *< *[0-9]" "$f"; then cseen=1
        if [ "$mode" = write ]; then sed -i -E "/^(Build)?Requires:/ s/([ ,]$e *< *)[0-9][0-9.]*/\1${CEIL[$i]}/" "$f"
        elif grep -E "^(Build)?Requires:" "$f" | grep -E "[ ,]$e *< *[0-9]" | grep -qvE "[ ,]$e *< *${CEIL[$i]}( |,|\$)"; then
          echo "deps-render: $f states $n below a ceiling other than ${CEIL[$i]}" >&2; bad=1; fi
      fi
    done
    [ "$cseen" = 1 ] || { echo "deps-render: no spec in packaging/ requires $n < ${CEIL[$i]}: a dependency needs a ceiling" >&2; bad=1; }
    fi
    # control
    if [ -f "$ctl" ]; then
      e="$(esc "${DEB[$i]}")"
      if grep -qE "^(Build-Depends|Depends|Pre-Depends):.*$e \(>= [0-9]" "$ctl"; then
        if [ "$mode" = write ]; then sed -i -E "/^(Build-Depends|Depends|Pre-Depends):/ s/($e \(>= )[0-9][0-9.]*/\1${FLOOR[$i]}/g" "$ctl"
        elif grep -E "^(Build-Depends|Depends|Pre-Depends):" "$ctl" | grep -oE "$e \(>= [0-9][0-9.]*~?\)" | sed 's/~//' | grep -qvxF "${DEB[$i]} (>= ${FLOOR[$i]})"; then
          echo "deps-render: debian/control states ${DEB[$i]} at a floor other than ${FLOOR[$i]}" >&2; bad=1; fi
      else echo "deps-render: debian/control has no ${DEB[$i]} (>= ${FLOOR[$i]})" >&2; bad=1; fi
      if [ -z "${CEIL[$i]}" ]; then
        if grep -qE "^(Build-Depends|Depends|Pre-Depends):.*$e \(<< [0-9]" "$ctl"; then
          if [ "$mode" = write ]; then
            sed -i -E "/^(Build-Depends|Depends|Pre-Depends):/ { s/, *$e \(<< [0-9][0-9.]*~?\)//g; s/$e \(<< [0-9][0-9.]*~?\), *//g; }" "$ctl"
          else echo "deps-render: debian/control states a ceiling for ${DEB[$i]}, which $DEPS declares floor-only" >&2; bad=1; fi
        fi
      elif grep -qE "^(Build-Depends|Depends|Pre-Depends):.*$e \(<< [0-9]" "$ctl"; then
        if [ "$mode" = write ]; then sed -i -E "/^(Build-Depends|Depends|Pre-Depends):/ s/($e \(<< )[0-9][0-9.]*/\1${CEIL[$i]}/g" "$ctl"
        elif grep -E "^(Build-Depends|Depends|Pre-Depends):" "$ctl" | grep -oE "$e \(<< [0-9][0-9.]*~?\)" | sed 's/~//' | grep -qvxF "${DEB[$i]} (<< ${CEIL[$i]})"; then
          echo "deps-render: debian/control states ${DEB[$i]} below a ceiling other than ${CEIL[$i]}" >&2; bad=1; fi
      else echo "deps-render: debian/control has no ${DEB[$i]} (<< ${CEIL[$i]}): a dependency needs a ceiling" >&2; bad=1; fi
    else echo "deps-render: $ctl is missing" >&2; bad=1; fi
    # workflow release-tag variable
    if [ -n "${VAR[$i]}" ]; then
      local wseen=0
      for f in $(wf_files "$root"); do
        if grep -qE "^[[:space:]]*${VAR[$i]}: *v[0-9]" "$f"; then wseen=1
          if [ "$mode" = write ]; then sed -i -E "s/^([[:space:]]*${VAR[$i]}: *v)[0-9][0-9.]*/\1${FLOOR[$i]}/" "$f"
          elif grep -E "^[[:space:]]*${VAR[$i]}: *v" "$f" | grep -qvE "v${FLOOR[$i]}[[:space:]]*(#.*)?\$"; then
            echo "deps-render: $f pins ${VAR[$i]} at a tag other than v${FLOOR[$i]}" >&2; bad=1; fi
        fi
      done
      [ "$wseen" = 1 ] || { echo "deps-render: no workflow sets ${VAR[$i]}: v${FLOOR[$i]}" >&2; bad=1; }
    fi
  done
  # a versioned requirement deps.txt does not list
  local names
  for f in $(spec_files "$root"); do
    for n in $(spec_names "$f"); do
      case " ${RPM[*]} " in *" $n "*) ;; *) echo "deps-render: $f requires $n with a floor deps.txt does not list" >&2; bad=1 ;; esac
    done
  done
  if [ -f "$ctl" ]; then
    for n in $(ctl_names "$ctl"); do
      case " ${DEB[*]} " in *" $n "*) ;; *) echo "deps-render: debian/control requires $n with a floor deps.txt does not list" >&2; bad=1 ;; esac
    done
  fi
  [ "$bad" = 0 ] || return 1
  [ "$mode" = check ] && echo "deps-render: spec, debian/control and workflows carry the floors of $DEPS"
  return 0
}

if [ "${1:-}" = --self-test ]; then
  S="$(mktemp -d)"; trap 'rm -rf "$S"' EXIT
  fail=0
  mk() { rm -rf "$S/t"; mkdir -p "$S/t/packaging" "$S/t/debian" "$S/t/.github/workflows"
    printf '# test\nlib-devel  libx-dev  1.2.0  2  LIB_REF\nother      libother 0.4.0  0.5\nown-devel  libown-dev 0.3.0\nownb  libownb  1.4  -  OWNB_REF\nownc  libownc  2.1  OWNC_REF\n' > "$S/t/$DEPS"
    printf 'Name: t\nBuildRequires: gcc\nBuildRequires: lib-devel >= 1.2.0\nBuildRequires: lib-devel < 2\nBuildRequires: other >= 0.4.0\nBuildRequires: other < 0.5\nRequires: lib-devel >= 1.2.0\nRequires: lib-devel < 2\nBuildRequires: own-devel >= 0.3.0\nRequires: ownb >= 1.4\nRequires: ownc >= 2.1\n' > "$S/t/packaging/t.spec"
    printf 'Source: t\nBuild-Depends: debhelper-compat (= 13), libx-dev (>= 1.2.0~), libx-dev (<< 2~), libother (>= 0.4.0~), libother (<< 0.5~), libown-dev (>= 0.3.0~)\n\nPackage: t\nDepends: libx-dev (>= 1.2.0~), libx-dev (<< 2~), libownb (>= 1.4~), libownc (>= 2.1~), ${misc:Depends}\n' > "$S/t/debian/control"
    printf 'env:\n  LIB_REF: v1.2.0\n  OWNB_REF: v1.4\n  OWNC_REF: v2.1\n' > "$S/t/.github/workflows/ci.yml"; }
  # <name> <file> <sed expression that plants the drift>
  sab() { mk; sed -i -E "$3" "$S/t/$2"
    if run check "$S/t" >/dev/null 2>&1; then echo "SABOTAGE $1: STAYED GREEN"; fail=1; else echo "SABOTAGE $1: red"; fi; }
  mk; run check "$S/t" >/dev/null || { echo "self-test: the clean tree is not green" >&2; exit 1; }
  sab spec-requires      packaging/t.spec '/^Requires:/ s/1\.2\.0/0.9.0/'
  sab spec-buildrequires packaging/t.spec '/^BuildRequires: lib/ s/1\.2\.0/1.3.0/'
  sab spec-second-dep    packaging/t.spec '/^BuildRequires: other/ s/0\.4\.0/0.1.0/'
  sab spec-unlisted      packaging/t.spec '$a BuildRequires: extra >= 2.0'
  sab control-build      debian/control   '/^Build-Depends/ s/libx-dev \(>= 1\.2\.0~\)/libx-dev (>= 1.0.0~)/'
  sab control-depends    debian/control   '/^Depends/ s/>= 1\.2\.0/>= 1.1.0/'
  sab control-unlisted   debian/control   '/^Depends/ s/libx-dev \(>=/libz (>= 3.0), libx-dev (>=/'
  sab control-gone       debian/control   's/libother \(>= 0\.4\.0~\), //'
  sab workflow-tag       .github/workflows/ci.yml 's/v1\.2\.0/v1.1.0/'
  sab workflow-gone      .github/workflows/ci.yml 's/LIB_REF/OTHER_REF/'
  sab deps-floor         packaging/deps.txt 's/^lib-devel( +libx-dev +)1\.2\.0/lib-devel\11.5.0/'
  sab deps-no-ceiling    packaging/deps.txt 's/^(other +libother +0\.4\.0) +0\.5/\1/'
  sab deps-ceiling-below-floor packaging/deps.txt 's/^(other +libother +0\.4\.0) +0\.5/\1 0.3/'
  sab deps-ceiling-not-number  packaging/deps.txt 's/^(other +libother +0\.4\.0) +0\.5/\1 next/'
  sab spec-no-ceiling    packaging/t.spec '/^BuildRequires: other < /d'
  sab spec-ceiling-differs packaging/t.spec '/^Requires: lib-devel </ s/2/3/'
  sab control-no-ceiling debian/control   's/, libother \(<< 0\.5~\)//'
  sab control-ceiling-differs debian/control '/^Depends/ s/<< 2~/<< 5~/'
  # a FLOOR-ONLY row (our own packages, .github#102): '>= floor' and no upper bound anywhere
  sab floor-only-floor-drift   packaging/t.spec '/^Requires: ownb/ s/1\.4/1.3/'
  sab floor-only-spec-ceiling  packaging/t.spec '$a Requires: ownb < 2'
  sab floor-only-ctl-ceiling   debian/control   '/^Depends/ s/libownc \(>= 2\.1~\)/libownc (>= 2.1~), libownc (<< 3~)/'
  sab floor-only-ctl-gone      debian/control   's/, libown-dev \(>= 0\.3\.0~\)//'
  sab floor-only-tag           .github/workflows/ci.yml 's/OWNC_REF: v2\.1/OWNC_REF: v2.0/'
  # --write puts every drifted file right, and a second check is green
  mk; sed -i 's/1\.2\.0/0.5.0/' "$S/t/packaging/t.spec" "$S/t/debian/control" "$S/t/.github/workflows/ci.yml"
  printf 'Requires: ownb < 2\n' >> "$S/t/packaging/t.spec"; sed -i 's/libownc (>= 2.1~)/libownc (>= 2.1~), libownc (<< 3~)/' "$S/t/debian/control"
  run write "$S/t" >/dev/null 2>&1 || true
  if run check "$S/t" >/dev/null 2>&1; then echo "WRITE repairs every file: ok"; else echo "WRITE left drift"; fail=1; fi
  [ "$fail" = 0 ] || exit 1
  echo "deps-render self-test: every drift red"
  exit 0
fi

mode=check
case "${1:-}" in
  --write) mode=write; shift ;;
  --check) shift ;;
  --floor) name="${2:?--floor needs a dependency name}"; root="${3:-.}"; load "$(cd "$root" && pwd)"
    for i in "${!RPM[@]}"; do [ "${RPM[$i]}" = "$name" ] && { echo "${FLOOR[$i]}"; exit 0; }; done
    echo "deps-render: $DEPS lists no $name" >&2; exit 1 ;;
esac
run "$mode" "$(cd "${1:-.}" && pwd)"
