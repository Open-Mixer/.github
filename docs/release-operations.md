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

## Artifact retention

The organisation's Actions artifact storage is a quota shared by every repository, so a pull-request or lane run must not
hold its artifacts for weeks. Every `upload-artifact` in these workflows sets `retention-days` explicitly, and always with
the one expression form

    retention-days: ${{ (startsWith(github.ref, 'refs/tags/') || <release condition>) && 30 || 2 }}

A release run keeps 30 days; every other run (pull request, lane, dry-run dispatch) keeps 2. The release condition is
the workflow's own sign that it publishes: `inputs.publish` (and `inputs.staged` in build-rpm.yml and build-deb.yml)
where the workflow has them, the tag push in promote-staged.yml, and the tag alone in release-package.yml. A
reusable workflow reads the caller's `github.ref`, so a caller changes nothing. A repository that calls these and
uploads its own artifacts uses the same form with its own release condition.

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

## Publish only by tagging

Nothing reaches the channel root (the Pages repository), npm or a GitHub release except from a tag push. A run by hand
(`workflow_dispatch`) may build and dry-run, never publish, and no workflow has a `publish` input to switch that on.
Re-running a failed tag run keeps its event `push`, so it still publishes.

The rule is decided by EXACT MATCH, never by evaluating an expression (`tests/publish-only-by-tag.sh`, run by ci.yml,
which proves itself first on planted trees: every way of publishing red, the allowed shapes green):

1. A job with a publishing step carries the job-level `if:` that is exactly
   `github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')` (whitespace and the `${{ }}` aside). An extra
   `||` or `&&`, `always()`, an input, or the condition on a step instead of the job is refused, by job name. A step
   publishes by what it does (`gh release`, `npm publish`, an upload, `curl -T`, a POST or PUT to a releases or uploads
   API, any `git push`, a `gh api` write, the channel push helper, or a composite action that contains one), not by its
   name. That is why a job that must also wait on the outcome of jobs that may be skipped has a gate job beside it
   (`publish-go`, `release-go`, `notify-go`) holding those conditions, and the publishing job needs the gate.
2. What is not publishing, by proof: a push whose `what` is a literal path under `staging/` (no expression, no `..`,
   no `//`): the stage builds and the purge of staging. By the owner's staged release cadence rule they feed the next
   layer and are not the release channel consumers install from. And a call of a composite action whose publishing
   steps carry one of the three canonical sign gates, when the caller gives it a literal `sign: 'false'` (the dry run,
   an unsigned tree) or `staging: 'true'` with the staging gate. Any expression where a literal is needed is not a
   proof and the job needs the exact tag condition.

So `build-rpm.yml` and `build-deb.yml` have `publish-release` (the tag condition alone, sign true, staging false), and
`publish`, which stages (`staged: true`, `staging: 'true'`) or assembles the unsigned tree (`sign: 'false'`). The package
workflows (surge-xt, pugl-nanovg, clap, rncbc-v1, mod-host-protocol), `release-package.yml` and `promote-staged.yml` have
a publishing job under the tag condition and a `-dry-run` job beside it under its negation. Limit: a script of the
repository itself (not of an action directory) that does the `git push` or the upload is invisible to the gate; the
shared workflows have none, and a caller repository's own scripts are not scanned (Open-Mixer/.github#132).

`publish-fedora.yml` and `publish-freereac.yml` are removed: they republished an existing tag by hand, which this
rule forbids. A new Fedora release gets the packages by re-running the tag run of each repository (in dependency
order, omx-contract first, since each build takes its BuildRequires from the channel's tree of its own Fedora
release), or by a new version tag. The preflight refuses a version the channel already serves, but only in the
trees the release publishes into, so a version served for fc44 does not block its first fc45 publish.

## The staging channel of a release wave

A release wave publishes inner layers before the outer ones build on them. Inside the wave, a layer does not wait
for the real channel: its staged run publishes to the staging channel, and the next layer builds, verifies and
install-tests against it. The real channel gets the whole set once, in the wave's release pass, from the `v<version>`
tags. The staging channel is per wave and is purged after the pass.

