<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# Release operations

What a caller of `build-rpm.yml` and `build-deb.yml` must grant, and how the parts that only run on a real
release are tested.

## What the calling release.yml grants

A called workflow cannot raise the token of its caller; the `permissions:` inside the reusable workflow only
narrow it. The calling `release.yml` therefore carries, at the top level or on the job that calls the shared
workflow:

```yaml
permissions:
  contents: write   # the GitHub release and its assets
  issues: write     # the issue opened when a release ends without packages
```

Without `issues: write` the `report-failure` job still runs, and ends in an error naming the missing permission
instead of a silent miss.

## Secrets

| Secret | Used for |
| --- | --- |
| `PAGES_TOKEN` | pushing the packages to the Pages repository |
| `OPENMIXER_PACKAGES_SIGNING_KEY`, `RPM_GPG_KEY`, `RPM_GPG_PASSPHRASE` | signing the packages and the index |
| `SITE_GPG_KEY` | signing the commits to the channel |
| `DISPATCH_TOKEN` | the `repository_dispatch` that tells the worker image build about a new package |

`DISPATCH_TOKEN` is the token meant for the dispatch. When it is unset, `PAGES_TOKEN` is tried and the job says
so in a notice; what `PAGES_TOKEN` may do on the dispatch repository is not recorded, so a refusal there is
expected. With neither token the job skips with a notice. The job is `continue-on-error` while nothing listens
for the event, so it never turns a published release red.

`verify-install: false` skips the clean-container install check. The release is then not proven installable,
and the dispatch goes out on the publish alone.

## The installability gate

