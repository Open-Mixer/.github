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
already uninstallable before the release is reported as a warning. Exit 2 means the measurement could not be taken,
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
