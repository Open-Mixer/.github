<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# The generated reference of every repository, published per release

Every OpenMixer repository publishes the reference its own generators produce, at each release tag, on the site:

    https://www.openmixer.org/reference/                         the repositories
    https://www.openmixer.org/reference/<repo>/                  its versions
    https://www.openmixer.org/reference/<repo>/<version>/        one release
    https://www.openmixer.org/reference/<repo>/latest/           the highest release

One mechanism, three parts, nothing of the content written by hand:

- **the repository's `make docs-site DOCS_OUT=<dir>`** runs the doc check the repository already holds (its doxygen
  gate, its `render --check`, its `check-protocol-doc`, its `check-params-doc`), then writes what its generators
  produce into `<dir>`: doxygen's html, the Markdown its tools render from source, its man pages, and an `index.md`
  (or `README.md`) as the entry page. A target that copies a hand-written file is a review finding.
- **`actions/docs-site`** (`docs-site.sh`) renders every `*.md` and man page in that tree with pandoc, rewrites links
  between `.md` pages, refuses a tree with no index page or with a symbolic link, and places a release under
  `reference/<repo>/<version>/`. `latest/` moves only when the release is the highest the channel holds, in version
  order (0.10.0 above 0.9.0), so a backport release never moves it. The version list and the repository list are
  written from the tree, so a place repeated on a newer channel tip writes the same bytes.
- **`workflows/docs-publish.yml`** runs both: on a pull request it builds and assembles (red there when the doc check
  is), on a tag push it publishes into `Open-Mixer/open-mixer.github.io` through `channel-pull` and `channel-push` (a
  signed commit, retried on a lost race by placing again on the new tip) and waits for Pages with `pages-live`.

A repository calls it with one job:

    on:
      push:
        tags: ['v*']
      pull_request:
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

`tests/docs-site.sh` (CI job `docs-site`): assemble renders Markdown and man pages and rewrites `.md` links; an empty
tree, a tree with no index page and a symbolic link are refused by name; place writes three releases in an order where
plain and version sort disagree and `latest/` is the highest; a backport leaves it; a second place of one release is no
change in git; a version or repository that is no name is refused. Sabotage: plain `sort` for the highest version, the
index guard and the symbolic-link guard removed, each turns an arm red.
