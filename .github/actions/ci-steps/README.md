<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# ci-steps

A check that sits in no step pins nothing, and neither does one whose failure the step swallows. This action reads a
repository's workflow files and says, per job, per step and per command of each `run:` script, whether the command runs
(`always`, `conditional`, `never`) and whether its failure fails the job. A repository then states what it requires and
the action goes red when a required command is written but not enforced.

```yaml
- uses: actions/checkout@v4
- uses: Open-Mixer/.github/.github/actions/ci-steps@v1
  with:
    workflows: |
      .github/workflows/ci.yml
    require: |
      tests/my-check.sh
      npm test
```

| Input | |
|---|---|
| `workflows` | the workflow files to read, one per line |
| `require` | one command per line, `CMD [ARG...]`: a command whose command word is CMD (a path may be longer on the left) and whose arguments hold every ARG must run always and gate, in one of the workflows |
| `conditional` | `true` to take a command that runs conditionally |

The action first runs the table and the sabotage rows below against the reader, then the requirements. It needs python3
with PyYAML (the hosted ubuntu runners have both). `ci_steps.py` can also be run by hand: `ci_steps.py WORKFLOW...` for the
report, `--json` for it as JSON, `--require` as above. Exit 0, 1 (a requirement is not met), 2 (usage, or a workflow that
cannot be read).

## What is decided

- A step is judged under the shell it runs: `bash -e {0}` with no `shell:`, `bash --noprofile --norc -eo pipefail {0}`
  for `shell: bash`, the step's, job's or workflow's `defaults.run.shell` in that order. Another shell is reported
  unread.
- `cond && x` in a block is conditional: errexit does not act before `&&`, so the step goes green without x. As the
  script's last line it is always.
- `x && echo ok` in a block does not gate, for the same reason.
- A quoted script given to `bash -c` (or `sh -c`) is parsed and judged as a script of its own, with the options given to
  that shell and not the step's: `bash -c "set -n; tests/x"` is reported as never run.
- An `if:` that is the literal false makes the commands never run. An `if:` that compares `github.event_name` with
  `==` or `!=` against a string (joined by `&&` and `||`) is evaluated against the events of the workflow's `on:`
  (a string, a list or a map): false on every one of them, the commands never run and `--require` refuses the step by
  name. Any other `if:`, and a workflow that is `workflow_call` or has no `on:`, is undecidable and is reported as a
  condition of the step or job, never as running.
- Known limits, all loud (reported as conditional or not gating, never as a false green): `if ! x; then exit 1; fi` is
  not recognised as gating; a function's body is conditional wherever it is called; `wait` after `&` is not followed.
- Bounds: a script longer than 262144 bytes, or nested deeper than 64 levels (substitutions, groups, `if`s, quoted
  scripts), is reported unread by name. The reader never needs more than a few MiB.

## The table

`arms.yml` is the table: one row per case, in arms. `arms.py` runs every row against the reader, and every row that is
only a script is also run by the real shell under the runner's command line for its `shell:` with the command a stub
that succeeds and then one that fails; the row's `want` is held to what the shell did. `sabotage.yml` holds the breaks:
`arms.py --sabotage` applies each to a copy of the reader and the table must go red in the arm it names.

| Arm | Case | Rows | Breaks |
|---|---|---|---|
| 1 | heredoc and here-string | 19 | 1 |
| 2 | continuation lines | 6 | 1 |
| 3 | \|\| true | 10 | 1 |
| 4 | continue-on-error | 5 | 1 |
| 5 | \| tee without pipefail | 8 | 1 |
| 6 | bash -n | 6 | 1 |
| 7 | a backgrounded & | 6 | 1 |
| 8 | \|\| { exit 1; } | 10 | 1 |
| 9 | env, command, timeout, bash -e prefixes | 17 | 1 |
| 10 | exec, source, time, ( subshell | 17 | 1 |
| 11 | job- and step-level if | 9 | 1 |
| 12 | a quoted ; | 8 | 1 |
| 13 | set +e | 9 | 1 |
| 14 | $(x) inside a command | 12 | 1 |
| 15 | cond && x | 15 | 1 |
| 16 | shell: bash {0} | 11 | 1 |
| 17 | text that is no command | 10 | 1 |
| 18 | an explicit `shell: bash` is bash --noprofile --norc -eo pipefail {0}; only a step with no shell lacks pipefail | 6 | 1 |
| 19 | set +o pipefail turns pipefail off for the lines after it | 4 | 1 |
| 20 | a set -o pipefail after the pipe line, or inside quotes, does not count | 7 | 1 |
| 21 | a quoted script given to bash -c is parsed and judged as a script of its own | 10 | 1 |
| 22 | an `if:` on github.event_name that is false on every trigger of the workflow cannot run; one that cannot be decided is conditional | 17 | 14 |
| 23 | an input too big or too deep is refused by name, within a bound of memory and time, never crashes the reader | 6 | 3 |

Run both from the repository root: `python3 -I .github/actions/ci-steps/arms.py` and the same with `--sabotage`
(`tests/ci-steps.sh` does).
