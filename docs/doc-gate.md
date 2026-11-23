<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas -->
# The shared documentation gate, and the base every compare gate resolves

Two helpers every repository's gate calls instead of carrying its own copy: `resolve-base`, the one rule for
resolving the base a compare gate holds a change to, and `doc-gate`, the documentation gate of a C repository and the
Python beside it. Both are composite actions under `.github/actions/`, each a script with a `--self-test` that proves
every arm on throwaway trees, red first, before the action reads a tree; `doc-gate.yml` is the reusable workflow a
repository calls with one `uses:` line.

## resolve-base

A compare gate (a baseline that only shrinks, a debt that only falls, a count held to the base branch) reads its base
through `resolve-base.sh <base>`, never by its own `rev-parse`. The rule, from the five ways a gate read a wrong base
in one day:

- a remote-tracking base (`origin/main`, however spelled: `refs/remotes/origin/main`, `remotes/origin/main`, `@{u}`,
  `<branch>@{upstream}`, each read as `<remote>/<branch>` first) is a copy from the last fetch, and a stale copy can
  already hold the rows a change grows: the base is fetched first (`+refs/heads/<branch>:refs/remotes/<remote>/<branch>`, `--no-tags`), and a
  fetch that fails is refused by name, never the stale ref left behind;
- an empty base, no base, and a remote with no branch (`origin/`) are refused by name, never a default and never a
  skipped compare;
- `HEAD` is no base, and neither is a ref at HEAD's own commit: a compare of HEAD with HEAD finds nothing;
- a plain local branch (`main`, not `origin/main`) is a copy too: one with an upstream is held to it (the upstream is
  fetched, and a branch that lacks any of its commits is refused by name, with the count); one with no upstream, or a
  local one, is refused by name unless the caller names it the authority (`--local-authority`, the action's
  `local-authority: true`, or `RESOLVE_BASE_LOCAL_AUTHORITY=1`: a fixture, a release branch built locally);
- a remote that is this repository itself (its URL `.`, `..`, or a path or `file://` URL whose git directory is ours)
  or any plain local path is no remote: a fetch from it refreshes the copy from a local branch that is itself stale;
- the base resolves with `git rev-parse -q --verify <base>^{commit}`; a name the clone does not hold (a depth-1
  single-branch checkout) is refused by name;
- the merge-base with HEAD is where a gate reads the base's files (what the change started from, never what the base
  branch did since); a merge-base git cannot find (shallow history) is refused, naming `fetch-depth: 0`.

Stdout carries `base=`, `commit=` and `merge-base=` lines (appended to `$GITHUB_OUTPUT` too); exit 1 is a base the
workflow got wrong, 2 a checkout that cannot give it, never a pass. The action:

    - id: base
      uses: Open-Mixer/.github/.github/actions/resolve-base@openmixer-v1
      with:
        base: origin/${{ github.base_ref }}
    - run: git show "${{ steps.base.outputs.merge-base }}:recipes/debt.json"

