#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""collect.py <channel checkout> rpm|deb --name N --version V --releases "44 45" --arches "x86_64 aarch64" --out DIR
              [--binaries "a b"] [--commit SHA] [--sums FILE]

The first step of a promotion (promote-staged.yml): find, in the staging tree of a channel checkout, the packages one
staged build of <name> <version> left there, and copy them to DIR laid out as the publish actions read them (rpm: flat;
deb: <suite>/<file>). Nothing is built and nothing in the checkout is written.

A staged build is named by its commit: <version>-<release>.git<sha>.fcNN for rpm, <version>+git<sha> for deb. Every
file of that version and commit goes along, the subpackages too. --releases are Fedora releases (rpm) or Debian suites
(deb), --arches the architectures a release builds; --binaries are the packages every one of those must hold
(default: the name), as its own architecture or as noarch / all.

It refuses, naming each case, and copies nothing when:
  - staging holds no build of that version, or builds of more than one commit and --commit names none of them;
  - a release and architecture of the matrix holds no build of a binary (or, for rpm, a release holds no source package);
  - the channel root serves a binary for a release the staged build does not cover: a machine on that release would
    be left on the old version.

On success: one "<sha256>  <path in the channel root>" line per file in --sums (default DIR.sha256) and on stdout, then
"commit <sha>", the short commit the staged build recorded.
"""
import argparse
import hashlib
import os
import re
import shutil
import sys

LAYOUT = {
    "rpm": ("fedora", "noarch", "SRPMS"),
    "deb": ("debian", "all", None),
}


def parse(kind, version, fname):
    """(package, commit, architecture) of a staged file of this version, or None."""
    v = re.escape(version)
    if kind == "rpm":
        m = re.match(rf"^(.+)-{v}-([^-]+)\.([^.]+)\.rpm$", fname)
        if not m:
            return None
        g = re.search(r"\.git([0-9a-f]{7,40})(?:\.|$)", "." + m.group(2))
        return (m.group(1), g.group(1), m.group(3)) if g else None
    m = re.match(rf"^([^_]+)_{v}\+git([0-9a-f]{{7,40}})[^_]*_([^_]+)\.deb$", fname)
    return (m.group(1), m.group(2), m.group(3)) if m else None


def cells(tree, ext):
    """{(release, arch dir): [package file names]} of <tree>/<release>/<arch dir>/."""
    out = {}
    for rel in sorted(os.listdir(tree)) if os.path.isdir(tree) else []:
        if not os.path.isdir(os.path.join(tree, rel)):
            continue
        for arch in sorted(os.listdir(os.path.join(tree, rel))):
            d = os.path.join(tree, rel, arch)
            if os.path.isdir(d):
                out[(rel, arch)] = sorted(f for f in os.listdir(d) if f.endswith(ext))
    return out


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("channel")
    ap.add_argument("kind", choices=("rpm", "deb"))
    for name in ("--name", "--version", "--releases", "--arches", "--out"):
        ap.add_argument(name, required=True)
    for name in ("--binaries", "--commit", "--sums"):
        ap.add_argument(name, default="")
    a = ap.parse_args()
    top, anyarch, srcdir = LAYOUT[a.kind]
    binaries = a.binaries.split() or [a.name]
    releases, arches = a.releases.split(), a.arches.split()
    stag = cells(os.path.join(a.channel, "staging", a.kind, top), "." + a.kind)
    root = cells(os.path.join(a.channel, a.kind, top), "." + a.kind)
    where = f"staging/{a.kind}/{top}"

    staged = {}  # (release, arch dir, file) -> (package, commit)
    for (rel, arch), files in stag.items():
        for f in files:
            p = parse(a.kind, a.version, f)
            if p:
                staged[(rel, arch, f)] = p[:2]
    commits = sorted({c for (p, c) in staged.values() if p in binaries or p == a.name})
    if a.commit:
        commits = [c for c in commits if c.startswith(a.commit) or a.commit.startswith(c)]
    if not commits:
        of = f" of commit {a.commit}" if a.commit else ""
        sys.exit(f"refused: {where} holds no {a.name} {a.version}{of}")
    if len(commits) > 1:
        sys.exit(f"refused: {where} holds {a.name} {a.version} of {len(commits)} commits ({' '.join(commits)}): name one with commit")
    commit = commits[0]
    chosen = {k: v for k, v in staged.items() if v[1] == commit}

    def has(rel, arch, pkg):
        return any(r == rel and d == arch and p == pkg for (r, d, _), (p, _) in chosen.items())

    def serves(rel, pkg):
        sep = "-" if a.kind == "rpm" else "_"
        return any(r == rel and d != srcdir and re.match(rf"^{re.escape(pkg)}{sep}[0-9]", f)
                   for (r, d), files in root.items() for f in files)

    refused = []
    for rel in releases:
        for arch in arches:
            for pkg in binaries:
                if not has(rel, arch, pkg) and not has(rel, anyarch, pkg):
                    refused.append(f"{where}/{rel}/{arch} holds no {pkg} {a.version} of {commit}")
        if srcdir and not has(rel, srcdir, a.name):
            refused.append(f"{where}/{rel}/{srcdir} holds no source package of {a.name} {a.version} of {commit}")
    for rel in sorted({r for (r, _) in root} - set(releases)):
        for pkg in binaries:
            if serves(rel, pkg):
                refused.append(f"the channel serves {pkg} in {a.kind}/{top}/{rel}, and the matrix of this promotion has no {rel}")
    if refused:
        sys.exit("\n".join("refused: " + r for r in refused) + "\nnothing was copied")

    if os.path.isdir(a.out) and os.listdir(a.out):
        sys.exit(f"refused: {a.out} is not empty")
    lines = []
    for (rel, arch, f) in sorted(chosen):
        src = os.path.join(a.channel, "staging", a.kind, top, rel, arch, f)
        dest = os.path.join(a.out, rel, f) if a.kind == "deb" else os.path.join(a.out, f)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(src, dest)
        with open(src, "rb") as h:
            lines.append(f"{hashlib.sha256(h.read()).hexdigest()}  {a.kind}/{top}/{rel}/{arch}/{f}")
    with open(a.sums or a.out.rstrip("/") + ".sha256", "w", encoding="utf-8") as h:
        h.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"commit {commit}")


if __name__ == "__main__":
    main()
