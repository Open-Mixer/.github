#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""built-cells.py rpm|deb --version V --commit SHA --missing FILE --built DIR --out DIR [--kept DIR] [--failed "rel arch,..."]

The second step of a promotion (promote-staged.yml, docs/release-operations.md "Promoting a staged version"): of the
packages built for the cells collect.py listed missing (--missing, "<release> <arch>" lines), choose what the publish
takes, per cell. --built is laid out as the build jobs upload it: rpm flat (<name>-<version>-<release>.fcNN.<arch>.rpm),
deb <suite>/<file>. --failed names the cells whose build or install check failed.

A missing cell is PUBLISHED when it has at least one built file of this version and of exactly the staged commit, no
file of another commit, and is not in --failed: its files go to --out (rpm flat, deb <suite>/). Otherwise it is FAILED
and nothing of it goes out. A built arch-independent file (noarch, src, all) goes out only for a release with no kept
cell (--kept, collect.py's output): the kept staged copy is never replaced, so a published file stays byte-identical.

Refused outright (exit 2, nothing copied): a built file of a cell that is not missing, i.e. a kept or served cell
rebuilt; and a missing list naming nothing.

stdout: "published <release> <arch>" and "FAILED <release> <arch>: <why>" per cell, then "dropped <file>: <why>" for
any built file left out. Exit 0 when every missing cell is published, 3 when some failed (the healthy ones are in
--out all the same: the caller publishes them, then ends red naming the failed ones).
"""
import argparse
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from collect import parse  # noqa: E402  (one parser of staged names for find and build)

def refuse(why):
    print("refused: " + why, file=sys.stderr)
    sys.exit(2)


ANY = {"rpm": ("noarch", "src"), "deb": ("all",)}


def built_files(kind, built):
    """[(release, arch, path, file)] of the built packages"""
    out = []
    for dirpath, _, files in os.walk(built):
        for f in sorted(files):
            if not f.endswith("." + kind):
                continue
            path = os.path.join(dirpath, f)
            if kind == "rpm":
                m = re.search(r"\.fc([0-9]+)\.([^.]+)\.rpm$", f)
                if not m:
                    refuse(f"{path} has no .fcNN.<arch> name")
                rel, arch = m.group(1), m.group(2)
            else:
                rel = os.path.basename(dirpath)
                arch = f.rsplit("_", 1)[-1][: -len(".deb")]
            out.append((rel, arch, path, f))
    return out


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("kind", choices=("rpm", "deb"))
    for name in ("--version", "--commit", "--missing", "--built", "--out"):
        ap.add_argument(name, required=True)
    ap.add_argument("--kept", default="")
    ap.add_argument("--failed", default="")
    a = ap.parse_args()
    with open(a.missing, encoding="utf-8") as h:
        missing = [tuple(line.split()) for line in h if line.strip()]
    if not missing:
        refuse("the missing list names no cell: nothing to build")
    failed_in = {tuple(c.split()) for c in a.failed.split(",") if c.strip()}
    kept_rel = set()
    if a.kept and os.path.isdir(a.kept):
        for rel, _, _, _ in built_files(a.kind, a.kept):
            kept_rel.add(rel)
    files = built_files(a.kind, a.built)
    missing_rel = {rel for rel, _ in missing}

    # a cell that is not missing is never rebuilt into the publish
    rebuilt = [p for rel, arch, p, _ in files if arch not in ANY[a.kind] and (rel, arch) not in missing]
    if rebuilt:
        refuse("built files of cells that are not missing (kept or served, never rebuilt): " + " ".join(rebuilt))

    def ours(f):
        p = parse(a.kind, a.version, f)
        return bool(p) and (p[1].startswith(a.commit) or a.commit.startswith(p[1]))

    report, take = [], []
    status = {}
    for rel, arch in missing:
        cell = [(p, f) for r, ar, p, f in files if r == rel and ar == arch]
        others = [f for _, f in cell if not ours(f)]
        if (rel, arch) in failed_in:
            status[(rel, arch)] = "its build or install check failed"
        elif not cell:
            status[(rel, arch)] = "no package was built"
        elif others:
            status[(rel, arch)] = f"built from another commit or version than {a.version} of {a.commit}: {' '.join(others)}"
        else:
            status[(rel, arch)] = ""
            take += [p for p, _ in cell]
    published_rel = {rel for (rel, _), why in status.items() if not why}
    drops = []
    for rel, arch, p, f in files:
        if arch not in ANY[a.kind]:
            continue
        if rel not in missing_rel or rel not in published_rel:
            drops.append(f"dropped {f}: no published cell of {rel} builds it")
        elif rel in kept_rel:
            drops.append(f"dropped {f}: {rel} keeps the staged copy, which is never replaced")
        elif not ours(f):
            drops.append(f"dropped {f}: not of {a.version} of {a.commit}")
        else:
            take.append(p)
    for (rel, arch), why in status.items():
        report.append(f"published {rel} {arch}" if not why else f"FAILED {rel} {arch}: {why}")
    os.makedirs(a.out, exist_ok=True)
    for p in take:
        if a.kind == "deb":
            dest = os.path.join(a.out, os.path.basename(os.path.dirname(p)), os.path.basename(p))
        else:
            dest = os.path.join(a.out, os.path.basename(p))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(p, dest)
    print("\n".join(report + drops))
    sys.exit(3 if any(status.values()) else 0)


if __name__ == "__main__":
    main()
