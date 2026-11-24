#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""holds.py [--promoter DIR] rpm|deb <version> <commit> <name>...   (the paths of the channel tree on stdin)

The one question a v<version> tag asks before it publishes (docs/release-operations.md "One publisher per tag",
.github#130): does the staging tree of the channel hold a build of <version> of <commit>? A staged file is
staging/rpm/fedora/<release>/<arch>/<name>-<version>-<release>.git[<time>.]<sha>.<dist>.<arch>.rpm or
staging/deb/debian/<suite>/<arch>/<name>_<version>+git[<time>.]<sha>_<arch>.deb (collect.py's parser, the one the
promotion reads them with). <name> may be a glob; <commit> short or full. A file in the channel root does not count:
a served version is not a staged one.

--promoter DIR: the answer is true only when the checkout DIR also has a workflow under .github/workflows that calls
promote-staged.yml (a `uses:` line, not a comment). The release workflows ask with it, so a repository that has no
promotion keeps releasing from its tag; the promotion asks without it.

stdout: "holds <path>" for the first staged file of the build, or "holds none", then "holds=true" or "holds=false".
Exit 0 either way; 2 on a usage error.
"""
import fnmatch
import glob
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "promote-staged"))
from collect import LAYOUT, parse  # noqa: E402  (one parser of staged names for every reader of staging)

CALLER = re.compile(r"^\s*(-\s*)?uses:\s*['\"]?[^'\"\s#]*/\.github/workflows/promote-staged\.yml@", re.M)


def same(c, commit):
    """A short commit recorded in a file name is the commit when one is a prefix of the other."""
    return c.startswith(commit) or commit.startswith(c)


def promoter(d):
    for f in sorted(glob.glob(os.path.join(d, ".github", "workflows", "*.y*ml"))):
        with open(f, encoding="utf-8", errors="replace") as h:
            if CALLER.search(h.read()):
                return f
    return None


def main(argv):
    prom = None
    if argv[:1] == ["--promoter"]:
        if len(argv) < 2:
            sys.exit(__doc__)
        prom, argv = argv[1], argv[2:]
    if len(argv) < 4 or argv[0] not in LAYOUT:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    kind, version, commit, names = argv[0], argv[1], argv[2], argv[3:]
    top = f"staging/{kind}/{LAYOUT[kind][0]}/"
    found = None
    for line in sys.stdin:
        path = line.strip()
        if not path.startswith(top) or not path.endswith("." + kind):
            continue
        p = parse(kind, version, os.path.basename(path))
        if p and same(p[1], commit) and any(fnmatch.fnmatchcase(p[0], n) for n in names):
            found = path
            break
    print(f"holds {found or 'none'}")
    if found and prom is not None:
        caller = promoter(prom)
        if not caller:
            print(f"staged, and {prom} has no workflow that calls promote-staged.yml: the release workflows publish")
            found = None
        else:
            print(f"staged, and {os.path.relpath(caller, prom)} calls promote-staged.yml: the promotion publishes")
    print(f"holds={'true' if found else 'false'}")


if __name__ == "__main__":
    main(sys.argv[1:])
