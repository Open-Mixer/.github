#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# no-local-copies check.sh [ROOT] | --self-test
#
# A FreeMixer repository runs the shared checks from Open-Mixer/.github and keeps no copy of them: no commit message
# checker, no pattern list, no private-refs engine, no SPDX check, no allow list (the engine reads none, and one left
# lying in a tree is refused), and a commit-msg hook that is the shared stub byte for byte: a missing hook is as red as
# a different one. A copy is found by its name and by its content, so a renamed copy is red too. A release workflow
# is judged here as well (release-order.py): no DEB job runs after a failed RPM job.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STUB=$HERE/commit-message-check/commit-msg
SIGNS=(
  'commit-message-check.sh: fail when a commit message'
  'private-refs-check.sh: a public repository'
  '"markers"[[:space:]]*:'
  'spdx-check: every tracked file'
)
NAMES='(^|/)(commit-message-check\.sh|commit-message-patterns\.json|private-refs-check\.sh|private-refs-allow\.txt|spdx-check\.sh|check-spdx\.mjs)$'
CODE='\.(sh|bash|py|mjs|cjs|js|ts|json|pl|rb)$'

check() { # <root>
  local root=$1 bad=0 files f s
  files=$(git -c safe.directory="$root" -C "$root" ls-files) || { echo "no-local-copies: git lists no file" >&2; return 1; }
  [ -n "$files" ] || { echo "no-local-copies: git lists no file" >&2; return 1; }
  while IFS= read -r f; do
    [[ $f =~ $NAMES ]] && { echo "no-local-copies: $f is a copy of a shared check" >&2; bad=1; }
  done <<<"$files"
  # by content: a script or data file, by its extension or a #! first line, is code; a log or a note that quotes one is not
  for s in "${SIGNS[@]}"; do
    while IFS= read -r f; do
      [ -n "$f" ] && [ "$f" != .githooks/commit-msg ] || continue
      if [[ $f =~ $CODE ]] || head -c2 "$root/$f" 2>/dev/null | grep -q '^#!'; then
        echo "no-local-copies: $f carries a shared check ($s)" >&2; bad=1
      fi
    done < <(git -c safe.directory="$root" -C "$root" grep -lIE -e "$s" -- . || true)
  done
  if [ ! -e "$root/.githooks/commit-msg" ]; then
    echo "no-local-copies: .githooks/commit-msg is missing (it is the shared stub, .github/actions/commit-message-check/commit-msg)" >&2; bad=1
  elif ! cmp -s "$root/.githooks/commit-msg" "$STUB"; then
    echo "no-local-copies: .githooks/commit-msg is not the shared stub (.github/actions/commit-message-check/commit-msg)" >&2; bad=1
  fi
  local wf
  wf=$(grep -E '^\.github/workflows/[^/]+\.ya?ml$' <<<"$files" || true)
  if [ -n "$wf" ]; then
    (cd "$root" && xargs python3 "$HERE/no-local-copies/release-order.py" <<<"$wf") || bad=1
  fi
  [ "$bad" = 0 ] || return 1
  echo "no-local-copies: the shared checks run from Open-Mixer/.github, and no copy is kept"
}