| Arm | Wanted |
|---|---|
| a local branch at its upstream, `origin/main`, a sha | `commit=` the base's commit, `merge-base=` the fork point |
| a local branch behind its upstream; its upstream unreachable | exit 1 `main is behind its upstream origin/main by 1 commit`; exit 2 `could not fetch main's upstream` |
| a local branch with no upstream; the same with `--local-authority` | exit 1 `lonely is a local branch with no upstream`; resolves |
| `origin/main` stale, the upstream moved on | the upstream's commit, the remote-tracking ref refreshed |
| `origin/main` stale, the remote unreachable | exit 2, `could not fetch origin/main from origin`, no `commit=` |
| the same spelled `refs/remotes/origin/main`, `remotes/origin/main`, `@{u}`, `topic@{upstream}` | the same refusal; `@{u}` with no upstream exit 1 |
| a remote of `.`, a `file://` URL of this repository, a plain local path | exit 1, each by name, never fetched |
| a branch the upstream does not hold | exit 2, by name |
| `''`, no argument | exit 1, `the base is empty`, `no base given` |
| `HEAD`, `HEAD~1`, a ref at HEAD's commit | exit 1, `is no base`, `resolves to HEAD's own commit` |
| `origin/` | exit 1, `names the remote origin with no branch` |
| a depth-1 single-branch clone: `main` | exit 2, `does not resolve in this clone` |
| the same with its remote gone, or no remote | exit 2, naming the fetch, naming the missing remote |
| shallow history on both sides | exit 2, `no merge-base`, naming `fetch-depth 0` |
| sabotage: the fetch removed | the stale copy is read: the fetch is what catches it |
| sabotage: the HEAD guard removed | HEAD against HEAD passes: the guard is what catches it |

## doc-gate

The gate is doxygen itself: the repository's Doxyfile over its tracked headers, `WARN_IF_UNDOCUMENTED` and
`WARN_NO_PARAMDOC` on, its warnings written to a log the gate owns and read as rows `file: text` (the line number
dropped, so a declaration that moves keeps its row; continuation lines joined, so a row names the parameters it
lists). The rows are compared with the baseline **as a set**: a row the baseline does not carry is red by name
(document the declaration, never extend the baseline), a baseline row nothing warns is red by name (strike it in the
same change), a baseline not sorted and unique (`LC_ALL=C sort -u`) is red. `--update` rewrites the baseline from the
tree only when that lowers it, and refuses by name otherwise. `--list` prints the tree's rows.

A repository keeps only its data, and names it:

    jobs:
      docs:
        uses: Open-Mixer/.github/.github/workflows/doc-gate.yml@openmixer-v1
        with:
          doxyfile: tools/Doxyfile             # default Doxyfile
          baseline: tools/doxygen.baseline     # default docs/doxygen-baseline.txt
          pin: tools/doxygen.version           # default docs/doxygen-version.txt
          py: clients/python tests/lib         # the Python half; none without
          ruff-config: ruff.toml               # default
          ruff-version: 0.17.5                 # default; installed and checked, another ruff refused naming both

What doxygen says is trusted only when it provably read every header, so the gate refuses by name, before the
compare (exit 2, it cannot run): a doxygen of another version than the pin (other versions give other rows); a
missing Doxyfile, baseline or pin; a run from anywhere but the repository root; a warning log doxygen did not write;
a header it wrote no HTML page for. And it finds (exit 1): a Doxyfile that silences what it counts, read back through
`doxygen -x` (the effective settings, `@INCLUDE` resolved): `EXTRACT_ALL`, `HIDE_UNDOC_*`, `WARNINGS`,
`WARN_IF_UNDOCUMENTED`, `WARN_IF_DOC_ERROR`, `WARN_IF_INCOMPLETE_DOC`, `WARN_AS_ERROR`, `WARN_FORMAT`, a filter,
`EXCLUDE_PATTERNS`, and `WARN_NO_PARAMDOC` not `YES`; a tracked header of the Doxyfile's `INPUT` (`FILE_PATTERNS`, `RECURSIVE` and
`EXCLUDE` honoured, git-tracked files only) with no `@file` in a doc comment (doxygen reports none of a file's
undocumented members without one); an untracked header there; a header hiding code with `@cond`, `@internal`,
`@private` or `@if`; a compared setting read from an environment variable (`$(VAR)`, through `doxygen -x_noenv`),
which would read equal against the base and differ at run time. The HTML goes to a throwaway directory the gate removes: with every `GENERATE_*` off, doxygen 1.9.8 never
records `@param` and `@return` and warns on every function, documented or not.

Against the base (resolved by resolve-base, the files read at the merge-base): a baseline row the base's baseline
does not carry is red (the list only shrinks); a Doxyfile setting that differs from the base's, each read through
`doxygen -x` in its own tree, is red by key with both values. Every setting is compared but the ones that only shape
the rendered output (`PROJECT_*`, `OUTPUT_DIRECTORY`, `GENERATE_*`, `HTML_*`, `LATEX_*`, the graphs, the search): a
list of the keys that silence rows would always be one key short (`EXTRACT_ALL`, `RECURSIVE` and `WARN_FORMAT` were
each found after such a list was written). `accept-config-change: <key>` lets a meant change through: the red names
the change's key (a hash of the watched settings and the ruff configuration, at the merge-base and here), and only
that key accepts it, so a configuration change pushed after the reviewer read the first is red again, by setting,
naming the old key as another change's. The accepted change is logged in the run's output with the key and both values
(the ruff configuration with its diff) and the change's key, and the input is itself red when nothing differs, so it
never stays in a workflow. The limit that stays: a declaration under a preprocessor condition that is
false with only the Doxyfile's `PREDEFINED` (an `#ifdef X` block) is not read, as a C compiler would not read it
either; its rows are neither warned nor missed. A base without the gate's files is the change that brings it,
and has nothing to compare. The reusable workflow compares on a pull request (`origin/${{ github.base_ref }}`) and
says a push has no base; an empty base on a pull request is refused by name, never skipped.

