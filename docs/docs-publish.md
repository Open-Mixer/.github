<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# The generated reference of every repository, published per release

Every OpenMixer repository publishes the reference its own generators produce, at each release tag, on the site:

    https://www.openmixer.org/reference/                         the repositories
    https://www.openmixer.org/reference/<repo>/                  its versions
    https://www.openmixer.org/reference/<repo>/<version>/        one release
    https://www.openmixer.org/reference/<repo>/latest/           the highest release

One mechanism, three parts, nothing of the content written by hand:

- **the repository's `make docs-site DOCS_OUT=<dir>`** runs the doc check the repository already holds where that
  check needs no base (`check-protocol-doc`, `check-params-doc`, a Doxyfile with `WARN_AS_ERROR`; a baseline gate that
  compares with a base stays in the repository's CI and release workflows), then writes what its generators produce into `<dir>`: doxygen's html, the Markdown its tools render from source, its man pages, and the overview
  pages it keeps in the tree (its README.md, its docs/). Nothing is written for the site by hand: a target that
  copies a page kept only for the site is a review finding.
- **`actions/docs-site`** (`docs-site.sh`) renders every `*.md` and man page in that tree with pandoc, rewrites links
  between `.md` pages, writes the entry page when the tree has none (every page of the top two levels by its own
  title), refuses a tree with no page or with a symbolic link, and places a release under
  `reference/<repo>/<version>/`. `latest/` moves only when the release is the highest the channel holds, in version
  order (0.10.0 above 0.9.0), so a backport release never moves it. The version list and the repository list are
  written from the tree, so a place repeated on a newer channel tip writes the same bytes.
- **`workflows/docs-publish.yml`** runs both, on a repository's release tags and by dispatch: only the repository's
  one lint workflow runs on a pull request (actions/trigger-gate), and its doc check runs there. A dispatch builds and
  assembles; a tag push publishes into `Open-Mixer/open-mixer.github.io` through `channel-pull` and `channel-push` (a
  signed commit, retried on a lost race by placing again on the new tip) and waits for Pages with `pages-live`.

A repository calls it with one job:

    on:
      push:
        tags: ['v*']
      workflow_dispatch:
    jobs:
      docs:
        uses: Open-Mixer/.github/.github/workflows/docs-publish.yml@openmixer-v1
        with:
          apt: libjson-c-dev        # beyond doxygen, pandoc and make; none by default
          node-version: '24'        # a target that runs node; none by default
        secrets: inherit

## Why /reference/ and not /docs/

The site's other top-level paths belong to openmixer-www: its `deploy/site-owns.txt` lists `docs`, and its
`deploy-root.sh` replaces every listed path whole at each site publish. A repository's reference under `/docs/<repo>/`
would be deleted by the next site deploy, and two writers would own one tree. `reference/` is written by this
workflow alone; the site links to it and never lists it as its own.

## The test

`tests/docs-site.sh` (CI job `docs-site`): assemble renders Markdown and man pages and rewrites `.md` links; a tree
with no index page gets one listing every page once; an empty tree, a tree with no page and a symbolic link are
refused by name; place writes three releases in an order where
plain and version sort disagree and `latest/` is the highest; a backport leaves it; a second place of one release is no
change in git; a version or repository that is no name is refused. Sabotage: plain `sort` for the highest version, a
directory's own index left out of the written index, the no-page and the symbolic-link guards removed: each turns an
arm red.
