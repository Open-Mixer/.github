<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# Open-Mixer/.github

Organisation defaults and the reusable package release workflows. `SECURITY.md` is the security policy of
every repository that has none of its own.

## Releasing a package

Publishing is by tagging only: every job that signs or pushes to the channel, npm or a GitHub release runs only on a
tag push, and a run by hand never publishes (`docs/release-operations.md`, "Publish only by tagging").

Every package's release workflow is a few lines that call the one reusable workflow of this
repository, `.github/workflows/build-rpm.yml`: push a tag `vX.Y.Z` that matches the `Version:` of the
package's `packaging/*.spec`, and the RPMs are built for x86_64 and aarch64, signed, published into the
`rpm/` tree of the organisation's Pages repository and attached to the GitHub release. Without a tag
the same workflow is a dry run that publishes nothing.

While a release wave is open a run can build the quick set (fc45 x86_64, trixie arm64) instead of the whole
matrix; a tag builds the whole matrix unless the wave says otherwise. `docs/release-operations.md`, "The quick set
and the full matrix", has the rule.

## Adding the repository

A machine adds the channel by installing `openmixer-release` (`packaging/openmixer-release`, released by
`.github/workflows/release-package.yml` on a tag `openmixer-release-<Version>-<Release>`):

    sudo dnf install https://www.openmixer.org/rpm/openmixer-release.noarch.rpm
    curl -fsSLO https://www.openmixer.org/deb/openmixer-release.deb && sudo apt install ./openmixer-release.deb

`docs/release-operations.md` says what it installs and how it is released.

## Versions

