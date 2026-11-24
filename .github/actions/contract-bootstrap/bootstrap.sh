#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# bootstrap.sh rpm|deb <entry> <out dir>: ONE -contract data package of a sibling repository, built alone from its source
# at a named commit, the way a stage-box chain line's bootstrap= builds it (Open-Mixer/.github#230). <entry> is
# <owner>/<repo>@<full commit>:<package>.
#
# The source is fetched at that commit and the checkout must BE that commit: a short sha, a branch, a tag, or a sha that
# resolves to another commit (an annotated tag's object) is refused. Its `make install-contract DESTDIR=<root> PREFIX=/usr`
# installs the files; the package is what the sibling's own packaging declares for it:
#   rpm: a `%package -n <package>` of a spec under packaging/ that says BuildArch: noarch. Its Summary, License, Requires,
#        %description, %license and %doc are the subpackage's; every file another %files section claims (a langpack's
#        catalog) is left out. Version: the spec's; Release: 0.git<commit time>.<short sha>%{?dist}, below the sibling's
#        own release of that version, which replaces it. Built with rpmbuild -ba from a tarball of the commit, so the
#        source package is the source.
#   deb: an `Architecture: all` stanza of debian/control. Its Depends (substitution variables dropped), Multi-Arch and
#        Description are the stanza's, Maintainer, Section and Homepage the source stanza's; the files debian/<package>
#        .install names (another package's are left out), the directories its .dirs names, copyright, its .docs, and the
#        changelog as build-deb.sh renders it (render-changelog.sh: the body from git, the snapshot version), all laid out
#        as debhelper lays them: the library's own snapshot build of the package, file for file. Version: debian/changelog's first, <version>~git<commit
#        time>.<short sha>, below the sibling's own <version>, above a consumer's (>= <version>~) floor.
# Both versions are the house snapshot forms (build-deb.sh, build-rpm.sh), so the channel's cells.tsv records the
# upstream version (release-matrix/cells.sh). Prints `BOOTSTRAP <package> ok <file> ...`; anything else is red, exit 1.
# BOOTSTRAP_GIT_BASE replaces https://github.com (a test's local fixtures); BOOTSTRAP_RENDER names render-changelog.sh for
# a copy of this script outside the tree (a test's sabotage).
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
kind=${1:-} entry=${2:-} outdir=${3:-}
red() { echo "BOOTSTRAP ${pkg:-$entry} FAIL $*"; exit 1; }
case $kind in rpm | deb) ;; *) echo "usage: bootstrap.sh rpm|deb <owner>/<repo>@<full commit>:<package> <out dir>" >&2; exit 2 ;; esac
[ -n "$outdir" ] || { echo "bootstrap.sh: no out dir" >&2; exit 2; }
[[ $entry =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40}):([A-Za-z0-9][A-Za-z0-9._+-]*-contract)$ ]] \
  || red "'$entry' is not <owner>/<repo>@<full 40-character commit>:<package>-contract"
repo=${BASH_REMATCH[1]} sha=${BASH_REMATCH[2]} pkg=${BASH_REMATCH[3]}

b=$(mktemp -d); trap 'rm -rf "$b"' EXIT
tree=$b/src
git init -q "$tree"
# deb: the history and the tags, which the changelog's rendering reads (render-changelog.sh, as build-deb.sh's checkout
# with fetch-depth: 0); rpm: the commit alone
how=(--depth 1); [ "$kind" = rpm ] || how=(--tags)
git -C "$tree" fetch -q "${how[@]}" "${BOOTSTRAP_GIT_BASE:-https://github.com}/$repo" "$sha" 2>"$b/fetch.log" \
  || { tail -3 "$b/fetch.log"; red "$repo has no commit $sha"; }
git -C "$tree" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
got=$(git -C "$tree" rev-parse HEAD)
[ "$got" = "$sha" ] || red "the checkout is $got, not $sha: the entry must name the commit itself"
ct=$(git -C "$tree" log -1 --format=%ct HEAD) short=${sha:0:7}

