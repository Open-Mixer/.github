# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# shellcheck shell=bash
# installs.sh, sourced by render.sh: a CI install line installs only an OpenMixer package that the packaging declares
# (.github#257). plugin-hostd's CI installed python3-plugin-hostd-protocol by hand for a
# test that its %check runs too, while neither the spec nor debian/control named it: CI stayed green and every package
# build's %check went red. So, in every workflow and composite action of the repository, each package a dnf, yum or
# apt-get install line names, when its name is one of the OpenMixer package families (channel-packages.txt, beside this
# file), must be one of:
#   - a row of packaging/deps.txt (its RPM or its Debian name);
#   - a name a spec in packaging/ or debian/control names in a dependency field (BuildRequires, Requires, Recommends,
#     Suggests; Build-Depends, Depends, Pre-Depends, Recommends, Suggests), or a package either of them builds;
#   - a row of packaging/ci-only.txt: `<name> <why a job that no package build runs needs it>`, for a CI-only target
#     (a test %check does not run). A row needs its reason; a row for a name the packaging already declares, or that no
#     install line names, is refused too, so the file never grows stale.
# A local file (./x.rpm, rpms/*.rpm), a name built from a variable or a glob, and a third-party package are not read.
# Each refusal names the file, the line and the package.

INSTALLS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLS_FAMILIES="$INSTALLS_HERE/channel-packages.txt"
CI_ONLY=packaging/ci-only.txt

# install_files <root>: every workflow and composite action of the repository
install_files() { ls "$1"/.github/workflows/*.yml "$1"/.github/workflows/*.yaml "$1"/.github/actions/*/action.yml \
  "$1"/.github/actions/*/action.yaml 2>/dev/null || true; }

# install_names <file>: NR<TAB>name for every package an install line names. A shell line continues on the next when it
# ends in a backslash, a folded YAML scalar (>, >-) on every line it folds; a comment line is not read; quotes and $(...) are one word; a word after `install` is a package
# unless it is an option (and -o, -t, -c and -x take the next word as their value).
install_names() { awk '
  function flush(   i, c, n, w, q, d, t, nt, s, mgr, name) {
    if (logical == "") return
    # split into words, with ; && || | as a separator word, outside quotes and $(...)
    nt = 0; w = ""; q = ""; d = 0; n = length(logical)
    for (i = 1; i <= n; i++) {
      c = substr(logical, i, 1)
      if (q != "") { w = w c; if (c == q) q = ""; continue }
      if (c == "\047" || c == "\"") { q = c; w = w c; continue }
      if (c == "$" && substr(logical, i + 1, 1) == "(") { d++; w = w "$("; i++; continue }
      if (d > 0) { w = w c; if (c == "(") d++; else if (c == ")") d--; continue }
      if (c == "#" && w == "") break
      if (c == " " || c == "\t") { if (w != "") t[++nt] = w; w = ""; continue }
      if (c == ";" || c == "|" || c == "&") { if (w != "") t[++nt] = w; w = ""; t[++nt] = ";"; continue }
      w = w c
    }
    if (w != "") t[++nt] = w
    s = 0
    for (i = 1; i <= nt; i++) {
      w = t[i]
      if (w == ";") { s = 0; continue }
      if (s == 0) { mgr = w; sub(/.*\//, "", mgr); if (mgr ~ /^(dnf5?|yum|apt-get|apt)$/) s = 1; continue }
      if (s == 1) { if (w == "install") s = 2; else if (w ~ /^-[otcx]$/) i++; continue }
      if (w ~ /^-[otcx]$/) { i++; continue }
      if (w ~ /^-/) continue
      gsub(/[\047"]/, "", w)
      if (w ~ /^[$.]/ || w ~ /\//) continue
      name = w; sub(/[ =<>].*/, "", name); sub(/-\$.*/, "", name)
      if (name == "" || name ~ /[$*?\[{]/ || name ~ /\.(rpm|deb)$/) continue
      print start "\t" name
    }
    logical = ""
  }
  # a folded YAML scalar (run: >-) is one logical line: each line at least as indented as its first joins it
  fold {
    if ($0 ~ /^[ \t]*$/) next
    match($0, /^[ \t]*/)
    if (find < 0) find = RLENGTH
    if (RLENGTH >= find) { if (logical == "") start = NR; logical = logical " " $0; next }
    fold = 0
    if (logical ~ /(dnf5?|yum|apt-get|apt)[ \t].*install/) flush(); else logical = ""
  }
  /:[ \t]*>[-+]?[ \t]*$/ { fold = 1; find = -1; logical = ""; next }
  /^[ \t]*#/ { if (logical == "") next }
  {
    line = $0
    if (logical == "") start = NR
    cont = sub(/\\[ \t]*$/, "", line)
    logical = logical " " line
    if (!cont) {
      if (logical ~ /(dnf5?|yum|apt-get|apt)[ \t].*install/) flush(); else logical = ""
    }
  }
  END { if (logical ~ /(dnf5?|yum|apt-get|apt)[ \t].*install/) flush() }' "$1"; }

