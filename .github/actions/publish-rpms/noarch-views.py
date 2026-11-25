#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Where a noarch package goes, and whether every architecture view of a release serves the same newest noarch build.

An architecture VIEW of fedora/<release> is what dnf reads on that architecture: fedora/<release>/<arch> with
fedora/<release>/noarch (rpm/openmixer.repo, $basearch and noarch). Open-Mixer/.github#267: a quick release placed every
noarch package in the x86_64 tree alone, and the aarch64 view of fc45 kept serving omx-contract-devel 3.19.1 while
x86_64 served 3.21.0, although omx-contract-devel needs nothing built for an architecture.

A noarch package NEEDS AN ARCHITECTURE when
  - some architecture view cannot install it: a Requires (followed through what it pulls in) names something the channel
    provides and that view serves no build of that satisfies it (omx-dsp-contract 0.32.1 -> omx-dsp-devel 0.32.1, which
    no aarch64 tree served; plugin-hostd-protocol-contract 0.8.1 -> omx-contract >= 3.21.0, an x86_64 package). A
    Requires on a name no package of the channel provides is Fedora's and is not judged; or
  - an arch package of the same source pins it exactly (Requires: name = [epoch:]version-release) and an architecture
    tree serves that package and is left with an older build of it (omx-clap-libs -> omx-clap-contract, #62).
Only such a package belongs in the quick architecture trees of a quick release; every other one in fedora/<release>/noarch.

  noarch-views.py place <tree> <rpm dir>        one line per noarch binary package of <rpm dir>: <file> TAB noarch, or
                                                <file> TAB arch TAB the reason; every architecture REPO_ARCHES names is
                                                judged too, as an empty view where the release has no tree for it yet
  noarch-views.py check <tree> <name>...        refuse (exit 1) a release whose architecture views serve different newest
                                                builds of a named noarch package, unless the newest build needs an
                                                architecture the lower view lacks (above); one line per refusal, naming the
                                                release, the package and each view's newest build
  noarch-views.py report <tree>                 the same judgement for every noarch package of the tree (exit 1 if any)
"""
import os
import re
import sys

import rpm

NOT_ARCH = ("noarch", "SRPMS")
# the frozen releases (release-matrix/frozen.txt, as promote-staged/collect.py reads it): served, never built again, so
# never judged here; a skew left in one is no run's doing and no run could mend it. PROMOTE_FROZEN names another list.
FROZEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "release-matrix", "frozen.txt")


def frozen_rpm():
    """The Fedora releases the frozen list names (lines 'rpm <release>'; '#' comments)."""
    path = os.environ.get("PROMOTE_FROZEN") or FROZEN
    out = set()
    with open(path, encoding="utf-8") as h:
        for line in h:
            words = line.split("#", 1)[0].split()
            if len(words) == 2 and words[0] == "rpm":
                out.add(words[1])
    return out
SENSE = rpm.RPMSENSE_LESS | rpm.RPMSENSE_GREATER | rpm.RPMSENSE_EQUAL

OPS = {"=": rpm.RPMSENSE_EQUAL, "<": rpm.RPMSENSE_LESS, ">": rpm.RPMSENSE_GREATER,
       "<=": rpm.RPMSENSE_LESS | rpm.RPMSENSE_EQUAL, ">=": rpm.RPMSENSE_GREATER | rpm.RPMSENSE_EQUAL}
TERM = re.compile(r"([^\s()]+(?:\([^\s()]*\))?)(?:\s*(<=|>=|=|<|>)\s*([^\s()]+))?")


def rich_terms(expr):
    """Every positive term of a rich dependency, as plain (name, flags, version) Requires: (a >= 1 with a < 2) needs both.
    An 'or' or 'if' is read as needing every branch, which only ever holds a package to the quick trees, never frees one."""
    out, negate = [], False
    for m in TERM.finditer(expr):
        name, op, ver = m.group(1), m.group(2), m.group(3)
        if name in ("with", "and", "or", "if", "else"):
            negate = False
            continue
        if name in ("without", "unless"):
            negate = True
            continue
        if not negate:
            out.append((name, OPS.get(op, 0), ver or ""))
    return out


_ts = rpm.TransactionSet()
_ts.setVSFlags(rpm._RPMVSF_NOSIGNATURES | rpm._RPMVSF_NODIGESTS)


class Pkg:
    def __init__(self, path):
        fd = os.open(path, os.O_RDONLY)
        try:
            hdr = _ts.hdrFromFdno(fd)
        finally:
            os.close(fd)
        self.path = path
        self.name = hdr[rpm.RPMTAG_NAME]
        self.epoch = str(hdr[rpm.RPMTAG_EPOCH] or 0)
        self.version = hdr[rpm.RPMTAG_VERSION]
        self.release = hdr[rpm.RPMTAG_RELEASE]
        self.arch = hdr[rpm.RPMTAG_ARCH]
        self.is_source = bool(hdr[rpm.RPMTAG_SOURCEPACKAGE])
        self.sourcerpm = hdr[rpm.RPMTAG_SOURCERPM] or ""
        self.provides = list(zip(hdr[rpm.RPMTAG_PROVIDENAME] or [], hdr[rpm.RPMTAG_PROVIDEFLAGS] or [],
                                 hdr[rpm.RPMTAG_PROVIDEVERSION] or []))
        if not any(n == self.name for n, _f, _v in self.provides):
            self.provides.append((self.name, rpm.RPMSENSE_EQUAL, f"{self.epoch}:{self.vr}"))
        self.requires = []
        for n, f, v in zip(hdr[rpm.RPMTAG_REQUIRENAME] or [], hdr[rpm.RPMTAG_REQUIREFLAGS] or [],
                           hdr[rpm.RPMTAG_REQUIREVERSION] or []):
            if n.startswith("("):
                self.requires += rich_terms(n)
            elif not n.startswith(("rpmlib(", "/")):
                self.requires.append((n, f, v))

    @property
    def evr(self):
        return (self.epoch, self.version, self.release)

    @property
    def vr(self):
        return f"{self.version}-{self.release}"

    def pins(self, name):
        """The version-release this package pins <name> at exactly (Requires: name = [epoch:]version-release), or None."""
        for n, f, v in self.requires:
            if n == name and (f & SENSE) == rpm.RPMSENSE_EQUAL and v:
                return v.split(":", 1)[-1]
        return None


def read_dir(d):
    if not os.path.isdir(d):
        return []
    return [Pkg(os.path.join(d, f)) for f in sorted(os.listdir(d)) if f.endswith(".rpm")]


def newer(a, b):
    return rpm.labelCompare(a.evr, b.evr) > 0


def releasever(pkg):
    for part in pkg.release.split("."):
        if part.startswith("fc") and part[2:].isdigit():
            return part[2:]
    return None


def arch_dirs(tree, rel):
    base = os.path.join(tree, "fedora", rel)
    if not os.path.isdir(base):
        return []
    return sorted(a for a in os.listdir(base) if a not in NOT_ARCH and os.path.isdir(os.path.join(base, a)))


class View:
    """The packages one architecture can install from, and the names the channel provides at all."""

    def __init__(self, pkgs, channel_names):
        self.channel_names = channel_names
        self.by_name = {}
        for p in pkgs:
            if p.is_source:
                continue
            for n, f, v in p.provides:
                self.by_name.setdefault(n, []).append((p, f, v))
        self.memo = {}

    def providers(self, n, f, v):
        req = rpm.ds((n, f, v), rpm.RPMTAG_REQUIRENAME) if v else None
        out = []
        for p, pf, pv in self.by_name.get(n, []):
            if req is None or not pv or req.Compare(rpm.ds((n, pf, pv), rpm.RPMTAG_PROVIDENAME)):
                out.append(p)
        return out

    def missing(self, pkg):
        """The first Requires of <pkg>, or of what it pulls in, that this view cannot meet ('' when it installs)."""
        if pkg.path in self.memo:
            return self.memo[pkg.path]
        self.memo[pkg.path] = ""  # a cycle is met by the package in progress
        for n, f, v in pkg.requires:
            if n not in self.channel_names:
                continue
            cands = self.providers(n, f, v)
            why = None
            for c in cands:
                why = self.missing(c)
                if not why:
                    break
            if not cands:
                self.memo[pkg.path] = f"{n} {rpm.ds((n, f, v), rpm.RPMTAG_REQUIRENAME).DNEVR()[2:]}".strip()
                return self.memo[pkg.path]
            if why:
                self.memo[pkg.path] = why
                return why
        return ""


def release_pkgs(tree, rel):
    base = os.path.join(tree, "fedora", rel)
    common = [p for p in read_dir(os.path.join(base, "noarch")) if not p.is_source]
    own = {a: [p for p in read_dir(os.path.join(base, a)) if not p.is_source] for a in arch_dirs(tree, rel)}
    return common, own


def names_of(pkgs):
    return {n for p in pkgs for n, _f, _v in p.provides}


def left_by_pin(q, pinners, own, built):
    """The architecture trees that serve an arch package pinning <q>'s name exactly but no build of it pinning <q>."""
    left = []
    for a, served in own.items():
        for p in pinners:
            if a in built.get(p.name, set()):
                continue
            held = [s for s in served if s.name == p.name and s.arch != "noarch"]
            if held and not any(s.vr == p.vr for s in held):
                left.append(f"{a} ({p.name} {p.vr} pins it exactly; {a} serves {p.name} and the run did not build it there)")
                break
    return left


def place(tree, rpm_dir):
    run = []
    for root, _dirs, files in os.walk(rpm_dir):
        run += [Pkg(os.path.join(root, f)) for f in sorted(files) if f.endswith(".rpm")]
    run = [p for p in sorted(run, key=lambda p: p.path) if not p.is_source]
    by_rel = {}
    for p in run:
        by_rel.setdefault(releasever(p), []).append(p)
    verdict = {}
    for rel, pkgs in by_rel.items():
        noarch = [p for p in pkgs if p.arch == "noarch"]
        if rel is None:
            verdict.update({p.path: "" for p in noarch})
            continue
        common, own = release_pkgs(tree, rel)
        # every architecture the channel lays out gets a view, made empty if the release has none yet (REPO_ARCHES,
        # publish-tree.sh's repo_arches), and so does any other the release holds or the run builds
        arches = sorted(set(own) | {p.arch for p in pkgs if p.arch != "noarch"} | set(os.environ.get("REPO_ARCHES", "").split()))
        everything = common + [p for a in own for p in own[a]] + pkgs
        channel_names = names_of(everything)
        built = {}
        for p in pkgs:
            if p.arch != "noarch":
                built.setdefault(p.name, set()).add(p.arch)
        # a fixed point: a noarch package of the run held to the quick trees is not in noarch/ for the others to lean on
        shared = {p.path for p in noarch}
        while True:
            changed = False
            for q in noarch:
                if q.path not in shared:
                    continue
                why = ""
                for a in arches:
                    view = View(common + own.get(a, []) + [p for p in pkgs if p.arch == a or p.path in shared], channel_names)
                    miss = view.missing(q)
                    if miss:
                        why = f"fedora/{rel}/{a} cannot install it: nothing it serves provides {miss}"
                        break
                if not why:
                    pinners = [p for p in pkgs if p.arch != "noarch" and p.sourcerpm == q.sourcerpm and p.pins(q.name) == q.vr]
                    left = left_by_pin(q, pinners, own, built)
                    if left:
                        why = f"fedora/{rel}/{left[0]}"
                if why:
                    shared.discard(q.path)
                    verdict[q.path] = why
                    changed = True
            if not changed:
                break
        for q in noarch:
            verdict.setdefault(q.path, "")
    for path in sorted(verdict):
        print(f"{path}\tnoarch" if not verdict[path] else f"{path}\tarch\t{verdict[path]}")
    return 0


def judge(tree, names):
    """One line per unexplained difference of the newest noarch build across the architecture views of a release."""
    out = []
    fedora = os.path.join(tree, "fedora")
    skip = frozen_rpm()
    for rel in sorted(os.listdir(fedora)) if os.path.isdir(fedora) else []:
        if rel in skip:
            continue
        common, own = release_pkgs(tree, rel)
        arches = sorted(own)
        if len(arches) < 2:
            continue
        channel_names = names_of(common + [p for a in own for p in own[a]])
        views = {a: common + own[a] for a in arches}
        # per noarch name: the newest build of any view, and the views that serve an older one or none
        skew = {}
        for name in sorted({p.name for a in arches for p in views[a] if p.arch == "noarch"}):
            newest = {}
            for a in arches:
                for p in views[a]:
                    if p.name == name and p.arch == "noarch" and (newest.get(a) is None or newer(p, newest[a])):
                        newest[a] = p
            top = max(newest.values(), key=_Key)
            lower = [a for a in arches if newest.get(a) is None or newer(top, newest[a])]
            if lower:
                skew[name] = (top, newest, lower)
        # every noarch build an architecture tree holds, as if it were in noarch/, is what a lower view could have; a fixed
        # point takes out each one that is held to its tree for a reason (below), so what leans on it is held too
        held = set()
        while True:
            spread = [p for a in arches for p in own[a] if p.arch == "noarch" and p.path not in held]
            explained = {}
            for name, (top, _newest, lower) in skew.items():
                top_tree = os.path.basename(os.path.dirname(top.path))
                # the arch packages of its source beside it that pin it exactly (#62): an architecture serving one of
                # them at another build is left behind by design until it is built there
                pinners = [p for p in own.get(top_tree, []) if p.arch != "noarch" and p.sourcerpm == top.sourcerpm
                           and p.pins(name) == top.vr]
                explained[name] = [a for a in lower
                                   if View(views[a] + spread, channel_names).missing(top)
                                   or left_by_pin(top, pinners, {a: own[a]}, {})]
            now = {top.path for name, (top, _n, lower) in skew.items() if explained[name]}
            if now <= held:
                break
            held |= now
        for name in (names if names is not None else sorted(skew)):
            if name not in skew:
                continue
            top, newest, lower = skew[name]
            unexplained = [a for a in lower if a not in explained[name]]
            if not unexplained:
                continue
            at = os.path.relpath(os.path.dirname(top.path), tree)
            served = ", ".join(f"{a} {newest[a].vr if newest.get(a) else '(none)'}" for a in arches)
            out.append(f"fedora/{rel}: {name} {top.vr} is in {at} alone, and {' '.join(unexplained)} could install it but "
                       f"serves an older build or none (newest per view: {served}); it belongs in fedora/{rel}/noarch")
    return out


class _Key:
    def __init__(self, p):
        self.p = p

    def __lt__(self, other):
        return newer(other.p, self.p)


def main(argv):
    if len(argv) == 3 and argv[0] == "place":
        return place(argv[1], argv[2])
    if len(argv) >= 2 and argv[0] in ("check", "report"):
        names = None if argv[0] == "report" else sorted(set(argv[2:]))
        if names == []:
            return 0
        lines = judge(argv[1], names)
        for line in lines:
            if argv[0] == "check":
                print(f"refused {line}", file=sys.stderr)
            else:
                print(line)
        return 1 if lines else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