if [ "${1:-}" = --self-test ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
  REL_HEAD='name: release
on: {push: {tags: ["v*"]}}
jobs:
  rpm:
    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1
    with: {package-name: x}'
  REL_PLAIN="$REL_HEAD
  deb:
    needs: rpm
    uses: Open-Mixer/.github/.github/workflows/build-deb.yml@openmixer-v1
    with: {package-name: x}"
  REL_GUARDED="$REL_PLAIN
    if: \${{ !cancelled() && needs.rpm.result == 'success' }}"
  REL_CANCELLED="$REL_PLAIN
    if: \${{ !cancelled() }}"
  REL_NONEEDS="$REL_HEAD
  deb:
    uses: Open-Mixer/.github/.github/workflows/build-deb.yml@openmixer-v1
    with: {package-name: x}"
  plant() { # <name> <path> <content>: a clean tree plus one planted file must be red
    rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/.githooks" "$t/r/tools"
    cp "$STUB" "$t/r/.githooks/commit-msg"; echo 'int main(void) { return 0; }' > "$t/r/tools/main.c"
    [ -z "$2" ] || { mkdir -p "$t/r/$(dirname "$2")"; printf '%s\n' "$3" > "$t/r/$2"; }
    git -C "$t/r" add -A
    if [ -z "$2" ]; then
      if check "$t/r" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
    else
      if check "$t/r" >/dev/null 2>&1; then echo "FAIL $1 stays green"; fail=1; else echo "ok   $1"; fi
    fi
  }
  plant "a clean tree with the stub hook is green" "" ""
  plant "a checker copy by name is red" tools/commit-message-check.sh 'echo'
  plant "a pattern list by name is red" tools/commit-message-patterns.json '{}'
  plant "a private-refs engine by name is red" tools/private-refs-check.sh 'echo'
  plant "an allow list is red" tools/private-refs-allow.txt 'Makefile   # reason'
  plant "an SPDX check by name is red" tools/spdx-check.sh 'echo'
  plant "an SPDX check in another language by name is red" tools/check-spdx.mjs 'echo'
  plant "a renamed SPDX check is red by its content" tools/licence.sh "# spdx-check: every tracked file a comment can be written in"
  plant "a renamed checker is red by its content" tools/msg.sh "# commit-message-check.sh: fail when a commit message carries a line"
  plant "a renamed pattern list is red by its content" tools/p.json '{"markers": []}'
  plant "a renamed private-refs engine is red by its content" tools/refs.sh "# private-refs-check.sh: a public repository's files"
  plant "a script with no extension is red by its #! line" tools/check "#!/bin/sh
# commit-message-check.sh: fail when a commit message carries a line"
  plant "a deb job with no needs on the rpm job is red" .github/workflows/release.yml "$REL_NONEEDS"
  plant "a deb job that runs after a cancelled or failed rpm is red" .github/workflows/release.yml "$REL_CANCELLED"
  rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/.githooks" "$t/r/.github/workflows" "$t/r/tools"; echo 'int main(void) { return 0; }' > "$t/r/tools/main.c"
  cp "$STUB" "$t/r/.githooks/commit-msg"; printf '%s\n' "$REL_PLAIN" > "$t/r/.github/workflows/release.yml"; git -C "$t/r" add -A
  if check "$t/r" >/dev/null 2>&1; then echo "ok   a deb job with needs: rpm and no if is green"; else echo "FAIL a deb job with needs: rpm and no if is red"; fail=1; fi
  printf '%s\n' "$REL_GUARDED" > "$t/r/.github/workflows/release.yml"; git -C "$t/r" add -A
  if check "$t/r" >/dev/null 2>&1; then echo "ok   a deb job whose if demands the rpm result is green"; else echo "FAIL a deb job whose if demands the rpm result is red"; fail=1; fi
  rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/tools"; echo 'int main(void) { return 0; }' > "$t/r/tools/main.c"; git -C "$t/r" add -A
  if check "$t/r" >/dev/null 2>&1; then echo "FAIL a tree without the stub hook stays green"; fail=1; else echo "ok   a tree without the stub hook is red"; fi
  rm -rf "$t/r"; git init -q "$t/r"
  if check "$t/r" >/dev/null 2>&1; then echo "FAIL an empty tree stays green"; fail=1; else echo "ok   an empty tree is red"; fi
  rm -rf "$t/r"; mkdir -p "$t/r"
  if check "$t/r" >/dev/null 2>&1; then echo "FAIL a directory git cannot read stays green"; fail=1; else echo "ok   a directory git cannot read is red"; fi
  rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/tools"; echo 'Makefile   # reason' > "$t/r/tools/private-refs-allow.txt"; git -C "$t/r" add -A
  if out=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 check "$t/r" 2>&1); then echo "FAIL a checkout another user owns stays green"; fail=1
  elif grep -q 'private-refs-allow.txt is a copy' <<<"$out"; then echo "ok   a checkout another user owns is read"; else echo "FAIL another user's checkout, red for another reason: $out"; fail=1; fi
  rm -rf "$t/r"; git init -q "$t/r"; mkdir -p "$t/r/logs" "$t/r/.githooks"; cp "$STUB" "$t/r/.githooks/commit-msg"; printf '%s\n' 'commit-message-check.sh: fail when a commit message' > "$t/r/logs/run.jsonl"; git -C "$t/r" add -A
  if check "$t/r" >/dev/null 2>&1; then echo "ok   a log quoting the checker is green"; else echo "FAIL a log quoting the checker is red"; fail=1; fi
  plant "a hook that is not the stub is red" .githooks/commit-msg 'exec tools/commit-message-check.sh --msg-file "$1"'
  # sabotage: with the name and content rules gone, a planted copy passes, so the arms above are what catch it
  sed -e "s|^HERE=.*|HERE=$HERE|" -e "s/^NAMES=.*/NAMES='^\$'/" -e "s/^  '.*'\$/  '^\$NEVER'/" "${BASH_SOURCE[0]}" > "$t/sab.sh"
  rm -rf "$t/s"; git init -q "$t/s"; mkdir -p "$t/s/tools" "$t/s/.githooks"; cp "$STUB" "$t/s/.githooks/commit-msg"; echo '{"markers": []}' > "$t/s/tools/commit-message-patterns.json"; git -C "$t/s" add -A
  if (cd "$HERE/no-local-copies" && bash "$t/sab.sh" "$t/s" >/dev/null 2>&1); then echo "ok   sabotage: without its rules the check passes a copy"; else echo "FAIL sabotage: the rules are not what catches a copy"; fail=1; fi
  sed -e "s|^HERE=.*|HERE=$HERE|" -e 's|^  wf=\$(grep.*|  wf=|' "${BASH_SOURCE[0]}" > "$t/sab2.sh"
  rm -rf "$t/s"; git init -q "$t/s"; mkdir -p "$t/s/.githooks" "$t/s/.github/workflows"; cp "$STUB" "$t/s/.githooks/commit-msg"; printf '%s\n' "$REL_CANCELLED" > "$t/s/.github/workflows/release.yml"; git -C "$t/s" add -A
  if (cd "$HERE/no-local-copies" && bash "$t/sab2.sh" "$t/s" >/dev/null 2>&1); then echo "ok   sabotage: without the release-order rule a deb after a red rpm passes"; else echo "FAIL sabotage: the release-order rule is not what catches it"; fail=1; fi
  exit "$fail"
fi
check "$(cd "${1:-.}" && pwd)"
