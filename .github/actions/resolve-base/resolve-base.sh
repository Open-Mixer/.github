#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# resolve-base resolve-base.sh <base> [--no-merge-base] [--local-authority] | --self-test
#
# The one base-resolution rule of every compare gate (a baseline that only shrinks, a debt that only falls, a count
# held to the base branch): a gate never resolves its base itself, it asks this script, so every gate refuses the
# same bases by the same names. The rule, from the five ways a gate read a wrong base in one day:
#
#   - a remote-tracking base (origin/main, however spelled: refs/remotes/origin/main, remotes/origin/main, @{u} or
#     <branch>@{upstream}, each normalised to <remote>/<branch> first) is a COPY from the last fetch, and a stale copy
#     can already hold the rows a change grows: the base is fetched first (+refs/heads/<branch>:refs/remotes/<remote>/
#     <branch>, --no-tags), and a fetch that fails is refused by name, never the stale ref left behind;
#   - a remote that is this repository itself (its URL ., .., or a path or file:// URL whose git directory is ours) or
#     any plain local path is no remote: a fetch from it refreshes the copy from a local branch that is itself stale;
#   - an empty base (a CI expression that yielded nothing), a base with no name at all, and a remote with no branch
#     (origin/) are refused by name, never a default and never a skipped compare;
#   - HEAD is no base, and neither is a ref that resolves to HEAD's own commit: a compare of HEAD with HEAD finds nothing;
#   - a plain local branch (main, not origin/main) is a copy too (.github#121): one with an upstream is held to it (the
#     upstream is fetched, and a local branch lacking any commit of it is refused by name); one with no upstream, or a
#     local one (.), is refused by name unless the caller says it is the authority: --local-authority, or
#     RESOLVE_BASE_LOCAL_AUTHORITY=1 (a fixture, a release branch built locally);
#   - the base resolves with git rev-parse -q --verify <base>^{commit}: a name this clone does not hold (a depth-1
#     single-branch clone) is refused by name;
#   - the merge-base with HEAD is where a gate reads the base's copy of a file (what this change started from, never
#     what the base branch did since); a merge-base git cannot find (shallow history) is refused by name, and the fix
#     is named: fetch-depth 0.
#
# On success stdout carries one key=value line each for base, commit and merge-base (the same lines are appended to
# $GITHUB_OUTPUT when it is set); everything else goes to stderr. Exit 0 resolved; 1 the base the caller gave is wrong
# (empty, missing, HEAD, a remote with no branch, HEAD's own commit): a finding in the caller's workflow; 2 the
# checkout cannot give it (the fetch failed, the name does not resolve, no merge-base): never a pass.
set -euo pipefail

refuse() { # <exit> <message>
  echo "resolve-base: $2" >&2
  exit "$1"
}