**RULED (owner, 2026-11-23, .github#233):** "the TESTING channel publishes only the
TESTED platforms — Fedora 45 x86_64 (the stage box's platform) and Zynthian (Debian trixie arm64) — as soon as their
tests pass; every other cell of the matrix goes to the real channel only when all tests pass (the tag release)." The
tested platforms are the quick set (`.github/actions/release-matrix/quick.txt`, "The quick set and the full matrix"),
written once there. So a staged run builds and publishes the quick set by default: `matrix.sh` refuses a staged run
whose caller's matrix holds no quick cell, and takes the quick set whatever `OMX_RELEASE_MATRIX` says. **Superseded for
promotion candidates (owner's build-once ruling, 2026-11-24; .github#273):** a staged run whose caller passes
`matrix: full` explicitly builds the full matrix, so the promotion finds every release and architecture it promotes
and its staging publish takes every architecture of the releases it built (`staged-cells.sh` reads the run's
`MATRIX_SET`; the deb skeleton adds the architectures built); the staging publish (`publish-rpms`, `publish-debs` with `staging: 'true'`) refuses a
package of a cell outside the run's set, and the staging deb tree's skeleton is the set's architectures. `tests/release-matrix.sh`
and `tests/staged-cells.sh` hold the guards, each sabotaged.

### A merge to devel publishes the real package to staging

**RULED (owner, 2026-11-25, .github#289):** development happens in devel. A merge to devel builds the RPMs and DEBs once
and publishes them to the staging channel at once, where the devel box (omx) and the staging box (omx2) install them.
Staging keeps testing, devel starts the next cycle at once, and promotion to the channel root later copies the same
files. The devel build is the real package at its real version, never a pre-release.

- **The trigger.** The caller's release workflow runs on `push: {branches: [devel]}` beside its tags. trigger-gate
  lets a push limited to tags, to `devel`, or to both through, and refuses any other branch filter.
- **What the build does.** build-rpm.yml and build-deb.yml treat a push to `refs/heads/devel` as a staged run. It
  builds against the staging channel and publishes to it, never to the channel root. It builds the full matrix, because
  promotion copies this one build to every cell.
- **The version.** It builds the tree's own version with no tag and no snapshot suffix: `build-rpm.sh -r` and
  `build-deb.sh -r` give `<name>-<version>-<release>.fcNN` and `<name>_<version>`, the NEVRA a release of that version
  has. A dispatched staged run keeps its `+git` snapshot.
- **A version is built once.** The preflight reads the version with the packaging tool (`tree-version`: `rpmspec -q
  --srpm --qf '%{VERSION}'` of the spec, macros expanded, or `dpkg-parsechangelog -S Version` without the Debian
  revision). When the channel root or staging (of that kind) holds it already, the merge publishes NOTHING and stays
  green: `release-preflight`'s `devel-version` runs `already-served.sh` with `STAGING=true ON_SERVED=notice`, a
  `::notice::` names the served version and files, the output `skip` is `true`, and the build, publish and verify
  jobs skip on it. No published version is rebuilt, and no epoch is used.
- **The missing bump is red on the pull request.** A pull request into devel that changes any path outside
  `bump-exempt` (default `docs/** **/*.md .github/**`; a glob starting `**/` matches at the top too) while its head
  version is published already, in the channel root or staging, is refused by `devel-bump-check`, naming every changed
  path and the served file. So a merge to devel that changes a package carries its version bump, and a fix after a
  published build is a new version. The channel is public: that check reads its tree with the run's own
  `github.token`, never `PAGES_TOKEN`.
- **A snapshot of a published version is retired.** A dispatched staged run (`staged: true`, not a merge to devel)
  still builds a `+git` snapshot of the tree's version, but the preflight reads that version (`staged-version`) and
  refuses it when the channel root or staging holds a REAL build of it (`already-served.sh` with `STAGING=true
  REAL_ONLY=true`: a name carrying `.git`, `+git` or `~git` is a snapshot and does not count), naming the file. Bump
  the version on devel instead.
- **The install check** takes the staged package of exactly that version.
- **A file the channel holds is refused, never kept.** The staging publish of a merge to devel passes `refuse-served`
  to `publish-rpms` and `publish-debs` (`REFUSE_SERVED=true` for `publish-tree.sh`): every package whose file the tree
  already holds (the same file name; for a deb, in the same suite) is named and refuses the run before anything is
  placed or signed. A release keeps a served file and says `kept`; a merge to devel has built its version once, so a
  second build of it is an error, not a no-op.
- **One publish per repository and kind at a time.** The publish job of a merge to devel runs in the concurrency group
  `devel-publish-<owner>/<repo>-rpm` (or `-deb`) with `cancel-in-progress: false`, not in the channel's `live` group:
  another repository's release never waits behind it, and `channel-push` repeats a push that lost a race on the new
  tip. GitHub keeps at most one run RUNNING and one PENDING per group: when a third merge to the same repository
  arrives while one publishes and one waits, the waiting one is cancelled and the newest takes its place. The
  cancelled merge's version is then not staged; it was superseded by a newer version (each merge that changes a
  package carries its own bump), and if that version must be staged anyway, rerun the cancelled run's failed jobs.
- **Promotion copies it, from the commit that built it.** The real package's name holds no commit, so the staging
  publish of the merge to devel records the full commit beside it: `staging/<kind>/built/<name>/<version>.commit`
  (`built-commit` of `publish-rpms` and `publish-debs`, `record-built.sh`; a record naming another commit is
  refused). `promote-staged`'s find job reads it for every kind it promotes (one record missing, or two naming
  different commits, is refused) and promotes the real build only when the promotion's commit (the tag's, or the dry
  run's input) carries the same version in its spec and changelog (`tree-version`) AND is that commit or descends from
  it (`git merge-base --is-ancestor`). It then asks `collect.py` for `--commit real`, which no commit sha selects, and
  the install checks require that real version (no `.git`, no `+git`). Promotion copies its bytes, checked checksum
  for checksum.
- **Tests.**
  - `tests/devel-push-staging.sh`: the workflow conditions for each kind of run, the version read, the refusal of a
    served file, the skip and the pull request's bump check, the promotion's checksums, its tie to the devel commit and
    its install checks, and trigger-gate.
  - `tests/build-devel-real.sh`: the real NEVRA (Fedora container).
  - `tests/devel-pr-staged-install.sh`: the next layer takes the staged build.

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
  `build-rpm.yml` and `build-deb.yml` build the quick set (fc45 on x86_64, trixie on arm64), the tested platforms and
  never more (the ruling above), against the staging channel,
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
and verified against is what ships. A repository calls it from a `promote.yml` of its own (triggered by the push of the tag `v<version>`, with
`contents: write`; the header of `promote-staged.yml` has the caller). The version is the tag's and the commit is the
one the tag is on; a dispatch of the caller is a dry run that takes `version` and `commit` as inputs.

1. **Find.** The staging tree must hold the build of that one commit for every Fedora release, Debian suite and
   architecture of the matrix, with its source package, and must cover every release the channel root serves the
   package for. The commit must be on the default branch.
   A staged build of the quick set does not hold every cell, so it is refused here by name. Since a staged run
   holds the quick set alone (the ruling above), a version whose matrix is wider is released from its tag.
2. **Check.** Every RPM carries a good signature by a key the channel serves; every DEB is listed with its SHA256 in
   the signed staging index of its suite. Nothing is signed by a promotion.
3. **Publish.** The files go to `rpm/` and `deb/` through `publish-rpms` and `publish-debs`, in the publish group of
   the channel; the metadata is regenerated and signed, the packages are placed as they are, and the tree is compared
   with the staged checksums before the push is trusted.
4. **Prove.** Every promoted file is fetched from the served channel and its SHA256 compared with the staged one
   (`same bytes <sha256> <path>` lines in the run log), then the version installs from the channel root alone in a
   clean container of every release and architecture.
5. **Release.** Only then: the GitHub release of the tag that started the run, with the promoted files. The workflow
   never creates the tag.

Any refusal in 1 or 2 leaves the channel as it was. A run that is not a tag push stops after assembling an unsigned tree: nothing
is pushed or released. A promoted package keeps the version string of its staged build
(`<version>-<release>.git<commit time>.<sha>`, `<version>+git<commit time>.<sha>`), because its bytes are the same. The staged copies stay under
`staging/` until the purge. `tests/promote-staged.sh` and `tests/promote-publish.sh` hold the proofs.

### A build-dependency cycle: the bootstrap input

Two libraries of a wave can need each other's packages to build (plugin-hostd-protocol needs omx-clap-contract, while
omx-clap-core, which builds that package, needs plugin-hostd-protocol; Open-Mixer/.github#230). No order satisfies both. A
stage-box chain line breaks such a cycle with `bootstrap=`. `build-rpm.yml` and `build-deb.yml` break it with the
`bootstrap` input, the same mechanism: entries `<owner>/<repo>@<full commit>:<package>`. Each entry is one `-contract`
data package of the later library, built alone from its source at that commit (`actions/contract-bootstrap`:
`make install-contract`, packed as the library's packaging declares it). On Debian that is the library's own snapshot
build of the package, file for file: only the files its `debian/<package>.install` names, the directories its `.dirs`
names, and the changelog as `build-deb.sh` renders it (`render-changelog.sh`), so the library's build of the same commit
and the bootstrap never differ in a path or a byte (#240). The build job builds it before the
library's own build and installs it in the container, so it meets the build's dependencies. It is never released;
the library's own release replaces it. The entry must name the commit itself: a short sha, a ref, or an annotated
tag's object (whose checkout is another commit) is refused before anything is built.

When the consumer has to be **released** before the library, the build container is not enough: the channel must
serve the package. `bootstrap-only` makes the one bootstrap package the release of the run, with every gate of a
release (the preflight and its already-served check, channel-installability, the signed publish, the install check),
and checks out nothing of the calling repository. Its version is the house snapshot form, below the library's own
release of the same version and above a consumer's floor: rpm `<version>-0.git<commit time>.<short sha>%{?dist}`, deb
`<version>~git<commit time>.<short sha>`. The library's release of `<version>` supersedes it, and the channel's
`cells.tsv` records it under `<version>` (`served.sh <package> <version>` answers for it).

`contract-bootstrap.yml` is the caller, here and not in either library. A release publishes only on a tag push of its
caller; the library's `v<version>` tag is its full release; and the consumer's release workflow is the one its own
head carries. The caller reads one line of `.github/contract-bootstraps.txt` (`<package> <version>
<owner>/<repo>@<full commit>`):

- a push of the tag `bootstrap-<package>-<version>` on a commit of main releases that line;
- `gh workflow run contract-bootstrap.yml -f package=<package>` is a dry run of the same line and publishes nothing.

A line goes when the library's own release of its version is served. `tests/contract-bootstrap.sh static|rpm|deb`
holds the wiring, the line reader, the package, both version bounds and the commit refusals, each with its sabotage;
its deb arm also builds the fixture library with `build-deb.sh` and holds the two packages equal in every path and byte.

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

A release builds four cells: Fedora 45 on x86_64 and aarch64, Debian trixie on amd64 and arm64. No release is built
for Debian bookworm (owner ruling 2026-11-16); what is already published for it stays served. Fedora 44 is no longer built, judged or installed in CI (owner ruling 2026-11-19: every machine is on Fedora 45); the fc44 trees stay served as they are, and nothing there is pruned without a separate decision. `.github/actions/release-matrix/frozen.txt` lists each such release (`rpm 44`, `deb bookworm`): a promotion does not hold it against its matrix, so the frozen tree is left as it is and the promotion covers the built releases. The noarch view check of a publish (publish-rpms/noarch-views.py) does not judge a frozen release either: nothing builds there, so no run could mend a difference left in it.
While a release wave is open the next layer needs only enough of a version to go on, so a run can build the **quick
set** instead:

| kind | cells |
|------|-------|
| rpm  | fc45 x86_64 |
| deb  | trixie arm64 |

The quick set is the development set: two cells, fc45 x86_64 and trixie arm64 (Debian packages ship for Zynthian, the Pi, alone). The full set (fc45 x86_64 and aarch64, trixie amd64 and arm64) returns at the end of development: one switch, `OMX_RELEASE_MATRIX=full`, no edit anywhere else; the served amd64 trees stay as they are meanwhile.

trixie amd64 joined the set on 2026-11-13 and left it on 2026-11-19 (Debian packages ship for Zynthian alone): the amd64 CI runners (zynthian-ui, omx-plugins' Debian packages) install
from the deb channel, and with no quick amd64 cell every one of their runs failed on a version the wave had not
built there.

The set is written once, in `.github/actions/release-matrix/quick.txt`. `build-rpm.yml` and `build-deb.yml` ask the
`release-matrix` action in their first job, and the build jobs and the install checks both run for the cells it
names, no others. The run says which set it builds, and why, in a notice.

### Which set a run builds

| run | `matrix` input | `OMX_RELEASE_MATRIX` unset | `quick` | `full` |
|-----|----------------|----------------------------|---------|--------|
| any | `quick` or `full` | the input | the input | the input |
| a tag, or `source-ref` | empty | **full** | quick | full |
| `staged: true` | empty or `quick` | **quick** | quick | quick |
| `workflow_dispatch`, not a tag | empty | **quick** | quick | full |
| a pull request, a push to a branch | empty | full | full | full |

- **A caller that changes nothing** passes no `matrix`. Its tag push builds the full matrix, as it always did,
  unless the organisation variable `OMX_RELEASE_MATRIX` is `quick`. The default is full on purpose: a tag pushed by
  hand with no wave open must never publish four cells of eight because nobody said otherwise.
- **`OMX_RELEASE_MATRIX`** is the one thing the release chain sets: `quick` when it opens a wave, `full` (or
  removed) before the final release of each repository. It is an organisation variable because a tag push carries no
  inputs, and the callers' workflow files stay as they are.
- **A caller can decide for itself** by passing `matrix`; `release-c-lib.yml` hands its own `matrix` input on.
- **A staged run is the quick set, always** (the tested platforms, "The staging channel of a release wave"): a
  `matrix: full` input is refused, `OMX_RELEASE_MATRIX=full` does not widen it, and a caller whose releases hold no
  quick cell of a kind is refused rather than given its full matrix.
- The quick set wins: a caller's architectures only narrow it within the set, and when they leave no cell (an
  amd64-only caller while the set is trixie arm64) the run builds the set's own cell, never the caller's full matrix. Only
  a caller whose releases hold no quick cell of a kind builds its full matrix of that kind and says so (a staged run
  is refused instead).

### Checks follow the set

A check outside the release workflows (a full-stack install check after the publish, like plugin-hostd's
`plugin-hostd-full`, or a repository's ordinary CI matrix of containers) covers the cells the set builds and no others
(ruling D25): while `OMX_RELEASE_MATRIX` is `quick` only the quick cells, and `full` (or the variable unset) adds the
rest. A cell the channel does not serve for the wave is skipped by reading the variable, never deleted from
the workflow, and comes back with `full`. Without this a check can only fail on a cell the set never built, every quick
release ends red, and a real failure no longer stands out (Open-Mixer/.github#59).

The `check-matrix` action renders such a matrix. The caller writes its whole matrix once; the action reads
`quick.txt` through `release-matrix`'s `matrix.sh`, so the quick set is still written in one place:

```yaml
  checks:
    runs-on: ubuntu-latest
    outputs:
      deb: ${{ steps.m.outputs.deb }}
      deb-count: ${{ steps.m.outputs.deb-count }}
    steps:
      - id: m
        uses: Open-Mixer/.github/.github/actions/check-matrix@openmixer-v1
        with:
          wave: ${{ vars.OMX_RELEASE_MATRIX }}
          deb-releases: '["trixie"]'
          deb-arches: '["amd64", "arm64"]'

  full-deb:
    needs: [deb, checks]
    if: needs.checks.outputs.deb-count != '0'
    runs-on: ${{ matrix.cell.runner }}
    container:
      image: ${{ matrix.cell.image }}
    strategy:
      matrix:
        cell: ${{ fromJSON(needs.checks.outputs.deb) }}
        mode: [default, headless]
```

Each cell carries its container image and the runner of its own architecture (`{"suite": "trixie", "arch": "arm64",
"image": "debian:trixie", "runner": "ubuntu-24.04-arm"}`). The inputs name the split: `arm-arches` (default `aarch64
arm64`) and `arm-runner` (default `ubuntu-24.04-arm`) for a cell that needs the ARM runner, `x86-runner` (default
`ubuntu-latest`) for every other cell; no architecture is written in the script. A caller with its own pool passes the
expression its x86 jobs already use (`x86-runner: ${{ vars.OMX_RUNNER || 'ubuntu-latest' }}`), so `runs-on: ${{
matrix.cell.runner }}` keeps the runner those jobs had. The development set's debs are trixie arm64 only, and an amd64
container resolves an arm64 `-dev` package that dpkg then refuses (omx-panel ci 44563540081). `build-deb.yml` already
sends its arm64 build and install-check cells to `ubuntu-24.04-arm`, and `build-rpm.yml` and `clap-headers-deb.yml` do
not read check-matrix, so their runner expressions are untouched. `images` is
the list of images alone, for a CI job that runs on the runner's own architecture. Unlike a release, a kind whose
matrix holds no quick cell renders no cell while `quick` (count 0, the job is skipped), never its full matrix. The
notice names the cells skipped. The cell is a matrix dimension of its own (`matrix.cell`), not an `include`: `include`
rows beside another dimension (`mode`) overwrite each other's added keys. `tests/check-matrix.sh` renders quick and
full for plugin-hostd's checks and for a CI image list, with two sabotages.

The install checks of `build-rpm.yml` and `build-deb.yml` already take their cells from the release's own first job.

#### Every workflow takes its cells from the one list

No workflow of this repository writes a cell list of its own; `tests/no-hardcoded-cells.sh` fails when one does. Each
declares its whole matrix once, as the `releases` and `arches` it hands to a plan job, and every job below takes its
cells from that job's output. A build and a publish use `release-matrix` (its `cells` feed `strategy.matrix.include`);
a check uses `check-matrix` (its `images`, or `cells`). Both name what they skipped while the wave is quick.

| Workflow | Primitive | Quick | Full |
| --- | --- | --- | --- |
| `pugl-nanovg-deb.yml`, `mod-host-protocol-deb.yml`, `surge-xt-deb.yml` | `release-matrix` (a build and a publish) | trixie arm64 | trixie, amd64 and arm64 |
| `pugl-nanovg-rpm.yml`, `surge-xt-rpm.yml` | `release-matrix` | fc45 x86_64 | fc45, x86_64 and aarch64 |
| `mod-host-protocol-rpm.yml`, `clap-rpm.yml` | `release-matrix` | fc45 x86_64 | fc45, x86_64 and aarch64 |
| `clap-headers-deb.yml` | `release-matrix`, arch `amd64` standing for an `Architecture: all` package | trixie | trixie |
| `release-package.yml` build, install check, layout | `release-matrix`, `Architecture: all` as above; the oldest release of the set builds it | trixie | trixie |
| `release-package.yml` install check from the channel | `check-matrix` (a check, after the publish) | fedora:45, debian:trixie | the same |
| `ci.yml` language packs | `check-matrix` (an ordinary CI image list) | fedora:45, debian:trixie | the same |

A build run by hand (`workflow_dispatch`) takes a `matrix` input (`quick`, `full`, or empty: the variable, and the quick
set without it); `clap-rpm.yml` is dispatch-only and no longer runs on a pull request, by the rule no heavy Action on a push or pull request, tags and dispatch only, plus one named lint (the check of a change to its spec, pins or file is a dry-run dispatch of it). The one-cell jobs of `ci.yml` (key transition,
staging, channel installability) are toolchain arms on an image the quick set always builds, and the test holds each to
the set. What stays literal, each with its reason, is the `ALLOW` list of the test: the whole matrices the reusable
workflows declare as input defaults, all handed to
`release-matrix`. `promote-staged.yml` is left whole on purpose: it promotes the whole matrix (its collect step refuses
a staged tree that lacks any cell), so its install checks cover what it promotes.

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
what is missing.

A catch-up used to be started by hand: `gh workflow run release.yml ... -f source-ref=v<version> -f publish=true
-f catch-up=true`. **That recipe is retired** by "Publish only by tagging": a dispatch publishes nothing, and a re-run of
a tag run repeats the inputs of the tag push, which carry no `catch-up`. A catch-up can be a dry run by dispatch (the
plan and the assembled tree are the proof), and the publish of a missing cell waits for a design that is a tag push
(the open question is which tag; until then a new version tag fills the cell). The plan, the refusals and the
publish rules below are unchanged and still tested.

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
left behind. The pinners are those of the run and also those the suite already serves: the newest served arch package of
the same source whose `Depends` holds the all package's current version exactly (read from the pulled tree's `.deb`
files) is left behind on every architecture the run builds no such package for, so an all package published alone is
refused too (Open-Mixer/.github#61, `tests/arch-all-served-pin.sh`). Build them too (the full matrix, or a quick set that covers them). A catch-up is never refused by it: it
drops the served `all` package, so the missing architecture of such a release is filled as above. The rpm
publish has the same refusal for a `noarch` package (Open-Mixer/.github#62; omx-clap-libs 0.32.4 on fc44, where
aarch64 serves 0.32.3 binaries that require `omx-clap-contract = 0.32.3-1.fc44` and the quick set built x86_64
alone): it is judged against the Fedora release (`fedora/<release>/noarch`), the pin is `Requires: name =
%{version}-%{release}` of a package of the same source rpm in the run, and the refusal names the `noarch` package, the
release, the pinning package and the architectures built and left behind, and ends `nothing was placed or signed`.
dnf itself still meets the exact pin with the older `noarch` build (measured on fedora:44, dnf5, aarch64 view of a
tree holding 0.32.3 and 0.32.4 of the contract: it installs omx-clap-libs 0.32.3 with contract 0.32.3), so the
refusal does not guard against an uninstallable binary: it keeps the channel's newest `noarch` build from being
one no served architecture's binary matches, which the release gate's newest-only check reads as red. `tests/arch-all-pin.sh`
(deb), `tests/arch-all-served-pin.sh` (deb, served pinners) and `tests/noarch-pin.sh` (rpm) reproduce the case on a fixture channel, with the passing arms (every
architecture built, an older package, the catch-up, a package nothing pins exactly) and a sabotage.

The guard judges only the architectures the release matrix publishes (Open-Mixer/.github#135). It reads them from
`release-matrix/matrix.sh`, the script the releases take their cells from: `MATRIX_SET` when the run has one, else the
organisation variable `OMX_RELEASE_MATRIX` (a regeneration such as the prune of the channel repository has no
`MATRIX_SET` and passes the variable through; without it the matrix is full and every architecture is judged). While the
matrix is quick no aarch64 rpm is published, so a quick release's noarch packages in the x86_64 trees are not refused
for aarch64; a skew inside a published architecture stays refused, an empty set is refused by name, and no kept package
is relabelled in `cells.tsv`. `tests/noarch-pin-matrix-arches.sh` proves each arm, with the architecture filter as its sabotage.

### A quick release writes the quick trees alone

While the set is `quick` the platforms are the quick cells and nothing else: every other tree keeps what it serves
until the full matrix publishes. A quick release never builds an aarch64 rpm, so its `noarch` package must not reach an
aarch64 machine: in `fedora/<release>/noarch`, which dnf reads on every architecture, it did (omx-dsp-contract 0.32.1
needs omx-dsp-devel 0.32.1, which no aarch64 tree served, and the aarch64 cells refused it). So, with `MATRIX_SET=quick`:

- `publish-rpms` places a `noarch` package that NEEDS an architecture in `fedora/<release>/<arch>` for each
  architecture `quick.txt` names for its release (`x86_64` for fc45); a release with no quick rpm cell is refused. A
  repository directory serves a `noarch` package like any other, and dnf takes the newest of the two directories. A
  `noarch` package needs an architecture when its `Requires`, followed through the packages of the run built from the
  same source rpm, reach an arch package (omx-dsp-contract -> omx-dsp-devel), or when an arch package of that source pins
  it exactly (`= %{version}-%{release}`) and some architecture tree of the release serves that package and the run did
  not build it there (omx-clap-libs -> omx-clap-contract, the #62 case).
- **Every other `noarch` package goes into `fedora/<release>/noarch`, served to every architecture** (Open-Mixer/.github#267).
  Placing every `noarch` package in the quick trees starved aarch64 of packages that need nothing of it: from omx-contract
  3.20.0 on, `omx-contract-devel` (which requires only `omx-contract-data`, noarch, same source) went into
  `fedora/45/x86_64` alone, the aarch64 view (`fedora/45/aarch64` + `fedora/45/noarch`) kept serving 3.19.1, and an
  aarch64 build needing `omx-contract-devel >= 3.21.0` found no match (run 45459465038, job 138685304544, against
  x86_64's job 138685304854 which installed 3.21.0).
- **A publish never leaves the newest build of a `noarch` package different across the architecture views.** After
  placing, `publish-tree.sh` reads every architecture view of the release (`fedora/<release>/<arch>` with
  `fedora/<release>/noarch`, for each architecture directory the release holds) and, for every `noarch` package name the
  run published, compares the newest build each view serves. A difference is refused, naming the package, the release and
  each view's newest version, unless the newest build needs an architecture as above, judged on the tree (its own
  architecture tree and `noarch`, the same source rpm), or the lower view's tree serves an arch package pinning the older
  build exactly. A refused run pushes nothing. `noarch-views.py report <tree>` lists the same differences for the whole
  channel. An
  `all` deb needs nothing new: a quick release builds only the quick set's suites, and each of them is a quick cell on
  every architecture it serves.
- `channel-installability` judges the quick cells alone (`--cell RELEASE/ARCH`, filled from `quick.txt` by `run.sh`
  when `MATRIX_SET` is `quick`) and names every other cell "outside the cells of the set, not judged". The publish
  actions set `MATRIX_SET`; the reusable `channel-installability.yml` passes `OMX_RELEASE_MATRIX`.

`tests/channel-installability.sh rpm_quick` replays the omx-dsp case on a fixture channel: the check of the quick release
is green and leaves aarch64 out, the contract lands in the `x86_64` trees alone, the `aarch64` and `noarch` trees hold
what they served, and a machine of each architecture still installs everything it is served.

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
| repository | `/etc/yum.repos.d/openmixer.repo`, ids `openmixer` and `openmixer-noarch`; `openmixer-testing` and `openmixer-testing-noarch` (the staging channel, disabled, as Fedora's updates-testing) | `/etc/apt/sources.list.d/openmixer.sources`, deb822, a link to the source of the system's `VERSION_CODENAME`; `/etc/apt/sources.list.d/openmixer-testing.sources` (the staging channel, trixie, `Enabled: no`, as the RPM's `openmixer-testing`) |
| key | `/etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer`, the channel's `rpm/RPM-GPG-KEY-openmixer` | `/usr/share/keyrings/openmixer-archive-keyring.asc`, the channel's `deb/openmixer.asc` |
| stable name | `rpm/openmixer-release.noarch.rpm` (the oldest Fedora release's build; noarch installs on every release) | `deb/openmixer-release.deb` |
| updates from | `fedora/<release>/noarch/` of the tree: one build per Fedora release of the set, since the dist tag `.fcNN` ties a build to its release | `debian/<suite>/all/` of the tree |

The DEB ships one source per Debian release the channel serves (bookworm, trixie) and links the one of the
running system at configure time: the stable `.deb` is one file for every release, and the sources stay
package contents, so an upgrade changes them. A system whose codename the channel does not serve fails the
install. A system upgraded to another Debian release relinks with `dpkg-reconfigure openmixer-release`.

### The testing repositories

openmixer-release installs the staging channel of the release wave as a testing repository, present and disabled, as
`fedora-repos` installs updates-testing: what a wave has proved, before its release tag publishes it. Turning it on is
the tester's whole opt-in, and turning it off returns the machine to the real channel at the next upgrade (apt and dnf do
not downgrade what is installed).

| | RPM | DEB |
| --- | --- | --- |
| file | `openmixer-testing`, `openmixer-testing-noarch` in `/etc/yum.repos.d/openmixer.repo` (`%config(noreplace)`) | `/etc/apt/sources.list.d/openmixer-testing.sources`, a file postinst writes from `/usr/share/openmixer-release/testing/openmixer-testing-<suite>.sources` |
| tree | `staging/rpm/fedora/$releasever/`: fc45 x86_64 and noarch, the tested platform | `staging/deb/debian/trixie/`: arm64 and all, the tested platform (Zynthian, the Pi); an amd64 machine finds only the `all` packages there, and bookworm gets no testing source |
| on, once | `dnf --enablerepo=openmixer-testing --enablerepo=openmixer-testing-noarch upgrade` | none: apt has no per-command switch |
| on | `dnf config-manager setopt openmixer-testing.enabled=1 openmixer-testing-noarch.enabled=1` | `sed -i 's/^Enabled: no$/Enabled: yes/' /etc/apt/sources.list.d/openmixer-testing.sources && apt-get update` |
| off | the same with `enabled=0` | `sed -i 's/^Enabled: yes$/Enabled: no/' /etc/apt/sources.list.d/openmixer-testing.sources && apt-get update` |

An upgrade of openmixer-release keeps the choice: the RPM file is not replaced, and the DEB's postinst rewrites the
source from the package's copy (so a new URI or key arrives with the upgrade) and keeps its `Enabled` line, `yes` only
when it read exactly `Enabled: yes`. Removing the package removes the testing source with the real one.

No priority and no apt pin: enabled, the newer build wins, as with updates-testing. The staged versions sort above the
release of the same version (`+git<commit time>.<sha>`, `.git<commit time>.<sha>`), so a staged build is taken without
a pin, and the released build of a later version is taken over it as soon as the real channel serves it. A pin above
500 would hold a tester on a staged build after the real channel moved past it; a disabled deb822 source is not read at
all, so it cannot win whatever the pins say. The `Pin-Priority: 600` of `openmixer-staging.pref` is the CI's
(`add-staging.sh`, "The files a machine adds"), where a build must take the staged dependency even over a higher
released one. A machine has one or the other: the testing source and `openmixer-staging.sources` name the same tree, so
both enabled is the same source twice.

`install-check.sh` refuses a machine where a testing repository is missing or enabled; on Debian it also enables the
testing source once, requires its signed index to load with the shipped key and no warning, and requires apt to read
nothing from it once disabled again.

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
publishes into the tree and at the stable names, checks from a clean container of every cell of the set (check-matrix)
that the stable name carries the release and installs, and last runs `served-check.sh`: every Fedora release of the
set serves the package in its own noarch tree (fc45 served the fc44 build at the stable name and never an update
until 1-5, 2026-11-15; the rpm job builds one RPM per release of the set since).

`add-openmixer` is the action the shared workflows use to add the channel to a build or install-check
container: it installs the stable name from `base-url`.

## A channel that is not OpenMixer's (FreeREAC)

`build-rpm.yml` and `build-deb.yml` publish into the channel named by `target-repo` and `base-url`. The key and the
repository file are inputs too, and default to OpenMixer's, so a caller that passes none changes nothing:

| input | default | FreeREAC passes |
| --- | --- | --- |
| `target-repo`, `base-url` | `Open-Mixer/open-mixer.github.io`, `https://www.openmixer.org` | `FreeREAC/freereac.github.io`, `https://freereac.github.io` |
| `key-file` | `RPM-GPG-KEY-openmixer` / `openmixer.asc` | `RPM-GPG-KEY-freereac` / `freereac.asc` |
| `committed-keys` | `true` | `false`: OpenMixer's committed keys are never served by another channel |
| `signing-fingerprint` | none | the channel's one key: a secret mapped to another key refuses the run before anything is signed |
| `repo-file` (rpm) | `packaging/openmixer-release/openmixer.repo` | `packaging/freereac-release/freereac.repo` |
| `label` (deb) | `OpenMixer` | `FreeREAC` |

The signing key and its passphrase reach the workflow under the declared secret names; the caller maps its own secrets onto
them (`OPENMIXER_PACKAGES_SIGNING_KEY: ${{ secrets.RPM_GPG_KEY }}`, `PACKAGES_SIGNING_PASSPHRASE: ${{ secrets.RPM_GPG_PASSPHRASE }}`).
A channel serves exactly one key and the two channels share none. `tests/channel-profile.sh` publishes through both profiles.

The two channels are independent (owner ruling 2026-11-23, .github#224): neither serves a package of the other,
openmixer-release requires nothing FreeREAC's channel serves (1-10), `add-openmixer` installs one channel's release
package per call, and the installability gate reads no channel but the one it judges. A job that needs both adds each;
a REAC rig adds FreeREAC's repository (`freereac-release`) for reac-pw.

The tree scripts refuse the crossing (`publish-rpms/channel-owner.sh`, `tests/channel-owner.sh`): a run of one house
organisation publishing into the other's channel, or a package whose URL (rpm) or Homepage (deb) names one
(`github.com/FreeREAC/`, `freereac.github.io`; `github.com/Open-Mixer/`, `openmixer.org`) going into the other's, is
refused before anything is placed. FreeREAC's packages had reached this channel two ways: FreeREAC release.yml files that
named no `target-repo` (libreac and reac-pw until 2026-11-18) took the default, `Open-Mixer/open-mixer.github.io`, and a
republish workflow of this repository (publish-freereac.yml, removed) built libreac 1.11.0 and reac-stageboxes 0.1.0 for
it; the freereac-release mirror (removed) was the third.

### Taking FreeREAC's packages out of the channel

The channel's prune cannot drop them: openmixer-release 1-9, still served, requires freereac-release.
`remove-freereac-packages.yml` does, and removes nothing else: `tools/remove-freereac-packages.sh` takes out the files whose
own header names a FreeREAC source (freereac-release, libreac, reac-pw, reac-stageboxes, a constant) and FreeREAC as home,
and only where FreeREAC's channel serves the same package at the same version or newer for the cell; every other one is
kept and printed as a gap. It makes the metadata again with the publish's tree scripts, signs it, and refuses any other
change (`tests/remove-freereac-packages.sh`). Once openmixer-release 1-10 is published, the tag runs it, from main (a
dispatch is a dry run):

```
git tag -s -m 'remove-freereac-packages-1' remove-freereac-packages-1 origin/main
git push origin remove-freereac-packages-1
```

A dry run on 2026-11-23 removed 33 rpm and 11 deb files and kept 22 for gaps: the fc44/fc45 source rpms (FreeREAC's
channel serves no SRPMS) and every bookworm deb (it serves no bookworm). Those stay until FreeREAC serves them or the owner
rules them dropped; a second tag then removes them. openmixer-release 1-9 is left uninstallable from this channel alone,
which dnf and apt never offer while 1-10 is the newest. The workflow, the script and the test are deleted once nothing is
left to remove.