The checks and builds every repository runs are reusable workflows here, and a repository keeps no copy of
them: `public-sources-check.yml` (commit messages, commit identity, private references, and no local copy of either, the
commit-msg hook being `.github/actions/commit-message-check/commit-msg` byte for byte; and, in a public repository,
no dated document, no dated folder and no folder of evidence or notes), `ci-node.yml`, `ci-c.yml`,
`fuzz.yml`, `release-c-lib.yml` (both kinds built, then `channel-installability.yml`, then RPMs and DEBs published),
`channel-installability.yml` (no release leaves a package of the channel uninstallable), `release-npm.yml`
(trusted publishing) and `doc-gate.yml` (doxygen's warnings held to a baseline that only shrinks, ruff beside it;
its base, like every compare gate's, resolved by `.github/actions/resolve-base`: `docs/doc-gate.md`). Each documents its
inputs at its top. A repository whose every tracked file carries its licence runs `.github/actions/spdx-check`: the
rule is the format of the file, a format with no comment syntax carries no header, and there is no list of files.
A check a repository relies on is run by a step that enforces it: `.github/actions/ci-steps` reads the workflow
files and goes red when a required command is in no step that runs it and fails the job (its README holds the arms).

`.github/actions/commit-identity-check` (a job of `public-sources-check.yml`, run when the caller passes `commit-identity: true`; off by default so moving `openmixer-v1` turns no caller red, and `author-email` / `committer-email` inputs pass through) reads EVERY commit of a pull request's
range, `origin/<base>..HEAD`, not only the head: the author email must be `linuxnow@gmail.com`, the committer email
`commits@openmixer.org` (the signing key's uid) and `.commit.verification.verified` true as GitHub reports it for the
commit (workflow token). The two emails are the action's inputs, whose defaults in its `action.yml` are the one place
they are written. Each offending commit is named by sha, field and value (a committer of `linuxnow@gmail.com` reads
`bad_email`, unverified). There is no bypass list. A base that moved on is not charged to the pull request (what the
base tip reaches is not in the range); GitHub's own "Update branch" commit is in the range and fails, so merge the base into the branch locally (a plain signed `git merge`, house author and committer) and push plainly, never a rebase or force; the merge button's commit is made after the checks and is never read. A missing API answer is exit 2, never
a pass. `tests/commit-identity-check.sh` proves it on planted ranges, including the head-only sabotage.

`.github/actions/pr-fixes-issue` (its own reusable workflow `.github/workflows/pr-fixes-issue.yml`, not a job of `public-sources-check.yml`: the check reads the pull request through the API, which a private repository answers only to `pull-requests: read`, and a called workflow cannot widen past its own permissions block while a pull-requests permission inside `public-sources-check.yml` would fail every caller that grants less; a caller adds one job `uses: Open-Mixer/.github/.github/workflows/pr-fixes-issue.yml@openmixer-v1` with `permissions: { contents: read, pull-requests: read }`; off by default, no caller has it, because a survey of the open pull requests of Open-Mixer and FreeREAC on 2026-11-20 found 223 of 280 with no closing reference, so on by default would turn most callers red the day `openmixer-v1` moves; require the check named `the pull request body closes an issue` once a repository's own open pull requests carry one) is the rule that every pull request fixes an issue: the CURRENT pull request body, read from the API with the job token (an edited body starts no run and a re-run replays the old payload) and never spliced into a run line, must hold a closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, any case) followed by `#N`, `Open-Mixer/<repo>#N` or `FreeREAC/<repo>#N` (owners case-insensitive, as GitHub links them). A reference of any other owner is refused by name, a reference written inside a code block or inline code does not count (GitHub links none), and the failure says what is missing; a body that cannot be read is exit 2, never a pass. `.github/workflows/pr-fixes-sweep.yml` is its read-only companion, daily once the owner enables the schedule (`contents`, `issues` and `pull-requests` read only; job summary only, no comment, label, close or deletion): over every non-archived repository of Open-Mixer and FreeREAC it lists the open issues created 7 or more days ago whose GraphQL `closedByPullRequestsReferences` is empty, and the branches with no open pull request and no issue reference in the name or the last commit message (the default branch, `main`, `openmixer-v*`, `release/*`, `settle/*` and `gh-pages` skipped), one API call per second; it reads with the read-only secret `SWEEP_READ_TOKEN` (no fallback to the default token; the owner creates it, and enables the commented schedule only then). `tests/pr-fixes-issue.sh` and `tests/pr-fixes-sweep.sh` prove them on planted bodies and a fixture, with a sabotage each.

`.github/actions/fedora-workflow-check` (a job of `public-sources-check.yml`, run when the caller passes `fedora-workflows: true`; off by default so moving `openmixer-v1` turns no caller red) is the one Fedora workflow guard, replacing the per-repository `tools/test/workflow-fedora-check.sh` copies. It reads the calling repository's `.github/workflows/*.yml`, outside comments, and refuses a Fedora release that is not in the `allowed-fedora` input (default `45`, the development matrix; `OMX_RELEASE_MATRIX=full` returns the full set by widening the list, never by editing the script): `fedora:NN` images, `fcNN` names, a number on a `fedora` line or list and `releases` / `rpm-releases` lists. `fedoraNN`, the name of a measured record set, is data and not a release. The list reaches the script through the environment, never a run line. `tests/fedora-workflow-check.sh` proves it on the 12 planted arms of omx-panel#148, the allowed-list change and one sabotage per rule.

Call the shared workflows and actions by the `v1` tag, never by `main`:

    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1

`v1` moves on compatible releases, so a repository on `v1` picks up fixes and additions without an edit.
`v1.0.0` and every other full version tag never move. A breaking change gets a new major tag, `v2`.
The shared workflows call their own actions at `v1` too, so a pinned caller runs one consistent version.

## Wave branches

Work that spans repositories lands on a `dedupe/all` branch of each, and a pull request into one builds on its
siblings' same branch, which the channel does not carry yet. `.github/actions/wave-deps` takes the siblings a
repository builds on and, on a pull request into `dedupe/all` or a push to it, builds each from its `dedupe/all` (as
the minor the wave releases) into a local package repository that dnf and apt then prefer over the channel; the
builddep and install steps after it are unchanged. Every other run keeps the channel's releases. The builds are
cached by the siblings' commits. The action's top says where it goes; `tests/wave-deps.sh` checks the version it
builds at and when it switches on.

## Why we pin

`pins.txt` names each outside source the packages are built from by its exact commit, not by a branch or a
version name. A version name does not say which bytes you have; a commit does. So:

- Every package we publish can be traced back to the exact upstream commit it was built from.
- CI, the build machines and a developer's desk all build the same thing; nothing drifts when upstream moves.
- A change of dependency is one reviewed line here, with its changelog entry, so you can see when and why it moved.
- mod-host is built from the OpenMixer fork at the commit `pins.txt` names, by the fork's own spec and `debian/`;
  nothing is patched here (`docs/mod-host.md`).

- pugl and nanovg, which neither Fedora nor Debian package, are pinned here and built by `packaging/pugl`,
  `packaging/nanovg` (the RPMs, `actions/pinned-rpms`) and `actions/deb-deps/pugl`, `nanovg` (the DEBs); a spec
  whose `commit0` is not the pin is refused. NanoVG ships no library build, so `packaging/nanovg/overlay/meson.build`
  is laid on its source for both. omx-panel's renderer builds its window against them.

- Surge XT, which neither distribution packages, is pinned here and built as a CLAP and an LV2 by `packaging/surge-xt`
  (the RPMs, `actions/pinned-rpms`) and `actions/deb-deps/surge-xt` (the DEBs), through one script, `packaging/surge-xt/
  overlay/surge-xt-build.sh`. Upstream tags nothing from 1.4.0 on, so the pin is a commit of its main that calls itself
  1.4.0; its submodules come with it (`packaging/surge-xt/make-source.sh`). The files go to `/usr/lib/clap`,
  `/usr/lib/lv2` and `/usr/share/surge-xt`; `packaging/surge-xt/load-check.sh` loads the installed package in
  `omx-clap-scan` and `lilv`, and the workflows `surge-xt-rpm.yml` and `surge-xt-deb.yml` run it for fedora 44 and
  trixie, on x86_64/amd64 and aarch64/arm64, before they publish.

- The CLAP headers, at 1.2.10, the floor every package of the channel builds against, one number for every
  distribution: Fedora 44 and 45 ship clap-devel 1.2.7 and Debian none, so the channel serves the pin of `pins.txt`
  (tag 1.2.10) to all of them. `packaging/clap-headers` builds clap-devel, a newer EVR of Fedora's own package that
  `dnf upgrade` takes over it, by `clap-rpm.yml` for fedora 44 and 45 on x86_64 and aarch64; `actions/deb-deps/
  clap-headers` builds clap-headers by `clap-headers-deb.yml` for trixie (Architecture: all). Each run
  installs the package in a clean container and compiles against it before it publishes.

A published version is never rebuilt with new bytes. To change what goes in, move the pin and bump the version.