mkdir -p "$b/root" "$outdir"
make -s -C "$tree" install-contract DESTDIR="$b/root" PREFIX=/usr >"$b/make.log" 2>&1 || { tail -5 "$b/make.log"; red "make install-contract"; }
mapfile -t files < <(cd "$b/root" && find . -type f -printf '/%P\n' | sort)
[ ${#files[@]} -gt 0 ] || red "make install-contract installed no file"

# section <file> <first line> <stop regex>: the lines after <first line> up to the next line matching <stop regex>
section() { awk -v p="$2" -v s="$3" '$0 == p {on=1; next} on && $0 ~ s {exit} on' "$1"; }

if [ "$kind" = rpm ]; then
  spec=
  for s in "$tree"/packaging/*.spec; do [ -f "$s" ] && grep -qx "%package -n $pkg" "$s" && { spec=$s; break; }; done
  [ -n "$spec" ] || red "no spec under packaging/ has %package -n $pkg"
  head=$(section "$spec" "%package -n $pkg" '^%(package|description|prep|build|install|files|changelog)')
  grep -qE '^BuildArch:[[:space:]]*noarch[[:space:]]*$' <<< "$head" || red "$pkg is not a noarch data package of ${spec##*/}"
  ver=$(rpmspec -q --srpm --qf '%{version}' "$spec" 2>/dev/null) && [ -n "$ver" ] || red "rpmspec gives no version for ${spec##*/}"
  summary=$(sed -n 's/^Summary:[[:space:]]*//p' <<< "$head" | head -1)
  lic=$(sed -n 's/^License:[[:space:]]*//p' <<< "$head" | head -1)
  [ -n "$lic" ] || lic=$(awk '/^License:/ {sub(/^License:[[:space:]]*/, ""); print; exit}' "$spec")
  [ -n "$summary" ] && [ -n "$lic" ] || red "${spec##*/} gives $pkg no Summary or License"
  desc=$(section "$spec" "%description -n $pkg" '^%(package|description|prep|build|install|files|changelog)' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
  # a file another %files section claims is that package's: every other section's paths, macros expanded, a directory
  # covering what is in it
  mapfile -t others < <(rpmspec -P "$spec" 2>/dev/null | awk -v p="%files -n $pkg" '
    /^%files([[:space:]]|$)/ {on = ($0 != p); next}
    /^%(changelog|package|description|prep|build|install|check|pre|post|preun|postun|posttrans|pretrans)([[:space:]]|$)/ {on = 0}
    on {sub(/^((%(config|attr|verify|lang|caps)\([^)]*\)|%(config|ghost))[[:space:]]+)*/, ""); if ($1 ~ /^\//) print $1}')
  kept=() dropped=()
  for f in "${files[@]}"; do
    mine=1; for o in ${others[@]+"${others[@]}"}; do o=${o%/}; [[ $f == "$o" || $f == "$o"/* ]] && { mine=0; break; }; done
    if [ "$mine" = 1 ]; then kept+=("$f"); else dropped+=("$f"); fi
  done
  [ ${#kept[@]} -gt 0 ] || red "every file make install-contract installed is another package's in ${spec##*/}"
  docs=$(section "$spec" "%files -n $pkg" '^%(files|changelog|package)' | awk '$1 == "%license" || $1 == "%doc"')
  mkdir -p "$b/top/SOURCES" "$b/top/SPECS"
  tarball=$pkg-$short.tar.gz
  git -C "$tree" archive --format=tar.gz --prefix=src/ HEAD > "$b/top/SOURCES/$tarball"
  { printf 'Name: %s\nVersion: %s\nRelease: 0.git%s.%s%%{?dist}\nSummary: %s\nLicense: %s\nURL: https://github.com/%s\nSource0: %s\nBuildArch: noarch\nBuildRequires: make\n' \
      "$pkg" "$ver" "$ct" "$short" "$summary" "$lic" "$repo" "$tarball"
    grep -E '^Requires(\([^)]*\))?:' <<< "$head" || true
    printf '\n%%description\n%s\n\nBuilt alone from %s at %s, ahead of that release, which replaces it.\n' "$desc" "$repo" "$sha"
    printf '\n%%prep\n%%setup -q -n src\n\n%%build\n\n%%install\nmake install-contract DESTDIR=%%{buildroot} PREFIX=/usr\n'
    for f in ${dropped[@]+"${dropped[@]}"}; do printf 'rm -f "%%{buildroot}%s"\n' "$f"; done
    printf '\n%%files\n'
    [ -z "$docs" ] || printf '%s\n' "$docs"
    printf '"%s"\n' "${kept[@]}"; } > "$b/top/SPECS/$pkg.spec"
  rpmbuild -ba --quiet --define "_topdir $b/top" --define '_build_id_links none' "$b/top/SPECS/$pkg.spec" >"$b/rpm.log" 2>&1 \
    || { tail -8 "$b/rpm.log"; red rpmbuild; }
  mapfile -t out < <(find "$b/top/RPMS" "$b/top/SRPMS" -name "$pkg-$ver-*.rpm" | sort)
  [ ${#out[@]} -eq 2 ] || red "rpmbuild wrote ${#out[@]} package(s), not the noarch package and its source"
else
  ctl=$tree/debian/control; [ -f "$ctl" ] || red "no debian/control"
  st=$(awk -v p="Package: $pkg" '$0 == p {on=1} on && /^$/ {exit} on' "$ctl")
  [ -n "$st" ] || red "debian/control has no Package: $pkg"
  grep -qx 'Architecture: all' <<< "$st" || red "$pkg is not an Architecture: all data package of debian/control"
  src=$(awk '/^$/ {exit} 1' "$ctl")
  field() { awk -v f="$2:" '$1 == f {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' <<< "$1"; }
  ver=$(sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "$tree/debian/changelog" 2>/dev/null) && [ -n "$ver" ] || red "debian/changelog gives no version"
  ver=${ver%-*}~git$ct.$short
  maint=$(field "$src" Maintainer); [ -n "$maint" ] || red "debian/control's source stanza has no Maintainer"
  # Depends with the substitution variables dropped (${misc:Depends} is debhelper's, empty for a data package)
  # shellcheck disable=SC2016 # a literal ${...}, matched, never expanded
  deps=$(awk '$1 == "Depends:" {on=1; sub(/^Depends:[[:space:]]*/, ""); print; next} on && /^[[:space:]]/ {print; next} {on=0}' <<< "$st" \
    | tr '\n' ' ' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | { grep -v -e '^\${[^}]*}$' -e '^$' || true; } | paste -sd, | sed 's/,/, /g')
  desc=$(awk '$1 == "Description:" {on=1} on' <<< "$st")
  # debian/<package>.install names what dh_install puts in the package: every other file the install made is another
  # package's (a language pack's catalog), as the spec's other %files sections say on the rpm side. With no .install, a
  # source of one binary package installs everything into it; a source of several puts none of debian/tmp in it.
  if [ -f "$tree/debian/$pkg.install" ]; then
    mapfile -t mine < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$tree/debian/$pkg.install" | awk '{print "/" $1}' | sed 's#^//*#/#')
    n=0
    for f in "${files[@]}"; do
      keep=0
      for m in "${mine[@]}"; do
        m=${m%/}
        # shellcheck disable=SC2053 # a line of the .install file is a path or a glob: matched as a pattern on purpose
        [[ $f == $m || $f == "$m"/* ]] && { keep=1; break; }
      done
      if [ "$keep" = 1 ]; then n=$((n + 1)); else rm -f "$b/root$f"; fi
    done
    find "$b/root" -mindepth 1 -type d -empty -delete
    [ "$n" -gt 0 ] || red "debian/$pkg.install names none of the files make install-contract installed"
  elif [ "$(grep -c '^Package:' "$ctl")" -gt 1 ]; then
    red "debian/control has several packages and no debian/$pkg.install: dh_install would put none of install-contract's files in $pkg"
  fi
  # debian/<package>.dirs: the directories dh_installdirs makes in it, kept when empty (the language packs' directory)
  [ ! -f "$tree/debian/$pkg.dirs" ] || grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$tree/debian/$pkg.dirs" | while read -r dir _; do mkdir -p "$b/root/${dir#/}"; done   # DIRS
  dd=$b/root/usr/share/doc/$pkg; mkdir -p "$dd"
  cpr=$tree/debian/$pkg.copyright; [ -f "$cpr" ] || cpr=$tree/debian/copyright
  [ ! -f "$cpr" ] || install -m 644 "$cpr" "$dd/copyright"
  if [ -f "$tree/debian/$pkg.docs" ]; then
    while read -r doc; do [ -n "$doc" ] || continue
      [ -f "$tree/$doc" ] || red "debian/$pkg.docs names $doc, not in the tree"
      install -m 644 "$tree/$doc" "$dd/${doc##*/}"
    done < <(grep -v '^[[:space:]]*#' "$tree/debian/$pkg.docs")
  fi
  cl=changelog.Debian; grep -qx '3.0 (native)' "$tree/debian/source/format" 2>/dev/null && cl=changelog
  # the changelog as the library's own snapshot build carries it: build-deb.sh's rendering (render-changelog.sh), at the
  # house snapshot separator, then laid out as dh_installchangelogs and dh_compress do
  "${BOOTSTRAP_RENDER:-$here/../build-deb/render-changelog.sh}" -C "$tree" -s '~git' >"$b/render.log" 2>&1 || { tail -3 "$b/render.log"; red "render-changelog.sh"; }   # RENDER
  install -m 644 "$tree/debian/changelog" "$dd/$cl"
  find "$dd" -type f ! -name copyright -size +4096c -exec gzip -9n {} \;
  [ -f "$dd/$cl.gz" ] || gzip -9n "$dd/$cl"
  mkdir -p "$b/root/DEBIAN"
  { printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: %s\n' "$pkg" "$ver" "$maint"
    for f in Section Priority Homepage; do v=$(field "$src" "$f"); [ -z "$v" ] || printf '%s: %s\n' "$f" "$v"; done
    v=$(field "$st" Multi-Arch); [ -z "$v" ] || printf 'Multi-Arch: %s\n' "$v"
    [ -z "$deps" ] || printf 'Depends: %s\n' "$deps"
    printf '%s\n' "$desc"; } > "$b/root/DEBIAN/control"
  out=("$b/${pkg}_${ver}_all.deb")
  dpkg-deb --root-owner-group -Zxz --build "$b/root" "${out[0]}" >"$b/deb.log" 2>&1 || { tail -5 "$b/deb.log"; red dpkg-deb; }
fi
cp "${out[@]}" "$outdir/"
echo "BOOTSTRAP $pkg ok $(for f in "${out[@]}"; do printf '%s ' "${f##*/}"; done)from $repo $sha"