resolve() { # <base> [--no-merge-base] [--local-authority]
  local base=${1-} want_merge_base=1 local_authority=${RESOLVE_BASE_LOCAL_AUTHORITY:-0} remote branch err commit head merge_base opt
  [ $# -ge 1 ] || refuse 1 "no base given: name the base branch (origin/main), never a default"
  for opt in "${@:2}"; do
    case $opt in
      --no-merge-base) want_merge_base=0 ;;
      --local-authority) local_authority=1 ;;
      *) refuse 1 "unknown option $opt" ;;
    esac
  done
  [ -n "$base" ] || refuse 1 "the base is empty: name the base branch (origin/main), never a default and never a skipped compare"
  case $base in
    HEAD | HEAD[~^]* | @ | @[~^]*) refuse 1 "$base is no base: a compare of HEAD with HEAD finds nothing" ;;
  esac
  # every spelling of a remote-tracking ref reads as <remote>/<branch>, so the fetch rule sees it
  local given=$base full
  case $base in
    @\{u\} | @\{upstream\} | *@\{u\} | *@\{upstream\})
      full=$(git rev-parse -q --symbolic-full-name "$base" 2>/dev/null) || refuse 1 "$base names no upstream: name the base branch (origin/main)"
      case $full in refs/remotes/*) base=${full#refs/remotes/} ;; *) refuse 1 "$base is $full, no remote-tracking ref: name the base branch (origin/main)" ;; esac ;;
    refs/remotes/*) base=${base#refs/remotes/} ;;
    remotes/*) base=${base#remotes/} ;;
  esac
  [ "$given" = "$base" ] || echo "resolve-base: $given read as $base" >&2
  remote=${base%%/*}
  if [ "$remote" != "$base" ] && git remote | grep -qx -- "$remote"; then
    branch=${base#*/}
    [ -n "$branch" ] || refuse 1 "$base names the remote $remote with no branch: name the base branch"
    local url ours theirs
    url=$(git remote get-url -- "$remote")
    case $url in
      . | ..) refuse 1 "the remote $remote is $url, this repository itself: a fetch from it refreshes $base from a local branch, which may itself be stale" ;;
      file://*) theirs=${url#file://} ;;
      *://* | *@*:* | *:*) theirs= ;;
      *) refuse 1 "the remote $remote is the local path $url, no remote: a fetch from it refreshes $base from a local branch, which may itself be stale" ;;
    esac
    if [ -n "$theirs" ]; then
      ours=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
      theirs=$(cd "$theirs" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null | { read -r d; cd "$d" 2>/dev/null && pwd -P; }) || theirs=
      [ "$ours" != "$theirs" ] || refuse 1 "the remote $remote ($url) is this repository itself: a fetch from it refreshes $base from a local branch, which may itself be stale"
    fi
    # the fetch is the rule: a remote-tracking ref is a copy from the last fetch, and a stale copy is no base
    if ! err=$(git fetch -q --no-tags -- "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>&1); then
      refuse 2 "could not fetch $base from $remote (${err%%$'\n'*}): a stale remote-tracking ref is no base"
    fi
  fi
  if ! commit=$(git rev-parse -q --verify "$base^{commit}"); then
    if [ "$remote" != "$base" ]; then
      refuse 2 "$base does not resolve in this clone, and $remote is no remote of it: check the clone out with its remote and fetch-depth 0"
    fi
    refuse 2 "$base does not resolve in this clone: fetch it (actions/checkout with fetch-depth: 0)"
  fi
  head=$(git rev-parse -q --verify "HEAD^{commit}") || refuse 2 "HEAD does not resolve: not a checkout"
  [ "$commit" != "$head" ] || refuse 1 "$base resolves to HEAD's own commit ${commit:0:12}: a compare of HEAD with HEAD finds nothing"
  # the local rule: a plain local branch is held to its upstream, or the caller is its authority
  if git show-ref -q --verify "refs/heads/$base"; then
    local up_remote up_merge up_ref behind
    up_remote=$(git config "branch.$base.remote" || true); up_merge=$(git config "branch.$base.merge" || true)
    if [ -n "$up_remote" ] && [ "$up_remote" != . ] && [ -n "$up_merge" ]; then
      up_ref=refs/remotes/$up_remote/${up_merge#refs/heads/}
      if ! err=$(git fetch -q --no-tags -- "$up_remote" "+$up_merge:$up_ref" 2>&1); then
        refuse 2 "could not fetch $base's upstream ${up_ref#refs/remotes/} from $up_remote (${err%%$'\n'*}): a local branch not held to its upstream is no base"
      fi
      behind=$(git rev-list --count "$commit..$up_ref")
      [ "$behind" = 0 ] || refuse 1 "$base is behind its upstream ${up_ref#refs/remotes/} by $behind commit$([ "$behind" = 1 ] || echo s): name ${up_ref#refs/remotes/} as the base"
    elif [ "$local_authority" != 1 ]; then
      refuse 1 "$base is a local branch with no upstream: name the remote base (origin/main), or pass --local-authority when this branch is the authority"
    fi
  fi
  # end of the local rule
  if [ "$want_merge_base" = 1 ]; then
    if ! merge_base=$(git merge-base HEAD "$commit" 2>/dev/null); then
      refuse 2 "no merge-base between HEAD and $base (${commit:0:12}): shallow history, fetch with fetch-depth 0"
    fi
  fi
  {
    echo "base=$base"
    echo "commit=$commit"
    [ "$want_merge_base" = 0 ] || echo "merge-base=$merge_base"
  } | tee -a "${GITHUB_OUTPUT:-/dev/null}"
}

self_test() {
  local fail=0 script up a b c
  script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null
  ok() { echo "ok   $1"; }
  no() { echo "FAIL $1"; fail=1; }
  commit() { echo "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$2"; git -C "$1" rev-parse HEAD; }
  # the upstream: main is A then B; topic branches at A with T1
  up=$t/up; git init -q -b main "$up"
  a=$(commit "$up" A); b=$(commit "$up" B)
  git -C "$up" checkout -q -b topic "$a"; commit "$up" T1 > /dev/null; git -C "$up" checkout -q main
  # run <dir> <args...>: the script in <dir>, stdout to $t/out, stderr to $t/err, status in $?
  run() { local d=$1; shift; (cd "$d" && bash "$script" "$@") > "$t/out" 2> "$t/err"; }
  # resolved <what> <dir> <commit> <merge-base> <args...>
  resolved() {
    local what=$1 d=$2 want_commit=$3 want_mb=$4; shift 4
    if run "$d" "$@" && grep -qx "commit=$want_commit" "$t/out" && grep -qx "merge-base=$want_mb" "$t/out"; then ok "$what"; else no "$what"; cat "$t/out" "$t/err"; fi
  }
  # refused <what> <dir> <exit> <text> <args...>: the status, the text on stderr, and no commit= on stdout
  refused() {
    local what=$1 d=$2 want=$3 text=$4 got=0; shift 4
    run "$d" "$@" || got=$?
    if [ "$got" = "$want" ] && grep -q -- "$text" "$t/err" && ! grep -q '^commit=' "$t/out"; then ok "$what"; else no "$what (exit $got)"; cat "$t/out" "$t/err"; fi
  }

  local full=$t/full
  git clone -q "file://$up" "$full"; git -C "$full" checkout -q topic
  resolved "a local branch base resolves to its commit and the merge-base with HEAD" "$full" "$b" "$a" main
  resolved "a remote base resolves, read as origin/main" "$full" "$b" "$a" origin/main
  resolved "a sha is a base" "$full" "$b" "$a" "$b"
  if run "$full" "$b" --no-merge-base && grep -qx "commit=$b" "$t/out" && ! grep -q '^merge-base=' "$t/out"; then ok "--no-merge-base gives the commit and no merge-base"; else no "--no-merge-base"; fi
  : > "$t/gh"; (cd "$full" && GITHUB_OUTPUT=$t/gh bash "$script" main) > /dev/null 2>&1
  if grep -qx "commit=$b" "$t/gh" && grep -qx "merge-base=$a" "$t/gh"; then ok "the lines land in GITHUB_OUTPUT when it is set"; else no "GITHUB_OUTPUT"; fi

  # the upstream moves on: the clone's origin/main is a stale copy
  c=$(commit "$up" C)
  [ "$(git -C "$full" rev-parse origin/main)" = "$b" ] || no "the fixture: origin/main in the clone is stale"
  resolved "a stale origin/main is fetched first: the upstream's commit, never the copy" "$full" "$c" "$a" origin/main
  if [ "$(git -C "$full" rev-parse origin/main)" = "$c" ]; then ok "the remote-tracking ref is the upstream's after the fetch"; else no "the remote-tracking ref after the fetch"; fi
  # a local branch is a copy too (.github#121): held to its upstream, or the caller says it is the authority
  git -C "$full" update-ref refs/remotes/origin/main "$b"
  refused "a local main behind its upstream is refused by name, after the upstream is fetched" "$full" 1 "main is behind its upstream origin/main by 1 commit" main
  git -C "$full" branch -q -f main "$c"
  resolved "a local main at its upstream resolves" "$full" "$c" "$a" main
  git -C "$full" branch -q -f main "$b"
  git -C "$full" remote set-url origin "file://$t/gone"
  refused "a local main whose upstream cannot be fetched is refused by name" "$full" 2 "could not fetch main's upstream origin/main" main
  git -C "$full" remote set-url origin "file://$up"
  git -C "$full" branch -q lonely "$b"
  refused "a local branch with no upstream is refused by name" "$full" 1 "lonely is a local branch with no upstream" lonely
  resolved "the same branch, the caller its authority (--local-authority), resolves" "$full" "$b" "$a" lonely --local-authority
  if (cd "$full" && RESOLVE_BASE_LOCAL_AUTHORITY=1 bash "$script" lonely) 2>/dev/null | grep -qx "commit=$b"; then ok "RESOLVE_BASE_LOCAL_AUTHORITY=1 is the same authority"; else no "RESOLVE_BASE_LOCAL_AUTHORITY"; fi
  git -C "$full" branch -q -f main "$c"
  git -C "$full" update-ref refs/remotes/origin/main "$b"
  git -C "$full" remote set-url origin "file://$t/gone"
  refused "a stale origin/main whose remote cannot be reached is refused by name, never read" "$full" 2 "could not fetch origin/main from origin" origin/main
  git -C "$full" remote set-url origin "file://$up"
  refused "a branch the upstream does not hold is refused by name" "$full" 2 "could not fetch origin/no-such from origin" origin/no-such
  # every spelling of the stale remote-tracking ref reaches the fetch rule
  git -C "$full" update-ref refs/remotes/origin/main "$b"; git -C "$full" remote set-url origin "file://$t/gone"
  refused "refs/remotes/origin/main is the same stale ref: refused by name" "$full" 2 "could not fetch origin/main from origin" refs/remotes/origin/main
  refused "remotes/origin/main is the same stale ref: refused by name" "$full" 2 "could not fetch origin/main from origin" remotes/origin/main
  git -C "$full" branch -q --set-upstream-to=origin/main topic
  refused "@{u} is the same stale ref: refused by name" "$full" 2 "could not fetch origin/main from origin" '@{u}'
  refused "topic@{upstream} is the same stale ref: refused by name" "$full" 2 "could not fetch origin/main from origin" 'topic@{upstream}'
  git -C "$full" branch -q --unset-upstream topic
  refused "@{u} with no upstream is refused by name" "$full" 1 "@{u} names no upstream" '@{u}'
  git -C "$full" remote set-url origin "file://$up"
  resolved "refs/remotes/origin/main reachable resolves like origin/main" "$full" "$c" "$a" refs/remotes/origin/main
  # a remote that is this repository: a fetch from it refreshes the copy from a stale local branch
  git -C "$full" branch -q -f main "$b"
  git -C "$full" remote add self .; git -C "$full" update-ref refs/remotes/self/main "$b"
  refused "a remote of . (this repository) is refused by name, never fetched from a stale local branch" "$full" 1 "the remote self is ., this repository itself" self/main
  git -C "$full" remote set-url self "file://$full"
  refused "a file:// remote that is this repository is refused by name" "$full" 1 "is this repository itself" self/main
  git -C "$full" remote set-url self "$up"
  refused "a plain local path as a remote is refused by name" "$full" 1 "is the local path $up, no remote" self/main
  git -C "$full" remote remove self

  refused "an empty base is refused by name, never a default" "$full" 1 "the base is empty" ''
  refused "no base at all is refused" "$full" 1 "no base given"
  refused "HEAD is no base" "$full" 1 "HEAD is no base" HEAD
  refused "HEAD~1 is no base" "$full" 1 "HEAD~1 is no base" HEAD~1
  refused "a remote with no branch (origin/) is refused by name" "$full" 1 "origin/ names the remote origin with no branch" origin/
  refused "a ref that resolves to HEAD's own commit is refused: never HEAD against HEAD" "$full" 1 "topic resolves to HEAD's own commit" topic
  refused "a name this clone does not hold is refused by name" "$full" 2 "no-such-base does not resolve in this clone" no-such-base

  # a depth-1 single-branch clone: the shape of a CI checkout
  local thin=$t/thin
  git clone -q --depth 1 --single-branch -b topic "file://$up" "$thin"
  refused "a depth-1 single-branch clone: a base it never fetched is refused by name" "$thin" 2 "main does not resolve in this clone" main
  git -C "$thin" remote set-url origin "file://$t/gone"
  refused "the same clone with its remote gone: origin/main is refused, naming the fetch" "$thin" 2 "could not fetch origin/main from origin" origin/main
  git -C "$thin" remote remove origin
  refused "the same clone with no remote: origin/main is refused, naming the missing remote" "$thin" 2 "origin is no remote of it" origin/main
  # shallow history on both sides: the base resolves, the merge-base does not exist in the clone
  git -C "$thin" remote add origin "file://$up"
  git -C "$thin" fetch -q --depth 1 --no-tags origin "+refs/heads/main:refs/heads/shallow-main"
  refused "a base that resolves in shallow history with no merge-base is refused, naming fetch-depth 0" "$thin" 2 "no merge-base between HEAD and shallow-main" shallow-main --local-authority
  if run "$thin" shallow-main --no-merge-base --local-authority && grep -qx "commit=$c" "$t/out"; then ok "the same base without a merge-base asked resolves"; else no "shallow base without merge-base"; fi

  # sabotage: with the fetch gone, the stale copy is read (the fetch is what catches it); with the HEAD guard gone,
  # HEAD against HEAD passes
  git -C "$full" update-ref refs/remotes/origin/main "$b"
  sed '/^resolve()/,/^}/{/# the fetch is the rule/,+3d}' "$script" > "$t/nofetch.sh"
  if (cd "$full" && bash "$t/nofetch.sh" origin/main 2>/dev/null | grep -qx "commit=$b"); then ok "sabotage: without the fetch the stale copy is read, so the fetch is what catches it"; else no "sabotage: the fetch"; fi
  # shellcheck disable=SC2016 # the script's own text is matched
  sed '/^resolve()/,/^}/s/\[ "$commit" != "$head" \] ||/true ||/' "$script" > "$t/noguard.sh"
  if (cd "$full" && bash "$t/noguard.sh" topic --local-authority 2>/dev/null | grep -q '^commit='); then ok "sabotage: without the guard HEAD against HEAD passes, so the guard is what catches it"; else no "sabotage: the HEAD guard"; fi

  # sabotage: with the local rule gone, a local main behind its upstream is read as it is
  git -C "$full" branch -q -f main "$b"
  sed '/^resolve()/,/^}/{/# the local rule/,/# end of the local rule/d}' "$script" > "$t/nolocal.sh"
  if (cd "$full" && bash "$t/nolocal.sh" main 2>/dev/null | grep -qx "commit=$b"); then ok "sabotage: without the local rule a stale local main is read, so the rule is what catches it"; else no "sabotage: the local rule"; fi

  [ "$fail" = 0 ] && echo "resolve-base self-test: every arm as wanted"
  return "$fail"
}

if [ "${1:-}" = --self-test ]; then self_test; exit $?; fi
resolve "$@"
