<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# Package descriptions and changelogs

Every OpenMixer package has a description that says what it does for a musician or an engineer, and a
changelog that the person updating it sees. This page is how that works for every repository that ships an
RPM or a deb through the workflows of this repository.

## What a user sees

| Where | What |
| --- | --- |
| `dnf info <package>` / `apt show <package>` | the Summary and %description / the Description |
| `dnf updateinfo info` | one advisory per release, with the release's changelog text and a link to its release notes |
| `dnf check-update --changelogs` | the changelog entries of the versions an update brings |
| `apt changelog <package>` | the changelog of the version about to be installed, or of the installed one |
| `apt-listchanges` (when installed) | the changelog of each deb it is about to upgrade, read from the deb itself |
| GitHub release page | the commit subjects since the previous tag |

## One source: git history

No changelog file is kept by hand. The changelog of a release is the commit subjects between the previous
tag and the release tag, merge commits left out, so a commit subject is written for the person updating:
what they can do now, what no longer breaks. `.github/actions/changelog/changelog.sh` makes everything
else from the history (the checkout needs its tags and history: `fetch-depth: 0`):

| Command | Output |
| --- | --- |
| `changelog.sh notes [<ref>]` | the GitHub release notes, `- <subject>` per commit |
| `changelog.sh rpm [<ref>] <version-release>` | the one `%changelog` entry of a spec |
| `changelog.sh deb [<ref>]` | rewrites the top entry of `debian/changelog` from the same commits |

Every generated line is also judged by the patterns of `.github/actions/commit-message-check/commit-message-patterns.json`
(read as data, the same list the commit-message check uses): a line a pattern names is dropped before it reaches the
notes, the `%changelog` or `debian/changelog`, and `release notes: N lines dropped by the message patterns` is logged.
An unreadable list stops the run.

The version is the package's own: the spec's `Version` and `Release`, the top entry's version of
`debian/changelog`. The spec keeps a `%changelog` heading (the build replaces what follows it) and the tree
keeps a `debian/changelog` with one entry for the version (the build replaces its body), because the package
formats require them. The author of the entries is `$CHANGELOG_AUTHOR` (Pau Aliagas by default); the dates
are the date of the release commit.

A release is: bump the version files, tag `v<version>`. The `changelog` action, `mode: notes`, writes the
notes of a tag to a file; `mode: check` no longer exists and fails.

## Where the shared workflows use it

`build-rpm.sh` and `build-deb.sh` check that the tag is `v<version>` of the package and the tree is the tag's
commit, then generate the changelog from git before building. The release jobs of `build-rpm.yml` and
`build-deb.yml` check out with full history and create the GitHub release with the notes from git. The
`changelog-spec` input of both workflows is ignored and kept so existing callers still validate.

## The channel's update metadata

RPM: `publish-rpms/publish-tree.sh` writes an `updateinfo.xml` for every directory that holds binary
packages and merges it into the repository metadata with `modifyrepo_c`, before the metadata is signed.
`updateinfo.py` makes it from the packages themselves: one advisory per source RPM, whose text is the
package's newest `%changelog` entry (the entry named after the package's own version and release). The
channel keeps no extra state, so every publish rewrites the advisories of every release the directory holds
and releases published earlier get theirs. The first release of a package is a `newpackage` advisory, the
others `enhancement`.

deb: `debhelper` puts `debian/changelog` into each package, as `changelog.Debian.gz` (`changelog.gz` for a
native package, which the OpenMixer packages are); that is what `apt-listchanges` and `apt changelog` for
an installed package read, and what lintian requires. `apt changelog` for a version that is not installed
yet asks the `Changelogs:` field of the Release file, so `publish-debs/publish-tree.sh` also writes each
package's changelog to `deb/changelogs/<prefix>/<source>/<source>_<version>_changelog` (a flat repository
has no component in the path) and adds `Changelogs: <base-url>/deb/changelogs/@CHANGEPATH@_changelog` to
every Release file. The `Changes` field of a `.changes` file is `debian/changelog` too.

## Descriptions

The Summary and `%description` of the spec and the `Description` of `debian/control` say what the package is
for and what it gives a person, in two to four sentences: a feature or a sound, not a build detail.
Developer packages (`-devel`, `-dev`) say what they let a developer build and against what. Internal names,
task numbers and how it is built belong in the repository's docs.

## Tests

`tests/changelog.sh` (the generator, from a throwaway git repository), `tests/updateinfo.sh` (two releases
published, `dnf updateinfo info` and `dnf check-update --changelogs` on a machine that holds the first) and
`tests/deb-changelog.sh` (a package built, published, and `apt changelog` over HTTP) run in `ci.yml`.
