<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# Open-Mixer/.github

Organisation defaults and the reusable package release workflows.

## Releasing a package

Every package's release workflow is a few lines that call the one reusable workflow of this
repository, `.github/workflows/build-rpm.yml`: push a tag `vX.Y.Z` that matches the `Version:` of the
package's `packaging/*.spec`, and the RPMs are built for x86_64 and aarch64, signed, published into the
`rpm/` tree of the organisation's Pages repository and attached to the GitHub release. Without a tag
the same workflow is a dry run that publishes nothing.

While a release wave is open a run can build the quick set (fc44 and fc45 x86_64, trixie amd64 and arm64) instead of the whole
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
them: `public-sources-check.yml` (commit messages, private references, and no local copy of either, the
commit-msg hook being `.github/actions/commit-message-check/commit-msg` byte for byte; and, in a public repository,
no dated document, no dated folder and no folder of evidence or notes), `ci-node.yml`, `ci-c.yml`,
`fuzz.yml`, `release-c-lib.yml` (RPMs and DEBs side by side) and `release-npm.yml` (trusted publishing). Each documents its
inputs at its top. A repository whose every tracked file carries its licence runs `.github/actions/spdx-check`: the
rule is the format of the file, a format with no comment syntax carries no header, and there is no list of files.

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
- mod-host is built from the FreeMixer fork at the commit `pins.txt` names, by the fork's own spec and `debian/`;
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
  bookworm and trixie, on x86_64/amd64 and aarch64/arm64, before they publish.

- The CLAP headers, at 1.2.10, the floor every package of the channel builds against, one number for every
  distribution: Fedora 44 and 45 ship clap-devel 1.2.7 and Debian none, so the channel serves the pin of `pins.txt`
  (tag 1.2.10) to all of them. `packaging/clap-headers` builds clap-devel, a newer EVR of Fedora's own package that
  `dnf upgrade` takes over it, by `clap-rpm.yml` for fedora 44 and 45 on x86_64 and aarch64; `actions/deb-deps/
  clap-headers` builds clap-headers by `clap-headers-deb.yml` for bookworm and trixie (Architecture: all). Each run
  installs the package in a clean container and compiles against it before it publishes.

A published version is never rebuilt with new bytes. To change what goes in, move the pin and bump the version.
