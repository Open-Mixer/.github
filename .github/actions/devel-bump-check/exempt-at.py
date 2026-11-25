#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""exempt-at.py <caller workflow file> <rpm|deb>

Prints the bump-exempt a caller workflow passes to build-<kind>.yml (the `with:` of every job that uses it), or nothing
when the file is absent or passes none (the default). devel-bump-check reads it at the merge base of a pull request:
the pull request is judged by that value, never by one it changes itself (.github#292). Exits 2, naming the file, when
jobs of one kind pass different values or the value is an expression, which cannot be read from the file.
"""
import os
import sys

import yaml


def main():
    path, kind = sys.argv[1:3]
    if not os.path.isfile(path):
        return
    doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
    values = set()
    for job in (doc.get("jobs") or {}).values():
        uses = str((job or {}).get("uses", ""))
        if f"/workflows/build-{kind}.yml@" in uses:
            values.add(" ".join(str((job.get("with") or {}).get("bump-exempt", "")).split()))
    if len(values) > 1:
        sys.exit(f"exempt-at: {path} passes {len(values)} different bump-exempt values to build-{kind}.yml: {sorted(values)}")
    value = values.pop() if values else ""
    if "${{" in value:
        sys.exit(f"exempt-at: {path} passes bump-exempt as an expression ({value}): it must be written in the file")
    print(value)


if __name__ == "__main__":
    main()