No release may leave a package of the channel uninstallable. `channel-installability` builds the channel as it
would be after the release, the published index plus the new packages, and asks the package manager's own solver,
on the newest version of each package, as apt installs it (apt does not go back to an older version, so a library
published alone above its consumers' ceiling breaks them although the old library is still in the tree):

- DEB: `dose-debcheck` over each Debian release and architecture the channel serves, the Debian release (main,
  updates, security) as background, before and after. A package installable before and not after is red, named
  with the dependency that is not met.
- RPM: `dnf repoclosure --newest` over each Fedora release and architecture, the same way.
- Ceilings (R-107): every dependency between our own packages that a new package declares has a floor and a
  ceiling, and a new version outside the range a published consumer declares is red, naming the consumer: release it
  in the same pass.
- Newest: each of our packages is installed by itself on a clean machine (`apt-get -s install`, `dnf install
  --assumeno`), and it and every one of our packages it pulls in must resolve to the newest version published. dnf
  backtracks: in the middle of a pass it can take an old build that declares no ceiling (plugin-hostd 0.17.0, which
  asks only for protocol 0.2.0 or later) and install it beside the new library, so repoclosure passes while the user
  silently gets old packages. A fallback the release brings is red, named with dnf's or apt's own reason.
- Hygiene: every published build, old ones included, whose dependencies on our own packages have no floor and
  ceiling is flagged (`HYGIENE:`), so it can be removed from the index or superseded. It is reported, not red.

It runs before anything is signed: inside `publish-debs` and `publish-rpms` (on the tree they pulled, or the served
channel in a dry run), and in `release-c-lib.yml` between the build of both kinds (`stage: build`) and the publish
of either (`stage: publish`). A package released by another repository in the same pass is named in `same-pass`; a
breakage it causes or suffers is then reported, not red, and its own release is checked when it publishes. A package
already uninstallable before the release is reported as a warning. An architecture the run built no binary for (a
dry run, or a release of the quick set on the cells outside it) takes the binaries built on another architecture as
released in the same pass (`--unbuilt-arch-pass`): the full release builds them; the architectures the run built
are judged strictly (`tests/quick-unbuilt-pass.sh`). A staged publish (`staging: true`) lands in the staging channel, which no client installs from by default, and is not checked. Exit 2 means the measurement could not be taken,
and is not a pass.

`tests/channel-installability.sh ceiling|deb|rpm` proves each arm on a throwaway channel, offline. To check a
release by hand against the live channel: `.github/actions/channel-installability/run.sh deb <dir of <suite>/*.deb>`
in a Debian container, or `run.sh rpm <dir of rpms>` in a Fedora one.

## The lost-race retry of channel-push

Two releases that publish to the same Pages repository can race for the tip of its branch. `channel-push`
repeats a push that lost on the new tip: it resets the checkout, assembles the tree again, signs a new commit
and pushes. The GitHub release assets are copied from the tree after the push, so they are the bytes the
channel serves.

### Local test

`tests/channel-push-race.sh` runs the real push step of the action against a bare git remote whose first push
loses the race to another publish. It checks that the remote ends with both publishes and a signed commit on
top, and that the same race fails the step when no rebuild command is given. It runs in CI as
`channel-push-race`. To sabotage-verify it, change the loop condition in `channel-push/action.yml` so it
always gives up: the test goes red.

### Forced race on a real release

Use a throwaway Pages repository, never the live channel.

1. Make a repository with a `release.yml` that calls the shared workflows with `target-repo` set to the
   throwaway Pages repository, and a small package in it.
2. Push two tags of two packages (or of the rpm and the deb workflows) within a few seconds of each other, so
   both reach `channel-push` together. To make the collision certain, add a short `sleep 40` to a copy of the
   first package's build job so the second one pushes first.
3. In the log of the later run look for `the push to ... lost a race (attempt 1 of 6)`, then
   `published <tag> to ...`.
4. In the Pages repository check that `git log` holds both publishes, that each commit is signed, and that the
   repodata or `InRelease` lists both packages.
5. Download an RPM or DEB from the GitHub release of the retried run and compare its sha256 with the file the
   channel serves.

## A released version for a new Fedora release

The release preflight refuses a version the channel already serves, but only in the trees the release publishes
into: build-rpm.yml checks the Fedora releases of its `fedora-versions`, build-deb.yml the suites of its
`suite-matrix`. A version served for fc44 therefore does not block its first fc45 publish.

To give a new Fedora release the packages the others serve, without a version bump, run `publish-fedora.yml` on
main with the repository, its existing tag and `fedora-versions` (`["45"]`). It checks the tag is annotated and
verified, builds that commit with the inputs the repository's own release.yml passes, and publishes the named
releases only; the GitHub release of the tag is left as it is. Publish in dependency order (omx-contract first),
since each build takes its BuildRequires from the channel's tree of its own Fedora release, and one run at a time.

## The staging channel of a release wave

A release wave publishes inner layers before the outer ones build on them. Inside the wave, a layer does not wait
for the real channel: its staged run publishes to the staging channel, and the next layer builds, verifies and
install-tests against it. The real channel gets the whole set once, in the wave's release pass, from the `v<version>`
tags. The staging channel is per wave and is purged after the pass.

### Where it is

The staging channel is a second dnf tree and a second apt tree in the same channel repository
(`Open-Mixer/open-mixer.github.io`), beside `rpm/` and `deb/`, served by the same host and signed with the same key:

| | RPM | DEB |
| --- | --- | --- |
| tree | `staging/rpm/fedora/<release>/<arch>/` | `staging/deb/debian/<suite>/<arch>/` |
| URL | `https://www.openmixer.org/staging/rpm/fedora/$releasever/$basearch/` and `.../noarch/` | `https://www.openmixer.org/staging/deb/debian/<suite>/` |
| key | the real channel's: `/etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer` | the real channel's: `/usr/share/keyrings/openmixer-archive-keyring.asc` |
| priority | `priority=10` (the real repositories keep dnf's default, 99) | `Pin-Priority: 600` on `Label: OpenMixer-Staging` (the real channel stays at 500) |

Every Fedora release and Debian release of the workflow's matrix has an index in the staging tree, empty or not, so a
machine that adds the staging channel never reads a 404. The release preflight, the channel prune and
channel-installability read `rpm/` and `deb/` only; the site deploy of openmixer-www replaces only the paths it owns.
On a machine that already holds a cached staging index, `apt-get update` only warns when a new index fails its signature
and keeps the old one; a fresh CI container has no cached index and fails correctly, so nothing is changed for it.

### The files a machine adds

The real channel first (openmixer-release, which installs the key), then these. They are `packaging/staging/` of this
repository, and `add-staging.sh` of the add-openmixer action writes them.

`/etc/yum.repos.d/openmixer-staging.repo`:

```ini
[openmixer-staging]
name=OpenMixer staging
baseurl=https://www.openmixer.org/staging/rpm/fedora/$releasever/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
priority=10

[openmixer-staging-noarch]
name=OpenMixer staging (noarch)
baseurl=https://www.openmixer.org/staging/rpm/fedora/$releasever/noarch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
priority=10
```

`/etc/apt/sources.list.d/openmixer-staging.sources`, with the system's Debian release for `<suite>`:

```
Types: deb
URIs: https://www.openmixer.org/staging/deb/debian/<suite>/
Suites: ./
Signed-By: /usr/share/keyrings/openmixer-archive-keyring.asc
```

`/etc/apt/preferences.d/openmixer-staging.pref`:

```
Package: *
Pin: release l=OpenMixer-Staging
Pin-Priority: 600
```

Where a package of the staging channel meets a dependency, it is taken over the real channel's, even over a higher
version; everything else comes from the real channel. The repository ids start with `openmixer` on purpose: channel-installability
disables every system repository whose id does, so the gate keeps judging the real channel alone on a machine that
has staging added (`tests/staging-installability.sh`). To take the staging channel off a machine, remove the three
files and refresh (`dnf makecache`, `apt-get update`).

### How a layer uses it

- **Publish to staging.** Dispatch the repository's release workflow on a branch with `staged: true` (never a tag).
  `build-rpm.yml` and `build-deb.yml` build the quick set (fc44 and fc45 on x86_64, trixie on amd64 and arm64), or the whole
  matrix when told full ("The quick set and the full matrix" below), against the staging channel,
  sign the packages with `OPENMIXER_PACKAGES_SIGNING_KEY`, assemble `staging/rpm` and `staging/deb` with the tree scripts
  of a real publish and push through `channel-push`, then install the build of that commit from the staging channel in
  a clean container. The real channel is not written. `staged` refuses a tag, `source-ref`, `publish` and
  `source-repository`.
- **Build against staging.** `staged: true` already does. A dry run on a branch takes `staging: true`: the build
  containers add the staging channel, and nothing is published. `staging` refuses a tag, `source-ref` and `publish`, so
  a release never builds against staged packages.
- **Anywhere else** (a consumer's own CI, the verify Job, an install test): `add-openmixer` with `staging: 'true'`, or
  the three files above on a machine that has openmixer-release. A consumer turns it on with one switch and has no
  per-package code: dnf and apt resolve to the staged builds.

For this wave only, the reusable workflows still accept `staged-deps` and ignore it, and `install-staged` is a no-op that says it is retired; both are removed in the wave's release pass once omx-panel, plugin-hostd and omx-clap-core have switched to `staging`.

The staged versions sort above the release of the same version (`<version>-<release>.git<commit time>.<sha>` for RPM,
`<version>+git<commit time>.<sha>` for DEB), so a consumer's floor on the coming version is met. The commit time, in
seconds, comes before the sha because a short sha sorts by chance: with it the staged build of a later commit sorts
above the build of an earlier one. A staging publish also drops the other staged builds of the same package and
version from the directories it publishes into, so the staging channel offers one build of a version, the last one
staged.

### Promoting a staged version

`promote-staged.yml` makes a staged build the release without building it again, so what the layers above were built
and verified against is what ships. A repository calls it from a `promote.yml` of its own (dispatched by hand, with
`contents: write`; the header of `promote-staged.yml` has the caller), with the staged `version` and, when staging
holds builds of more than one commit of that version, the `commit`.

1. **Find.** The staging tree must hold the build of that one commit for every Fedora release, Debian suite and
   architecture of the matrix, with its source package, and must cover every release the channel root serves the
   package for. The commit must be on the default branch, and `v<version>` must be free or already on that commit.
   A staged build of the quick set does not hold every cell, so it is refused here by name: a version is promoted
   from a staged run of the full matrix, or released from its tag.
2. **Check.** Every RPM carries a good signature by a key the channel serves; every DEB is listed with its SHA256 in
   the signed staging index of its suite. Nothing is signed by a promotion.
3. **Publish.** The files go to `rpm/` and `deb/` through `publish-rpms` and `publish-debs`, in the publish group of
   the channel; the metadata is regenerated and signed, the packages are placed as they are, and the tree is compared
   with the staged checksums before the push is trusted.
4. **Prove.** Every promoted file is fetched from the served channel and its SHA256 compared with the staged one
   (`same bytes <sha256> <path>` lines in the run log), then the version installs from the channel root alone in a
   clean container of every release and architecture.
5. **Tag and release.** Only then: `v<version>` on the commit the staged build recorded, and the GitHub release with
   the promoted files. The tag is made by the workflow's token, so it starts no tag-triggered release run.

Any refusal in 1 or 2 leaves the channel as it was. `dry-run: true` stops after assembling an unsigned tree: nothing
is pushed, tagged or released. A promoted package keeps the version string of its staged build
(`<version>-<release>.git<commit time>.<sha>`, `<version>+git<commit time>.<sha>`), because its bytes are the same. The staged copies stay under
`staging/` until the purge. `tests/promote-staged.sh` and `tests/promote-publish.sh` hold the proofs.

### The purge

After the wave's release pass has published every layer to the real channel, run `purge-staging.yml` (dispatched by hand, it being on the default
branch, the only place GitHub dispatches from; or as
the last job of the pass with `uses: Open-Mixer/.github/.github/workflows/purge-staging.yml@openmixer-v1` and
`secrets: inherit`). One job per kind empties `staging/rpm` and `staging/deb`, regenerates their empty metadata with
the tree scripts, signs it with the same keys and pushes through `channel-push`. A machine that still has the staging
channel added then reads an empty index.

The staging channel needs no hand step to come to exist: the first staged publish creates `staging/rpm` or
`staging/deb` with the signed index of every release of its matrix and the key, and a purge of a channel that never had
staging makes the same empty tree. Before that first publish the staging URLs answer 404, and a build that adds staging
then fails, naming the URL that answered 404: a staged build never falls back to the released dependency.

The one exception is the first layer of a wave (omx-contract's own staged run), whose build job adds staging before
anything was ever published to it. Its release workflow, and only it, passes `staging-bootstrap: true` to `build-rpm.yml`
and `build-deb.yml` (the input of the same name on `add-openmixer`), so that `add-openmixer` (add-staging.sh) adds
nothing and gives a notice when this machine's staging index and the staging key file both answer 404. The coordinator
of the wave sets it in that one caller. Even with the switch, a staging tree that exists without this release's index,
any other status, or an index whose signature does not verify still fails the step (`tests/staging-bootstrap.sh`).
After a purge the empty index is served, so the channel is added and loaded as usual. Each job refuses a checkout changed outside `staging/<kind>`, so `rpm/`, `deb/`
and the site are never committed (`tests/staging-publish.sh` checks them byte for byte). `dry-run: true` purges a
pulled copy and pushes nothing.

## The quick set and the full matrix

A release builds eight cells: Fedora 44 and 45 on x86_64 and aarch64, Debian bookworm and trixie on amd64 and arm64.
While a release wave is open the next layer needs only enough of a version to go on, so a run can build the **quick
set** instead:

| kind | cells |
|------|-------|
| rpm  | fc44 x86_64, fc45 x86_64 |
| deb  | trixie amd64, trixie arm64 |

trixie amd64 joined the set on 2026-11-13: the amd64 CI runners (zynthian-ui, omx-plugins' Debian packages) install
from the deb channel, and with no quick amd64 cell every one of their runs failed on a version the wave had not
built there. bookworm stays out.

The set is written once, in `.github/actions/release-matrix/quick.txt`. `build-rpm.yml` and `build-deb.yml` ask the
`release-matrix` action in their first job, and the build jobs and the install checks both run for the cells it
names, no others. The run says which set it builds, and why, in a notice.

### Which set a run builds

| run | `matrix` input | `OMX_RELEASE_MATRIX` unset | `quick` | `full` |
|-----|----------------|----------------------------|---------|--------|
| any | `quick` or `full` | the input | the input | the input |
| a tag, or `source-ref` | empty | **full** | quick | full |
| `staged: true` | empty | **quick** | quick | full |
| `workflow_dispatch`, not a tag | empty | **quick** | quick | full |
| a pull request, a push to a branch | empty | full | full | full |

- **A caller that changes nothing** passes no `matrix`. Its tag push builds the full matrix, as it always did,
  unless the organisation variable `OMX_RELEASE_MATRIX` is `quick`. The default is full on purpose: a tag pushed by
  hand with no wave open must never publish four cells of eight because nobody said otherwise.
- **`OMX_RELEASE_MATRIX`** is the one thing the release chain sets: `quick` when it opens a wave, `full` (or
  removed) before the final release of each repository. It is an organisation variable because a tag push carries no
  inputs, and the callers' workflow files stay as they are.
- **A caller can decide for itself** by passing `matrix`; `release-c-lib.yml` hands its own `matrix` input on.
  `publish-fedora.yml` always passes `full`: a new Fedora release is filled whole.
- The quick set is cut down to the caller's own matrix and never adds to it. A caller whose own matrix holds no quick
  cell of a kind builds its full matrix of that kind and says so; a library built for x86_64 alone builds trixie amd64.

### What the channel records

The tree scripts write `cells.tsv` at the top of each tree (`rpm/cells.tsv`, `deb/cells.tsv`, and the same under
`staging/`), one line per package and version, tab separated:

```
# package	version	set	cells
omx-contract-devel	3.13.0	full	fc44/aarch64 fc44/x86_64 fc45/aarch64 fc45/x86_64
omx-contract-devel	3.14.0	quick	fc44/x86_64 fc45/x86_64
```

The cells are read from the files in the tree at every publish. The set is that of the run that published the
version; `-` marks a version published before sets were recorded. The file is page data, not signed, and nothing
installs from it: the channel page reads it to show which cells a version has.

### The final release

A version the channel has for the quick set alone is not a release: five cells cannot install it. Two things hold
the line.

- A release of the full matrix reads `cells.tsv` after its build has installed its dependencies, in every build job,
  and **refuses** when one of them is a version marked `quick`, naming it and its cells. The dependency is released
  for the full matrix first. A channel that serves no `cells.tsv` yet records no quick version and the check says so;
  a channel that cannot be read fails the run.
- A quick version becomes a full one by going out again for the full matrix: a new tag, or the same tag run again
  with `republish: true`, which keeps the files already published and adds the missing cells. Its line in `cells.tsv`
  then reads `full`.

The check sees what the build installed, so it covers build dependencies and whatever they pull in. A package that
is only a run-time dependency, never installed by the build, is not seen by it; the install check of the release is
what meets it.

`tests/release-matrix.sh` renders every row of the table above from the workflows as written, and runs `cells.sh`
and `quick-deps.sh` on trees of its own.

### Catching a served version up

A cell that joins the quick set (trixie amd64, 2026-11-13) has no build of the versions already tagged and served.
`republish` cannot fill it alone: it rebuilds every cell of the run, and its rebuilt arch-independent packages
(`all`, `noarch`) and source rpms carry other bytes under the names the channel serves. A **catch-up** fills only
what is missing:

```
gh workflow run release.yml -R Open-Mixer/<repository> --ref main \
  -f source-ref=v<version> -f publish=true -f catch-up=true
```

- **The plan.** The first job (`release-matrix`, `matrix.sh`) takes the set's cells as above, reads `<kind>/cells.tsv`
  from the channel repository (the API, not the Pages site, which lags a push), and leaves out every cell the tag's
  version already records for the release's packages (`binary-names`, or `package-name`). A package whose line records
  only `all` or `noarch` cells in a release serves that whole release and is not judged there. Nothing missing is
  green: the run says so and builds and publishes nothing. **Refused by name:** a version the channel does not serve
  (that is a release), a package of the release with no line at that version, a cell some packages serve and others
  lack, a staged run, and `republish` beside it.
- **The preflight** does not run the already-served check for a catch-up: the version is served by definition.
- **The publish** pulls the channel with its metadata. Before anything is placed, every file whose path the tree
  already holds is judged: an `all` deb, a `noarch` rpm or a source rpm is **dropped** from the publish, by path, and the
  log says `dropped ...`; any other file is **refused**, named, byte-identical or not, and nothing is placed or signed.
  Only the Debian releases (deb) or directories (rpm) that received a package get their index made and signed again;
  every other file of the channel keeps its bytes, the key file and repository file too unless a new key must be
  served. `cells.tsv` gains the new cell and keeps the version's set. The install check runs for the new cells only.

`tests/catch-up-plan.sh` (the plan, the refusals, the workflow wiring) and `tests/catch-up-publish.sh rpm|deb` (a
catch-up onto a fixture channel, served files byte-identical, an overwrite refused) run in CI, each with a sabotage
that goes red.

### An `all` package pinned by its source

A Debian suite of the channel is one flat index for every architecture: an `Architecture: all` deb is served to all of
them, and apt takes the newest version of each package as its candidate and never an older one to meet an exact
dependency. plugin-hostd 0.20.5 and 0.20.6 went out while the quick set's Debian cells were trixie arm64 alone; their
`plugin-hostd-contract` (all) became the candidate on amd64 too, where `plugin-hostd` 0.20.4 asks for
`plugin-hostd-contract (= 0.20.4)`, and `apt-get install plugin-hostd` failed there (Open-Mixer/.github#59).

So the deb publish (`publish-tree.sh`) **refuses**, before anything is placed or signed, an `all` package that becomes
its suite's newest while a package of the same source in the run pins it exactly (`= ${source:Version}`,
`= ${binary:Version}`) and the run does not build that package, at that version, for every architecture of the suite
that already serves it. The refusal names the `all` package, the suite, the pinning package and the architectures
left behind. Build them too (the full matrix, or a quick set that covers them). A catch-up is never refused by it: it
drops the served `all` package, so the missing architecture of such a release is filled as above. Rpm needs no such
rule: dnf takes an older `noarch` build to meet an exact dependency. `tests/arch-all-pin.sh` reproduces the case on a
fixture channel, with the passing arms (every architecture built, an older `all`, the catch-up) and a sabotage.

### Tests

`tests/staging-channel.sh` (the workflows rendered, the precheck as written, the repository files, the purge guard),
`tests/staging-publish.sh rpm|deb` (a staged publish, a client and the purge on a stub channel, in a Fedora or Debian
container), `tests/staging-bootstrap.sh rpm|deb` (the first staged run into a channel with no staging path, served
over HTTP, and the next one after a purge) and `tests/staging-installability.sh` (the gate's verdict with and without a staged minor) run in CI.

## openmixer-release, the package that adds the repository

A machine adds the channel by installing `openmixer-release`, as RPM Fusion's machines do with
`rpmfusion-free-release`: a change of baseurl, key or Debian release reaches every machine as an update of that
package. The packaging is `packaging/openmixer-release`; workflow `release-package.yml` builds it and
publishes it.

| | RPM | DEB |
| --- | --- | --- |
| repository | `/etc/yum.repos.d/openmixer.repo`, ids `openmixer` and `openmixer-noarch` | `/etc/apt/sources.list.d/openmixer.sources`, deb822, a link to the source of the system's `VERSION_CODENAME` |
| key | `/etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer`, the channel's `rpm/RPM-GPG-KEY-openmixer` | `/usr/share/keyrings/openmixer-archive-keyring.asc`, the channel's `deb/openmixer.asc` |
| stable name | `rpm/openmixer-release.noarch.rpm` | `deb/openmixer-release.deb` |
| updates from | `fedora/<release>/noarch/` of the tree | `debian/<suite>/all/` of the tree |

The DEB ships one source per Debian release the channel serves (bookworm, trixie) and links the one of the
running system at configure time: the stable `.deb` is one file for every release, and the sources stay
package contents, so an upgrade changes them. A system whose codename the channel does not serve fails the
install. A system upgraded to another Debian release relinks with `dpkg-reconfigure openmixer-release`.

The key is the file the channel serves at build time, read over HTTPS from `www.openmixer.org`, never kept in
this repository: a key added to the channel (channel-keys.sh) reaches machines by the next release of the
package. The channel is not the trust root for that file: `.github/actions/import-gpg-key/pinned-fingerprints.txt`
lists the primary fingerprints OpenMixer signs with (the release key of 2026-11-01, the release key before it that signed every package published until then, the first channel key, and the site key that
signs the channel commits), and every reader of a served key file (the publish actions, `channel-keys.sh`, this
build) refuses a file holding any other primary. A new signing key is therefore a reviewed commit to that list
first, then served by a publish. Its public half is also committed in `.github/actions/import-gpg-key/served-keys/`:
every publish serves it next to the keys the channel already served (the old public keys stay served, so installed
systems keep verifying), and the build of openmixer-release ships the served file plus those committed keys.

To release: bump `Release:` in the spec and add the same version on top of `debian/changelog` (build.sh
refuses a build where the two differ), merge, and push the tag `openmixer-release-<Version>-<Release>`, for
example `openmixer-release-1-2`. Without that tag the workflow is a dry run: both packages are built, each is
installed in a clean container with a package of the channel installed through the repository it adds
(`install-check.sh`), and the unsigned trees with the stable names are attached to the run. A release signs,
publishes into the tree and at the stable names, and checks from a clean fedora:44, bookworm and trixie that
the stable name carries the release and installs.

`add-openmixer` is the action the shared workflows use to add the channel to a build or install-check
container: it installs the stable name from `base-url`.