The Python half counts what ruff honours, with ruff: `ruff check` must be clean, and the suppressed findings (the
count under `--ignore-noqa` minus the count without: `# noqa`, `#noqa: D103`, `# NOQA`, `# noqa:D103`,
`#   noqa : D103`, `# noqa D103`, a second `#` after it, a file-level `# ruff: noqa` or `# flake8: noqa`: every form
ruff honours, counted by ruff) may not grow against the base; a changed ruff configuration is red
unless accepted.

| Arm (stand-in doxygen unless said) | Wanted |
|---|---|
| the tree at its baseline, with and without the base and the Python | green |
| a new row; a stale row; a swapped row | red, each row named (a set, never a count) |
| a duplicated row; the last newline missing | red `not sorted and unique`; green, the same set |
| a warning with continuation lines | one row, joined |
| `--update` with a new row; with a row gone | refused by name, baseline untouched; lowered |
| no Doxyfile, baseline, pin; an empty pin; an `INPUT` with no tracked header | exit 2, each by name |
| another doxygen version; no doxygen; no log; no page; a subdirectory | exit 2, each by name |
| a header with no `@file`; `@file` in a plain comment; `/// @file` | red by name; red by name; green |
| an untracked header under `INPUT` | red by name |
| `@cond`, `@internal`, `@private` | red, the line named |
| `EXCLUDE_SYMBOLS = $(HIDE)` | red by key: an environment variable in a compared setting |
| `EXTRACT_ALL`, `HIDE_UNDOC_MEMBERS`, `WARN_IF_UNDOCUMENTED = NO`, no `WARN_NO_PARAMDOC`, a filter, `EXCLUDE_PATTERNS`, `WARN_FORMAT` | red by key |
| a setting behind `@INCLUDE` | read as doxygen reads it |
| `EXCLUDE`, `PREDEFINED`, `ALIASES` changed against the base; accepted; accepted with no change | red by key, both values; green, the change logged with both values; red `drop the flag` |
| `PROJECT_NUMBER` changed against the base | green: it only shapes the output |
| a baseline row added against the base; struck | red, the row named; green |
| a base without the gate's files | green, each missing file named |
| `--base ''`, an unknown base, a stale remote base with its fetch failing | refused by name through resolve-base |
| a ruff finding; each noqa form added; a noqa removed with the function documented | red; red `grew from 1 to 2`; green |
| a changed ruff configuration; accepted; no ruff; no configuration; no ruff pin; another ruff than the pin | red by name; green, logged with its diff; exit 2; exit 2; exit 2; exit 2 naming both |
| sabotage: a count compare; the settings check, the base compare, the Doxyfile compare, the suppression compare removed | the swap passes; `EXTRACT_ALL`, an added row, a changed `EXCLUDE`, a noqa each pass: each compare is what catches its case |
| real doxygen: two documented headers of one name; `@return` dropped; `EXTRACT_ALL` planted | no row; red `return type of member add`; red by key |

The self-test needs doxygen and ruff on the path and is red by name without them (`tests/doc-gate.sh`, the `doc-gate`
job of `ci.yml`, on the runner whose apt serves 1.9.8).