# is_family <name>: 0 when the name is one of the OpenMixer package families
is_family() { local p
  while read -r p _; do case "$p" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2254 # the families are globs
    case "$1" in $p) return 0 ;; esac
  done < "$INSTALLS_FAMILIES"; return 1; }

# declared_names <root>: every name the packaging declares, one per line
declared_names() {
  local root="$1" f n
  if [ -f "$root/$DEPS" ]; then awk '!/^[ \t]*(#|$)/ { print $1; print $2 }' "$root/$DEPS"; fi
  for f in $(spec_files "$root"); do
    n="$(sed -nE 's/^Name:[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | head -n1)"
    printf '%s\n' "$n"
    sed -nE "s/^%package[[:space:]]+-n[[:space:]]+([^[:space:]]+).*/\1/p; s/^%package[[:space:]]+([^-][^[:space:]]*).*/$n-\1/p" "$f"
    # a dependency field: every word that is a name, %{name} expanded, %{?_isa} and versions dropped
    grep -E '^(Build)?(Requires|Recommends|Suggests)(\([^)]*\))?:' "$f" | sed -E "s/^[^:]*://; s/%\{\??_isa\}//g; s/%\{name\}/$n/g; s/[(),]/ /g" |
      tr ' \t' '\n\n' | grep -E '^[A-Za-z][A-Za-z0-9_.+-]*$' | grep -vxE 'with|without|if|else|unless|or|and' || true
  done
  if [ -f "$root/debian/control" ]; then
    sed -nE 's/^Package:[[:space:]]*([^[:space:]]+).*/\1/p' "$root/debian/control"
    awk '/^#/ { next } /^[ \t]/ { if (inf) print; next }
      { inf = ($0 ~ /^(Build-Depends(-Indep|-Arch)?|Depends|Pre-Depends|Recommends|Suggests):/); if (inf) print }' "$root/debian/control" |
      sed -E 's/^[A-Za-z-]+://; s/\([^)]*\)//g; s/\[[^]]*\]//g; s/<[^>]*>//g' | tr ',|' '\n\n' |
      sed -E 's/^[[:space:]]+//; s/[[:space:]].*//; s/:any$//' | grep -E '^[a-z0-9][a-z0-9.+-]*$' || true
  fi
}

# undeclared_installs <root>: one refusal per line, naming the file, the line and the package; empty when every OpenMixer
# package an install line names is declared. Run as $(undeclared_installs), so a grep that finds nothing is no failure.
undeclared_installs() {
  set +e; set +o pipefail
  local root="$1" f rel ln name decl ci_only used="" r why
  decl="$(declared_names "$root" | sort -u)"
  ci_only=""
  if [ -f "$root/$CI_ONLY" ]; then
    while read -r r why; do
      case "$r" in ''|'#'*) continue ;; esac
      if [ -z "$why" ]; then echo "deps-render: $CI_ONLY: $r: a CI-only package names why a job needs it"; fi
      if grep -qxF "$r" <<<"$decl"; then echo "deps-render: $CI_ONLY: $r: the packaging declares it already: drop the row"; fi
      ci_only="$ci_only $r "
    done < "$root/$CI_ONLY"
  fi
  for f in $(install_files "$root"); do
    rel="${f#"$root"/}"
    while IFS=$'\t' read -r ln name; do
      is_family "$name" || continue
      used="$used $name "
      grep -qxF "$name" <<<"$decl" && continue
      case "$ci_only" in *" $name "*) continue ;; esac
      echo "deps-render: $rel:$ln: $name: an install line installs an OpenMixer package the packaging does not declare: name it in $DEPS (make deps renders the spec and debian/control), or in $CI_ONLY with the reason when no package build runs the job's target"
    done < <(install_names "$f")
  done
  for r in $ci_only; do
    case "$used" in *" $r "*) ;; *) echo "deps-render: $CI_ONLY: $r: no install line names it: drop the row" ;; esac
  done
  return 0
}

# installs_self_test [nodeps]: each undeclared install, planted in each form, must go red by file, line and name, through
# render.sh's own run check; every declared form and every form that is not read must stay green. With nodeps, the tree
# has no deps.txt (the arm runs there too) and its spec and control name the dependency without a floor.
installs_self_test() {
  local S fail=0 out ln nodeps="${1:-}"
  S="$(mktemp -d)"
  # the refusals run check prints for the tree (its own success line is not one)
  # shellcheck disable=SC2069 # the refusals are stderr alone: stdout is dropped after it is swapped onto it
  chk() { run check "$S/i" 2>&1 >/dev/null || true; }
  mki() { rm -rf "$S/i"; mkdir -p "$S/i/packaging" "$S/i/debian" "$S/i/.github/workflows" "$S/i/.github/actions/a"
    printf 'omx-contract-devel  libomx-contract-dev  3.21.0\n' > "$S/i/$DEPS"
    printf 'Name: p\nBuildRequires: omx-contract-devel >= 3.21.0\nBuildRequires: python3-plugin-hostd-protocol\nRequires: %%{name}-contract = %%{version}\nSuggests: mod-host\n%%package contract\nSummary: c\n%%package -n python3-p\nSummary: py\n' > "$S/i/packaging/p.spec"
    printf 'Source: p\nBuild-Depends: debhelper-compat (= 13), libomx-contract-dev (>= 3.21.0~), omx-dsp-contract <!nocheck>,\n libplugin-db-dev [amd64] | plugin-db-dev\n\nPackage: p-tests\nSuggests: omx-panel\n' > "$S/i/debian/control"
    # every form that is declared, local or third-party: green
    cat > "$S/i/.github/workflows/ci.yml" <<'EOF'
jobs:
  t:
    steps:
      # a comment that says: dnf install omx-nothing
      - run: sudo apt-get update && sudo apt-get -o Dpkg::Options::=--force-unsafe-io install -y --no-install-recommends gcc libomx-contract-dev ./debs/omx-x_*.deb
      - run: |
          bounded-install dnf install -y --setopt=retries=10 omx-contract-devel \
            python3-plugin-hostd-protocol p-contract python3-p mod-host
          dnf install -y "omx-contract-devel-$pkg" 'omx-contract-devel >= 3.21' rpms/omx-y-[0-9]*.rpm $(command -v node || echo omx-not-a-package)
          if command -v dnf; then dnf install -y omx-dsp-contract; else apt-get install -y omx-panel plugin-db-dev "libomx-contract-dev=$v"; fi
          pip install omx-not-a-package; dnf builddep -y packaging/p.spec
EOF
    printf 'runs:\n  steps:\n    - run: dnf install -y caps-lv2 p\n' > "$S/i/.github/actions/a/action.yml"
    if [ "$nodeps" = nodeps ]; then rm "$S/i/$DEPS"; sed -i -E 's/ >= 3\.21\.0//; s/ \(>= 3\.21\.0~\)//' "$S/i/packaging/p.spec" "$S/i/debian/control"; fi; }
  # <name> <file> <line appended>: red, naming that file, that line and that package
  plant() { mki; printf '%s\n' "$3" >> "$S/i/$2"; ln="$(wc -l < "$S/i/$2")"
    out="$(chk)"
    if grep -qF "$2:$ln: $1:" <<<"$out"; then echo "installs${nodeps:+ ($nodeps)}: $1 in $2:$ln: red, by name"
    else echo "installs${nodeps:+ ($nodeps)}: $1 in $2:$ln: STAYED GREEN or not by name"; echo "    ${out//$'\n'/$'\n    '}"; fail=1; fi; }
  mki
  out="$(chk)"
  if [ -z "$out" ]; then echo "installs${nodeps:+ ($nodeps)}: every declared, local and third-party form: green"; else echo "installs${nodeps:+ ($nodeps)}: FALSE RED"; echo "$out"; fail=1; fi
  plant plugin-hostd-protocol-langpack-ca .github/workflows/ci.yml '      - run: bounded-install dnf install -y --setopt=retries=10 plugin-hostd-protocol-langpack-ca'
  plant omx-plugins-clap   .github/workflows/ci.yml '      - run: dnf install -y omx-contract-devel omx-plugins-clap'
  plant plugin-qualify     .github/workflows/ci.yml "      - run: dnf install -y 'plugin-qualify >= 0.11.0'"
  plant libomx-clap-dev    .github/workflows/ci.yml '      - run: apt-get -o Dpkg::Options::=--force-unsafe-io install -y libomx-clap-dev'
  plant omx-clap-host      .github/workflows/ci.yml '      - run: if command -v dnf; then dnf install -y omx-clap-host; fi'
  plant mod-host-protocol  .github/actions/a/action.yml '    - run: sudo yum install -y mod-host-protocol'
  # a continued line names the line the command starts on
  mki; printf '      - run: |\n          dnf install -y gcc \\\n            omx-clap-core-devel\n' >> "$S/i/.github/workflows/ci.yml"
  ln=$(( $(wc -l < "$S/i/.github/workflows/ci.yml") - 1 )); out="$(chk)"
  if grep -qF ".github/workflows/ci.yml:$ln: omx-clap-core-devel:" <<<"$out"; then echo "installs${nodeps:+ ($nodeps)}: a continued line: red, by its first line"
  else echo "installs${nodeps:+ ($nodeps)}: a continued line: STAYED GREEN or not by name"; echo "$out"; fail=1; fi
  # a folded scalar (run: >-) is one command: a package on its third line is read, and named by the scalar's first line
  mki; printf '      - run: >-\n          dnf install -y\n          gcc omx-contract-devel\n          plugin-qualification-db-write\n      - run: true\n' >> "$S/i/.github/workflows/ci.yml"
  ln=$(( $(wc -l < "$S/i/.github/workflows/ci.yml") - 3 )); out="$(chk)"
  if grep -qF ".github/workflows/ci.yml:$ln: plugin-qualification-db-write:" <<<"$out" && ! grep -q 'omx-contract-devel' <<<"$out"; then
    echo "installs${nodeps:+ ($nodeps)}: a folded scalar: red, by its first line"
  else echo "installs${nodeps:+ ($nodeps)}: a folded scalar: STAYED GREEN or not by name"; echo "$out"; fail=1; fi
  # packaging/ci-only.txt: a row with its reason makes the install green; a row with no reason, a row the packaging
  # declares already and a row no install line names are red
  mki; printf '      - run: dnf install -y omx-plugins-clap\n' >> "$S/i/.github/workflows/ci.yml"
  printf '# CI-only\nomx-plugins-clap  make test-panel-wire reads a real plugin; %%check does not run it\n' > "$S/i/$CI_ONLY"
  out="$(chk)"
  if [ -z "$out" ]; then echo "installs${nodeps:+ ($nodeps)}: a CI-only row with its reason: green"; else echo "installs${nodeps:+ ($nodeps)}: a CI-only row: FALSE RED"; echo "$out"; fail=1; fi
  cio() { mki; printf '      - run: dnf install -y omx-plugins-clap\n' >> "$S/i/.github/workflows/ci.yml"; printf '%s\n' "$2" > "$S/i/$CI_ONLY"
    out="$(chk)"
    if grep -qF "$3" <<<"$out"; then echo "installs${nodeps:+ ($nodeps)}: ci-only $1: red, by name"; else echo "installs${nodeps:+ ($nodeps)}: ci-only $1: STAYED GREEN"; echo "$out"; fail=1; fi; }
  cio no-reason   'omx-plugins-clap'                                  "$CI_ONLY: omx-plugins-clap: a CI-only package names why"
  cio declared    $'omx-plugins-clap  a test\nmod-host  a test'      "$CI_ONLY: mod-host: the packaging declares it already"
  cio stale       $'omx-plugins-clap  a test\nomx-live  a test'      "$CI_ONLY: omx-live: no install line names it"
  rm -rf "$S"
  return "$fail"
}
