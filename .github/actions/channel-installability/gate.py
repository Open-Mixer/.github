#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""channel-installability: no release may leave a package of the channel uninstallable.

The gate builds the channel as it would be after the release (the published index plus the release's new packages)
and asks the package manager's own solver whether every package that installed before still installs. apt takes the
newest version of every package and does not go back to an older one, so the check is made on the newest version of
each package only: a library published alone above its consumers' ceiling leaves the consumers uninstallable on
Debian although an older library is still in the tree (plugin-hostd-protocol 0.5.0: "held broken
packages" on a clean bookworm and trixie). Three arms:

  deb      dose-debcheck over the channel's Packages of each Debian release and architecture, with the Debian release
           (main, updates, security) as background, before and after: a package installable before and not after is
           RED, named with the dependency that is not met.
  rpm      dnf repoclosure --newest over the channel's repositories of each Fedora release and architecture (the
           architecture's tree and noarch), with the Fedora release as the system repositories, before and after.
  newest   each of our packages installed by itself on a clean machine (apt-get -s, dnf install --assumeno) resolves,
           with every one of our packages it pulls in, to the newest version published: dnf backtracks, and in the
           middle of a pass takes an old build without a ceiling beside the new library (plugin-hostd 0.17.0 asks only
           for protocol >= 0.2.0) while repoclosure passes. A fallback the release brings is RED, with the reason.
  hygiene  every published build, old ones too, whose dependencies on our own packages lack a floor or a ceiling is
           flagged, to be removed from the index or superseded (reported, not red).
  ceiling  every dependency between the channel's own packages that a new package declares has a floor AND a ceiling
           (R-107: below 1.0 the ceiling is the next minor, from 1.0 the next major); and a new version outside the
           range a published consumer declares is RED unless that consumer's new release is in the same pass.

A package named in --same-pass (released by another repository in the same pass) excuses a breakage of its own or one
it causes: its own release is checked when it publishes. --unbuilt-arch-pass (a dry run, whose matrix builds one
architecture) does the same, on an architecture the release brings no binary package for, for the binary packages it
built on another: the release builds them there at the new version. Every architecture is still checked. "before" is the published channel without the exact versions
this release brings, so a gate re-run after a partial publish judges the release, not the channel it already changed.

Exit status: 0 green, 1 red, 2 the check could not be made (an index that does not download, a tool that is missing):
2 is never a pass.

  gate.py deb     --channel URL|DIR [--suite S]... [--arch A]... (--new-dir DIR | --new-index FILE...) [options]
  gate.py rpm     --channel URL|DIR [--fedora N]... [--arch A]... --new-dir DIR [options]
  gate.py ceiling --kind deb|rpm --published FILE --new FILE [--same-pass NAMES]
  gate.py source-deb --control debian/control --changelog debian/changelog [--arch A]...   (stanzas, on stdout)
"""
import argparse
import functools
import glob
import gzip
import lzma
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

RED, GREEN, CANNOT = 1, 0, 2


class Cannot(Exception):
    """The measurement could not be taken."""


def say(msg):
    print(msg, flush=True)


def annotate(level, msg):
    # a GitHub annotation when run in Actions, a plain line otherwise
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::{level}::{msg}", flush=True)
    else:
        print(f"{level.upper()}: {msg}", flush=True)


# ----------------------------------------------------------------------------------------------- version comparison

def _deb_order(c):
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _deb_part(a, b):
    a, b = list(a), list(b)
    while a or b:
        first = 0
        while (a and not a[0].isdigit()) or (b and not b[0].isdigit()):
            ac = _deb_order(a[0]) if a and not a[0].isdigit() else 0
            bc = _deb_order(b[0]) if b and not b[0].isdigit() else 0
            if ac != bc:
                return -1 if ac < bc else 1
            if a and not a[0].isdigit():
                a.pop(0)
            if b and not b[0].isdigit():
                b.pop(0)
        an = ""
        while a and a[0].isdigit():
            an += a.pop(0)
        bn = ""
        while b and b[0].isdigit():
            bn += b.pop(0)
        first = int(an or 0) - int(bn or 0)
        if first:
            return -1 if first < 0 else 1
    return 0


def deb_split(v):
    e, _, rest = v.partition(":") if ":" in v else ("0", "", v)
    u, _, r = rest.rpartition("-") if "-" in rest else (rest, "", "0")
    return int(e or 0), u, r


def deb_cmp(a, b):
    """dpkg --compare-versions, as a cmp."""
    ea, ua, ra = deb_split(a)
    eb, ub, rb = deb_split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    return _deb_part(ua, ub) or _deb_part(ra, rb)


def rpmvercmp(a, b):
    """rpm's rpmvercmp of one version or release string."""
    if a == b:
        return 0
    i = j = 0
    while i < len(a) or j < len(b):
        while i < len(a) and not a[i].isalnum() and a[i] not in "~^":
            i += 1
        while j < len(b) and not b[j].isalnum() and b[j] not in "~^":
            j += 1
        if (i < len(a) and a[i] == "~") or (j < len(b) and b[j] == "~"):
            if not (i < len(a) and a[i] == "~"):
                return 1
            if not (j < len(b) and b[j] == "~"):
                return -1
            i += 1
            j += 1
            continue
        if (i < len(a) and a[i] == "^") or (j < len(b) and b[j] == "^"):
            if i >= len(a):
                return -1
            if j >= len(b):
                return 1
            if a[i] != "^":
                return 1
            if b[j] != "^":
                return -1
            i += 1
            j += 1
            continue
        if not (i < len(a) and j < len(b)):
            break
        isnum = a[i].isdigit()
        si, sj = i, j
        if isnum:
            while i < len(a) and a[i].isdigit():
                i += 1
            while j < len(b) and b[j].isdigit():
                j += 1
        else:
            while i < len(a) and a[i].isalpha():
                i += 1
            while j < len(b) and b[j].isalpha():
                j += 1
        x, y = a[si:i], b[sj:j]
        if not y:
            return 1 if isnum else -1
        if isnum:
            x, y = x.lstrip("0"), y.lstrip("0")
            if len(x) != len(y):
                return -1 if len(x) < len(y) else 1
        if x != y:
            return -1 if x < y else 1
    if i >= len(a) and j >= len(b):
        return 0
    return -1 if i >= len(a) else 1


def rpm_split(evr):
    e, _, rest = evr.partition(":") if ":" in evr else ("0", "", evr)
    v, _, r = rest.partition("-")
    return int(e or 0), v, r


def rpm_cmp(a, b):
    """Compare a package's EVR (a) with a constraint's (b): a constraint without a release compares the version only."""
    ea, va, ra = rpm_split(a)
    eb, vb, rb = rpm_split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = rpmvercmp(va, vb)
    if c or not ra or not rb:
        return c
    return rpmvercmp(ra, rb)


OPS = {
    "<<": lambda c: c < 0, "<": lambda c: c < 0, "<=": lambda c: c <= 0, "=": lambda c: c == 0,
    ">=": lambda c: c >= 0, ">>": lambda c: c > 0, ">": lambda c: c > 0,
}
# dpkg's old "<" and ">" mean <= and >=; rpm's mean strictly less and greater
DEB_OPS = dict(OPS, **{"<": OPS["<="], ">": OPS[">="]})
FLOOR_OPS = {">=", ">>", ">", "="}
CEILING_OPS = {"<<", "<", "<=", "="}


def satisfies(kind, version, op, want):
    cmp = deb_cmp(version, want) if kind == "deb" else rpm_cmp(version, want)
    return (DEB_OPS if kind == "deb" else OPS)[op](cmp)


def key(kind, version):
    import functools
    return functools.cmp_to_key(deb_cmp if kind == "deb" else rpm_cmp)(version)


# ----------------------------------------------------------------------------------------------- packages

class Pkg:
    def __init__(self, name, version, arch, deps, raw=None):
        self.name, self.version, self.arch, self.deps, self.raw = name, version, arch, deps, raw

    def __repr__(self):
        return f"{self.name} {self.version} ({self.arch})"


def parse_stanzas(text):
    out = []
    for block in re.split(r"\n\s*\n", text):
        if not block.strip():
            continue
        fields, last = {}, None
        for line in block.splitlines():
            if line[:1] in (" ", "\t") and last:
                fields[last] += "\n" + line
            elif ":" in line:
                last, _, value = line.partition(":")
                fields[last] = value.strip()
        if "Package" in fields:
            out.append((fields, block.strip() + "\n"))
    return out


DEB_ATOM = re.compile(r"^\s*([a-z0-9][a-z0-9+.-]*)(?::[a-z0-9-]+)?\s*(?:\(\s*(<<|<=|=|>=|>>|<|>)\s*([^)\s]+)\s*\))?")


def deb_deps(fields):
    """The atoms of Depends and Pre-Depends: (name, op or None, version or None)."""
    atoms = []
    for f in ("Pre-Depends", "Depends"):
        for clause in fields.get(f, "").replace("\n", " ").split(","):
            for alt in clause.split("|"):
                m = DEB_ATOM.match(alt)
                if m and alt.strip():
                    atoms.append((m.group(1), m.group(2), m.group(3)))
    return atoms


def deb_pkgs(stanzas):
    return [Pkg(f["Package"], f.get("Version", ""), f.get("Architecture", ""), deb_deps(f), raw)
            for f, raw in stanzas]


RPM_ARCH_SUFFIX = re.compile(r"\((?:x86-64|x86-32|aarch-64|arm-32|ppc-64|s390-64|riscv-64)\)$")
RPM_ATOM = re.compile(r"^\s*([^\s()]+(?:\([^)]*\))*)\s*(?:(<=|>=|<|>|=)\s*(\S+))?\s*$")


def rpm_req_atoms(req):
    """A Requires entry, plain or rich ((a >= 1 with a < 2)), as atoms (name, op, version)."""
    req = req.strip()
    if req.startswith("("):
        body = req[1:-1] if req.endswith(")") else req[1:]
        parts = re.split(r"\s+(?:with|and|or|if|else|unless|without)\s+", body)
    else:
        parts = [req]
    atoms = []
    for p in parts:
        p = p.strip().strip("()").strip() if p.count("(") != p.count(")") else p.strip()
        m = RPM_ATOM.match(p)
        if m:
            atoms.append((RPM_ARCH_SUFFIX.sub("", m.group(1)), m.group(2), m.group(3)))
    return atoms


def parse_rpm_query(text):
    """The output of repoquery --qf '@@%{name} %{evr} %{arch}\\n%{requires}\\n' as packages."""
    pkgs, cur = [], None
    for line in text.splitlines():
        if line.startswith("@@"):
            name, evr, arch = line[2:].split()[:3]
            cur = Pkg(name, evr, arch, [])
            pkgs.append(cur)
        elif cur is not None and line.strip():
            cur.deps.extend(rpm_req_atoms(line))
    return pkgs


def latest(kind, pkgs):
    """The newest version of every (name, architecture): the candidate a package manager installs."""
    best = {}
    for p in pkgs:
        k = (p.name, p.arch)
        if k not in best or (deb_cmp if kind == "deb" else rpm_cmp)(p.version, best[k].version) > 0:
            best[k] = p
    return list(best.values())


# ----------------------------------------------------------------------------------------------- ceiling arm

def fmt(op, ver, kind):
    return f"({op} {ver})" if kind == "deb" else f"{op} {ver}"


def r107_ceiling(floor):
    """R-107: below 1.0 the ceiling is the next minor, from 1.0 the next major."""
    nums = [int(x) for x in re.findall(r"\d+", floor.split("~")[0].split("-")[0])[:2]] + [0, 0]
    return f"0.{nums[1] + 1}" if nums[0] == 0 else f"{nums[0] + 1}"


def ceiling_check(kind, published, new, same_pass=()):
    """Returns (reds, warnings, notes): lists of lines."""
    reds, warns, notes = [], [], []
    same_pass = set(same_pass)
    new_keys = {(p.name, p.version, p.arch) for p in new}
    pub = latest(kind, [p for p in published if (p.name, p.version, p.arch) not in new_keys])
    ours = {p.name for p in published} | {p.name for p in new}
    new_names = {p.name for p in new}

    def ranges(p):
        by = {}
        for name, op, ver in p.deps:
            if name in ours and name != p.name:
                by.setdefault(name, []).append((op, ver))
        return by

    # 1. a floor and a ceiling on every dependency between our own packages (a new package must; a published one
    #    that does not is reported, not held against this release)
    def sanity(p, sink, what):
        for dep, cons in ranges(p).items():
            ops = {op for op, _ in cons if op}
            has_floor, has_ceiling = bool(ops & FLOOR_OPS), bool(ops & CEILING_OPS)
            if has_floor and not has_ceiling and kind == "deb" and re.match(r"^lib.*\d$", dep) \
                    and all(op in (">=", None) for op, _ in cons):
                # a shared library's shlibs dependency: the soname in the package name is its ceiling, and a new
                # soname is a new package
                continue
            if has_floor and has_ceiling:
                continue
            missing = " and ".join(x for x, ok in (("a floor", has_floor), ("a ceiling", has_ceiling)) if not ok)
            floors = [v for op, v in cons if op in FLOOR_OPS]
            hint = f"; R-107: the ceiling of {floors[0]} is {fmt('<<' if kind == 'deb' else '<', r107_ceiling(floors[0]) + ('~' if kind == 'deb' else ''), kind)}" if floors else ""
            sink.append(f"{what}{p.name} {p.version} depends on {dep} without {missing} "
                        f"(every dependency between our own packages has both{hint})")

    seen = set()
    for p in new:
        if (p.name, p.version) not in seen:
            seen.add((p.name, p.version))
            sanity(p, reds, "")
    seen = set()
    for p in pub:
        if p.name not in new_names and p.name not in seen:
            seen.add(p.name)
            sanity(p, warns, "published: ")

    # 2. a new version outside the range a consumer declares
    said = set()
    for lib in new:
        for cons_pkg in pub + new:
            if cons_pkg.name == lib.name:
                continue
            is_new = (cons_pkg.name, cons_pkg.version, cons_pkg.arch) in new_keys
            if not is_new and cons_pkg.name in new_names:
                continue  # the consumer's new release replaces this one; it is checked as new
            for op, ver in ranges(cons_pkg).get(lib.name, []):
                if not op or satisfies(kind, lib.version, op, ver):
                    continue
                k = (cons_pkg.name, cons_pkg.version, lib.name, lib.version, op, ver)
                if k in said:
                    continue
                said.add(k)
                req = f"{lib.name} {fmt(op, ver, kind)}"
                if is_new:
                    reds.append(f"{cons_pkg.name} {cons_pkg.version} of this pass requires {req}, and this pass "
                                f"releases {lib.name} {lib.version}: the two releases do not fit each other")
                elif cons_pkg.name in same_pass:
                    notes.append(f"{cons_pkg.name} {cons_pkg.version} requires {req}, outside {lib.name} "
                                 f"{lib.version}: its new release is in the same pass")
                else:
                    reds.append(f"{lib.name} {lib.version} falls outside the range published "
                                f"{cons_pkg.name} {cons_pkg.version} declares ({req}): release it in the same pass")
    return reds, warns, notes


# ----------------------------------------------------------------------------------------------- hygiene

def hygiene(kind, published):
    """Every published build, old ones too, whose dependencies on our own packages lack a floor or a ceiling: a
    package manager that backtracks (dnf) can fall back to it and install it beside the new library it does not fit,
    so it should leave the index or be superseded. Grouped by package and dependency; reported, not red."""
    ours = {p.name for p in published}
    groups = {}
    for p in published:
        by = {}
        for name, op, ver in p.deps:
            if name in ours and name != p.name:
                by.setdefault(name, set()).add(op)
        for dep, ops in by.items():
            ops.discard(None)
            has_floor, has_ceiling = bool(ops & FLOOR_OPS), bool(ops & CEILING_OPS)
            if has_floor and has_ceiling:
                continue
            if has_floor and kind == "deb" and re.match(r"^lib.*\d$", dep) and ops <= {">="}:
                continue  # a shlibs floor: the soname is the ceiling
            missing = " and ".join(x for x, ok in (("floor", has_floor), ("ceiling", has_ceiling)) if not ok)
            groups.setdefault((p.name, dep, missing), set()).add(p.version)
    cmpk = functools.cmp_to_key(deb_cmp if kind == "deb" else rpm_cmp)
    return [f"HYGIENE: {name} {' '.join(sorted(vs, key=cmpk))} depend on {dep} with no {missing}: remove these builds "
            f"from the index or supersede them" for (name, dep, missing), vs in sorted(groups.items())]


# ----------------------------------------------------------------------------------------------- newest arm

def newest_judge(where, before, after, same_pass, reds, warns, notes):
    """before and after map (requested package, our package resolved older) to a message. A fallback the release
    brings is RED; one that was there before is reported."""
    for k in sorted(after):
        req, dep = k
        # a package that does not resolve names what is missing only in dnf's problem: when every name it misses is
        # released in the same pass (an architecture a dry run built nothing for), it waits for the pass like the rest
        missing = set(re.findall(r"nothing provides ([^\s(]+)", after[k]))
        if k in before:
            warns.append(f"{where}: already before this release: {after[k]}")
        elif {req, dep} & set(same_pass) or (missing and missing <= set(same_pass)):
            notes.append(f"{where}: until the rest of the pass is released: {after[k]}")
        else:
            reds.append(f"{where}: {after[k]}")


INST = re.compile(r"^Inst (\S+) (?:\[[^]]*\] )?\((\S+) ")


def apt_newest(stanzas, bg_files, arch, names, work, tag):
    """apt-get -s install of each package alone on a clean machine of arch, the channel being the given stanzas.
    Returns {(package, our package): message} for every one of our packages that does not resolve to its newest
    version, and every package that does not install."""
    root = os.path.join(work, f"apt-{tag}")
    for d in ("bg", "chan", "state/lists/partial", "cache/archives/partial", "parts"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    open(os.path.join(root, "state/status"), "w").close()
    with open(os.path.join(root, "bg/Packages"), "w") as out:
        for b in bg_files:
            out.write(open(b).read().rstrip("\n") + "\n\n")
    with open(os.path.join(root, "chan/Packages"), "w") as out:
        for f, raw in stanzas:
            # apt simulates only what it could download: a package built here has no Filename, Size or hash yet
            extra = "" if "Filename" in f else f"\nFilename: ./{f['Package']}.deb"
            extra += "" if "Size" in f else "\nSize: 1"
            extra += "" if "SHA256" in f else "\nSHA256: " + "0" * 64
            out.write(raw.rstrip("\n") + extra + "\n")
            out.write("\n")
    with open(os.path.join(root, "sources.list"), "w") as out:
        out.write(f"deb [trusted=yes] file:{root}/bg ./\ndeb [trusted=yes] file:{root}/chan ./\n")
    opts = ["-o", f"Dir::State={root}/state", "-o", f"Dir::State::status={root}/state/status",
            "-o", f"Dir::Cache={root}/cache", "-o", f"Dir::Etc::SourceList={root}/sources.list",
            "-o", f"Dir::Etc::SourceParts={root}/parts", "-o", f"Dir::Etc::PreferencesParts={root}/parts",
            "-o", f"Dir::Etc::Preferences={root}/parts/none", "-o", f"APT::Architecture={arch}",
            "-o", f"APT::Architectures={arch}", "-o", "Debug::NoLocking=1", "-o", "Acquire::Languages=none",
            "-o", "Acquire::AllowInsecureRepositories=1", "-o", "APT::Get::AllowUnauthenticated=1",
            "-o", "APT::Install-Recommends=0", "-o", "APT::Sandbox::User=root"]
    r = subprocess.run(["apt-get", *opts, "update"], capture_output=True, text=True)
    if r.returncode:
        raise Cannot(f"apt-get update of the {tag} view failed: {r.stderr.strip()[-400:]}")
    newest = {}
    for f, _ in stanzas:
        n, v = f["Package"], f.get("Version", "")
        if n not in newest or deb_cmp(v, newest[n]) > 0:
            newest[n] = v
    found = {}
    for name in sorted(names):
        r = subprocess.run(["apt-get", *opts, "-s", "install", name], capture_output=True, text=True)
        if r.returncode:
            why = " ".join(l.strip() for l in (r.stdout + r.stderr).splitlines()
                           if ":" in l and ("Depends" in l or "Breaks" in l or "Conflicts" in l or l.startswith("E:")))
            found[(name, name)] = f"apt-get install {name} fails on a clean machine: {why or r.stderr.strip()[-300:]}"
            continue
        for m in INST.finditer(r.stdout):
            pkg, ver = m.group(1).split(":")[0], m.group(2)
            if pkg in newest and deb_cmp(ver, newest[pkg]) < 0:
                found[(name, pkg)] = (f"installing {name} resolves {pkg} to {ver}, not its newest {newest[pkg]} "
                                      f"(apt-get -s)")
    return found


ROW = re.compile(r"^ (\S+)\s+(\S+)\s+(?:\d+:)?(\S+)\s+(\S+)\s")


def dnf_transaction(base, specs):
    """dnf install --assumeno: (rows [(name, arch, evr, repo)], problem text or '')."""
    r = subprocess.run(base + ["install", "--assumeno", "--setopt=install_weak_deps=False"] + list(specs),
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    rows = [m.groups() for line in out.splitlines() for m in [ROW.match(line)] if m]
    problem = ""
    if "Problem" in out or "Failed to resolve" in out or "No match" in out:
        problem = " ".join(l.strip() for l in out.splitlines()
                           if l.strip().startswith(("Problem", "- ", "No match", "Failed")))[:600]
    return rows, problem


def dnf_newest(base, ids, pkgs, arch):
    """Each of our packages installed on a clean machine resolves to its newest version, and so does every one of
    our packages it pulls in. One transaction of all of them first; a fallback in it, or a transaction that does not
    resolve, is then attributed package by package. dnf backtracks, so an old build without a ceiling can be taken
    beside a new library: that is the fallback this finds. Returns {(package, our package): message}."""
    view = [p for p in pkgs if p.arch in (arch, "noarch")]
    newest = {}
    for p in view:
        if p.name not in newest or rpm_cmp(p.version, newest[p.name]) > 0:
            newest[p.name] = p.version
    names = sorted(newest)
    ours = set(ids)

    def fallbacks(rows):
        return {(n, evr) for n, a_, evr, repo in rows if repo in ours and n in newest
                and rpm_cmp(evr, newest[n]) < 0}

    rows, problem = dnf_transaction(base, names)
    if rows and not problem and not fallbacks(rows):
        return {}
    found = {}
    for name in names:
        rows, problem = dnf_transaction(base, [name])
        if problem and not rows:
            _, why = dnf_transaction(base, [f"{name}-{newest[name]}"])
            found[(name, name)] = f"dnf install {name} does not resolve on a clean machine: {why or problem}"
            continue
        for dep, evr in sorted(fallbacks(rows)):
            forced = [name] + ([f"{dep}-{newest[dep]}"] if dep != name else [f"{name}-{newest[name]}"])
            rows2, why = dnf_transaction(base, forced)
            if not why:
                # the newest resolves, and something else then falls back: an old build without a ceiling
                other = sorted(f"{n} {e}" for n, e in fallbacks(rows2) if n != dep)
                why = (f"with {dep} {newest[dep]} requested, dnf takes {', '.join(other)} instead"
                       if other else "dnf takes the older build although the newest resolves")
            found[(name, dep)] = f"installing {name} falls back to {dep} {evr}, not its newest {newest[dep]}: {why}"
    return found


# ----------------------------------------------------------------------------------------------- fetching

def fetch(src, dest):
    """A URL (http, https, file) or a local path, into dest; a .xz or .gz source is uncompressed."""
    try:
        if re.match(r"^[a-z]+://", src):
            req = urllib.request.Request(src, headers={"User-Agent": "channel-installability"})
            last = None
            for _ in range(4):
                try:
                    with urllib.request.urlopen(req, timeout=60) as r:
                        data = r.read()
                    break
                except Exception as e:  # noqa: BLE001 - every failure is retried, then reported
                    last = e
            else:
                raise last
        else:
            with open(src, "rb") as f:
                data = f.read()
    except Exception as e:  # noqa: BLE001
        raise Cannot(f"{src} could not be read: {e}") from e
    if src.endswith(".xz"):
        data = lzma.decompress(data)
    elif src.endswith(".gz"):
        data = gzip.decompress(data)
    with open(dest, "wb") as f:
        f.write(data)
    return dest


def exists(src):
    if re.match(r"^[a-z]+://", src):
        try:
            req = urllib.request.Request(src, method="HEAD", headers={"User-Agent": "channel-installability"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status == 200
        except Exception:  # noqa: BLE001
            return False
    return os.path.exists(src)


def join(base, *parts):
    return "/".join([base.rstrip("/")] + [p.strip("/") for p in parts])


def served_suites(channel, work):
    """The Debian releases the channel serves: the sources files openmixer-release installs."""
    deb = fetch(join(channel, "openmixer-release.deb"), os.path.join(work, "openmixer-release.deb"))
    out = os.path.join(work, "openmixer-release")
    if subprocess.run(["dpkg-deb", "-x", deb, out]).returncode:
        raise Cannot("openmixer-release.deb could not be unpacked")
    suites = sorted({m.group(1) for f in glob.glob(os.path.join(out, "usr/share/openmixer-release/*.sources"))
                     for m in [re.search(r"URIs:\s*\S*/debian/([a-z]+)/", open(f).read())] if m})
    if not suites:
        raise Cannot("openmixer-release.deb names no Debian release")
    return suites


# ----------------------------------------------------------------------------------------------- deb arm

def deb_new_stanzas(new_dir, suite, new_index):
    stanzas = []
    for f in new_index or []:
        stanzas += parse_stanzas(open(f).read())
    if new_dir:
        debs = sorted(glob.glob(os.path.join(new_dir, suite, "**", "*.deb"), recursive=True))
        if not os.path.isdir(os.path.join(new_dir, suite)):
            # a flat directory of packages built for every release
            debs = sorted(glob.glob(os.path.join(new_dir, "*.deb")))
        for d in debs:
            r = subprocess.run(["dpkg-deb", "-f", d], capture_output=True, text=True)
            if r.returncode:
                raise Cannot(f"{d} is not a package dpkg-deb reads: {r.stderr.strip()}")
            stanzas += parse_stanzas(r.stdout)
    return stanzas


def debian_background(suite, arch, mirror, security, work):
    files = []
    for base, dist in ((mirror, suite), (mirror, f"{suite}-updates"), (security, f"{suite}-security")):
        url = join(base, "dists", dist, "main", f"binary-{arch}", "Packages.xz")
        dest = os.path.join(work, f"bg-{dist}-{arch}")
        if not os.path.exists(dest):
            fetch(url, dest)
        files.append(dest)
    return files


def run_dose(fg_stanzas, bg_files, arch, work, tag):
    fg = os.path.join(work, f"fg-{tag}")
    with open(fg, "w") as f:
        f.write("\n".join(raw for _, raw in fg_stanzas))
    cmd = ["dose-debcheck", "--latest", "1", f"--deb-native-arch={arch}", "-e", "-f", "--fg", fg]
    for b in bg_files:
        cmd += ["--bg", b]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode not in (0, 1):
        raise Cannot(f"dose-debcheck failed ({r.returncode}): {r.stderr.strip()[:400]}")
    try:
        import yaml
    except ImportError as e:
        raise Cannot("python3-yaml is needed to read dose-debcheck's report") from e
    doc = yaml.safe_load(r.stdout) or {}
    broken = {}
    for entry in doc.get("report") or []:
        reasons = []
        for reason in entry.get("reasons") or []:
            if "missing" in reason:
                pkg = reason["missing"]["pkg"]
                reasons.append((pkg["package"], f"{pkg['package']} {pkg['version']} needs "
                                f"{pkg.get('unsat-dependency', '?')}, which nothing in the channel meets"))
            elif "conflict" in reason:
                c = reason["conflict"]
                p1, p2 = c.get("pkg1", {}), c.get("pkg2", {})
                reasons.append((p1.get("package", "?"), f"{p1.get('package')} {p1.get('version')} conflicts with "
                                f"{p2.get('package')} {p2.get('version')}"))
        broken.setdefault(str(entry["package"]), []).append((str(entry["version"]), reasons))
    return broken


def judge(where, before, after, new_names, same_pass, reds, warns, notes):
    """before and after map a package name to its breakage; a name broken after and not before is RED."""
    for name in sorted(after):
        for version, reasons in after[name]:
            why = "; ".join(sorted({r for _, r in reasons})) or "no reason given"
            if name in before:
                was = "; ".join(sorted({r for _, rs in before[name] for _, r in rs})) or "no reason given"
                warns.append(f"{where}: {name} {version} was already uninstallable before this release: {was}")
                continue
            culprits = {name} | {c for c, _ in reasons}
            if culprits & set(same_pass):
                notes.append(f"{where}: {name} {version} is uninstallable until the rest of the pass "
                             f"({' '.join(sorted(culprits & set(same_pass)))}) is released: {why}")
                continue
            state = "is new and does not install" if name in new_names else "was installable and is not"
            reds.append(f"{where}: {name} {version} {state}: {why}")


def unbuilt_pass(a, here, elsewhere):
    """--same-pass for one architecture: with --unbuilt-arch-pass, an architecture the release built no binary package
    for takes the binary packages it built on another as released in the same pass, at the new version."""
    if not getattr(a, "unbuilt_arch_pass", False) or here:
        return list(a.same_pass)
    if elsewhere:
        say(f"no binary package built for this architecture: {' '.join(sorted(elsewhere))} counted in the same pass")
    return list(a.same_pass) + sorted(elsewhere)


def deb_arm(a):
    reds, warns, notes = [], [], []
    work = tempfile.mkdtemp(prefix="gate-deb-")
    try:
        # every Debian release the channel serves, and any the release brings that it does not serve yet
        built = sorted(d for d in os.listdir(a.new_dir) if os.path.isdir(os.path.join(a.new_dir, d))) \
            if a.new_dir and os.path.isdir(a.new_dir) else []
        suites = a.suite or sorted(set(served_suites(a.channel, work)) | set(built))
        for suite in suites:
            pub_src = join(a.channel, "debian", suite, "Packages")
            published = parse_stanzas(open(fetch(pub_src, os.path.join(work, f"pub-{suite}"))).read())
            new = deb_new_stanzas(a.new_dir, suite, a.new_index)
            drop = set(a.drop or [])
            published = [s for s in published if f"{s[0]['Package']}={s[0].get('Version')}" not in drop
                         and s[0]["Package"] not in drop]
            new_keys = {(f["Package"], f.get("Version"), f.get("Architecture")) for f, _ in new}
            before_all = [s for s in published
                          if (s[0]["Package"], s[0].get("Version"), s[0].get("Architecture")) not in new_keys]
            arches = a.arch or sorted({f.get("Architecture") for f, _ in published + new} - {"all", None, ""})
            new_names = {f["Package"] for f, _ in new}
            say(f"debian/{suite}: {len(published)} published, {len(new)} new "
                f"({' '.join(sorted(new_names)) or 'none'}), architectures {' '.join(arches)}")
            for arch in arches:
                bg = a.bg or debian_background(suite, arch, a.mirror, a.security, work)
                pick = lambda ss: [s for s in ss if s[0].get("Architecture") in (arch, "all")]  # noqa: E731
                same_pass = unbuilt_pass(a, {f["Package"] for f, _ in new if f.get("Architecture") == arch},
                                         {f["Package"] for f, _ in new if f.get("Architecture") not in (arch, "all")})
                before = run_dose(pick(before_all), bg, arch, work, f"{suite}-{arch}-before")
                after = run_dose(pick(before_all) + pick(new), bg, arch, work, f"{suite}-{arch}-after")
                judge(f"debian/{suite} {arch}", before, after, new_names, same_pass, reds, warns, notes)
                say(f"debian/{suite} {arch}: {sum(map(len, before.values()))} uninstallable before, "
                    f"{sum(map(len, after.values()))} after")
                if not a.no_newest:
                    view_b, view_a = pick(before_all), pick(before_all) + pick(new)
                    names_a = {f["Package"] for f, _ in view_a}
                    nb = apt_newest(view_b, bg, arch, {f["Package"] for f, _ in view_b}, work, f"{suite}-{arch}-before")
                    na = apt_newest(view_a, bg, arch, names_a, work, f"{suite}-{arch}-after")
                    newest_judge(f"debian/{suite} {arch} newest", nb, na, same_pass, reds, warns, notes)
                    say(f"debian/{suite} {arch}: {len(names_a)} packages installed alone, {len(nb)} not at their "
                        f"newest before, {len(na)} after")
            warns += [f"debian/{suite}: {x}" for x in hygiene("deb", deb_pkgs(published))]
            r, w, n = ceiling_check("deb", deb_pkgs(published), deb_pkgs(new), a.same_pass)
            reds += [f"debian/{suite}: {x}" for x in r]
            warns += [f"debian/{suite}: {x}" for x in w]
            notes += [f"debian/{suite}: {x}" for x in n]
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)
    return report("deb", reds, warns, notes)


# ----------------------------------------------------------------------------------------------- rpm arm

def dnf_base(release, arch, reposdir=None):
    return ["dnf"] + ([f"--setopt=reposdir={reposdir}"] if reposdir else []) + [ f"--releasever={release}", f"--forcearch={arch}", "--setopt=*.gpgcheck=0",
            "--setopt=*.repo_gpgcheck=0", "--setopt=skip_if_unavailable=False"]


def system_omx_repos():
    r = subprocess.run(["dnf", "-q", "repo", "list", "--all"], capture_output=True, text=True)
    return sorted({line.split()[0] for line in r.stdout.splitlines()[1:]
                   if line.split() and line.split()[0].startswith("openmixer")})


def rpm_nevra_name(nevra):
    # name-[epoch:]version-release.arch
    m = re.match(r"^(.+)-(?:\d+:)?[^-]+-[^-]+\.[^.]+$", nevra)
    return m.group(1) if m else nevra


def run_repoclosure(base, repos, check, arch):
    cmd = list(base)
    for rid, path in repos:
        cmd.append(f"--repofrompath={rid},{path}")
    # the system's own OpenMixer repositories (an add-openmixer earlier in the job) would stand in for the channel
    cmd += [f"--disablerepo={r}" for r in system_omx_repos()]
    cmd += ["repoclosure", "--newest", f"--check={','.join(check)}", f"--arch={arch}", "--arch=noarch"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = r.stdout + r.stderr
    broken, cur = {}, None
    for line in out.splitlines():
        m = re.match(r"^package:\s+(\S+)\s+from\s+(\S+)", line)
        if m:
            cur = (rpm_nevra_name(m.group(1)), m.group(1))
            broken.setdefault(cur[0], []).append((cur[1][len(cur[0]) + 1:], []))
        elif cur and line.startswith("    ") and line.strip():
            dep = line.strip()
            names = {n for n, _, _ in rpm_req_atoms(dep)}
            broken[cur[0]][-1][1].append((next(iter(names), dep), f"{cur[1]} needs {dep}, which nothing meets"))
    if r.returncode and not broken:
        raise Cannot(f"dnf repoclosure failed ({r.returncode}): {out.strip()[-600:]}")
    return broken


QF = "@@%{name} %{evr} %{arch}\n%{requires}\n"


def repoquery(base, repos, ids, excludes=()):
    cmd = list(base)
    for rid, path in repos:
        cmd.append(f"--repofrompath={rid},{path}")
    for rid in ids:
        if excludes:
            cmd.append(f"--setopt={rid}.excludepkgs={','.join(excludes)}")
    cmd += ["repoquery", "-q", "--qf", QF]
    for rid in ids:
        cmd += ["--repo", rid]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise Cannot(f"dnf repoquery failed ({r.returncode}): {r.stderr.strip()[-600:]}")
    return parse_rpm_query(r.stdout)


def served_fedora(channel):
    return [str(n) for n in range(38, 61) if exists(join(channel, "fedora", str(n), "noarch", "repodata", "repomd.xml"))]


def rpm_arm(a):
    reds, warns, notes = [], [], []
    work = tempfile.mkdtemp(prefix="gate-rpm-")
    try:
        rpms = [f for f in glob.glob(os.path.join(a.new_dir, "**", "*.rpm"), recursive=True)
                if not f.endswith(".src.rpm")] if a.new_dir else []
        versions = a.fedora or sorted(set(served_fedora(a.channel))
                                      | {m.group(1) for f in rpms for m in [re.search(r"\.fc(\d+)\.", f)] if m})
        if not versions:
            raise Cannot(f"no Fedora release served under {a.channel}/fedora and none given")
        arches = a.arch or ["x86_64", "aarch64"]
        for rel in versions:
            for arch in arches:
                where = f"fedora/{rel} {arch}"
                mine = [f for f in rpms if re.search(rf"\.fc{rel}\.({arch}|noarch)\.rpm$", f)]
                rpm_name = lambda f: os.path.basename(f).rsplit("-", 2)[0]  # noqa: E731
                same_pass = unbuilt_pass(
                    a, {rpm_name(f) for f in rpms if re.search(rf"\.fc{rel}\.{arch}\.rpm$", f)},
                    {rpm_name(f) for f in rpms if re.search(rf"\.fc{rel}\.[^.]+\.rpm$", f)
                     and not re.search(rf"\.fc{rel}\.({arch}|noarch)\.rpm$", f)})
                newdir = os.path.join(work, f"new-{rel}-{arch}")
                os.makedirs(newdir)
                for f in mine:
                    shutil.copy(f, newdir)
                if subprocess.run(["createrepo_c", "-q", newdir]).returncode:
                    raise Cannot(f"createrepo_c failed on the new packages of {where}")
                base = dnf_base(rel, arch, a.reposdir)
                pub = [("omx-gate", channel_path(a.channel, rel, arch)),
                       ("omx-gate-noarch", channel_path(a.channel, rel, "noarch"))]
                newrepo = [("omx-gate-new", newdir)]
                new_pkgs = repoquery(base, newrepo, ["omx-gate-new"])
                new_nevras = [f"{p.name}-{p.version}.{p.arch}" for p in new_pkgs]
                excl = new_nevras + [x for x in (a.drop or [])]
                ids = [r for r, _ in pub]
                excl_opts = [f"--setopt={rid}.excludepkgs={','.join(excl)}" for rid in ids] if excl else []
                before = run_repoclosure(base + excl_opts, pub, ids, arch)
                # repoclosure --newest takes the newest of each repository, so the published versions of what the
                # release brings leave the published repositories for the after view: the newest of each name is
                # then the one the release brings, as for apt
                shadow = sorted({p.name for p in new_pkgs})
                after_opts = [f"--setopt={rid}.excludepkgs={','.join(excl + shadow)}" for rid in ids] \
                    if excl or shadow else []
                after = run_repoclosure(base + after_opts, pub + newrepo, ids + ["omx-gate-new"], arch)
                new_names = {p.name for p in new_pkgs}
                say(f"{where}: {len(new_pkgs)} new ({' '.join(sorted(new_names)) or 'none'}), "
                    f"{sum(map(len, before.values()))} unresolved before, {sum(map(len, after.values()))} after")
                judge(where, before, after, new_names, same_pass, reds, warns, notes)
                published = repoquery(base, pub, ids, excl)
                if not a.no_newest:
                    # every version stays in view here: the fallback to an old build is what is looked for
                    sysrepos = [f"--disablerepo={r}" for r in system_omx_repos()]
                    # an empty install root is the clean machine, of the architecture checked, whatever the host is
                    root = os.path.join(work, f"root-{rel}-{arch}")
                    os.makedirs(root, exist_ok=True)
                    clean = [f"--installroot={root}", "--use-host-config"]
                    vb = base + clean + excl_opts + sysrepos + [f"--repofrompath={i},{u}" for i, u in pub]
                    va = vb + [f"--repofrompath={i},{u}" for i, u in newrepo]
                    nb = dnf_newest(vb, ids, published, arch)
                    na = dnf_newest(va, ids + ["omx-gate-new"], published + new_pkgs, arch)
                    newest_judge(f"{where} newest", nb, na, same_pass, reds, warns, notes)
                    say(f"{where}: {len(nb)} of our packages not at their newest before, {len(na)} after")
                warns += [f"{where}: {x}" for x in hygiene("rpm", published)]
                r, w, n = ceiling_check("rpm", published, new_pkgs, same_pass)
                reds += [f"{where}: {x}" for x in r]
                warns += [f"{where}: {x}" for x in w]
                notes += [f"{where}: {x}" for x in n]
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)
    return report("rpm", reds, warns, notes)


_indexed = {}


def channel_path(channel, rel, arch):
    p = join(channel, "fedora", rel, arch) + "/"
    if re.match(r"^[a-z]+://", p):
        return p
    p = os.path.abspath(p)
    # A pulled tree (channel-pull) has its dnf metadata removed, so the publish regenerates it from the bytes the tree
    # holds; the gate indexes the same bytes in a scratch directory of its own and leaves the tree as it was pulled. A
    # directory that does not exist stays as it is: an unreadable repository is not a pass.
    if os.path.isdir(p) and not exists(join(p, "repodata", "repomd.xml")):
        if p not in _indexed:
            scratch = tempfile.mkdtemp(prefix="gate-pulled-")
            for f in glob.glob(join(p, "**", "*.rpm"), recursive=True):
                link = join(scratch, os.path.basename(f))
                if not os.path.lexists(link):
                    os.symlink(f, link)
            if subprocess.run(["createrepo_c", "-q", scratch]).returncode:
                raise Cannot(f"createrepo_c failed on the pulled tree {p}")
            _indexed[p] = scratch + "/"
        return _indexed[p]
    return p


# ----------------------------------------------------------------------------------------------- source stanzas

def source_deb(a):
    """Binary stanzas from a source tree's debian/control and debian/changelog, for a preflight before any build:
    ${binary:Version} and ${source:Version} become the changelog's version, other substitutions are dropped."""
    version = re.match(r"^\S+\s+\(([^)]+)\)", open(a.changelog).readline()).group(1)
    paras = parse_stanzas(open(a.control).read())
    out = []
    for fields, _ in paras:
        if "Source" in fields and "Package" not in fields:
            continue
        arch = fields.get("Architecture", "any")
        archs = ["all"] if arch == "all" else (a.arch or ["amd64", "arm64"])
        for ar in archs:
            lines = [f"Package: {fields['Package']}", f"Version: {version}", f"Architecture: {ar}"]
            for f in ("Pre-Depends", "Depends", "Conflicts", "Breaks", "Provides"):
                v = fields.get(f, "").replace("\n", " ")
                v = v.replace("${binary:Version}", version).replace("${source:Version}", version)
                v = ", ".join(c.strip() for c in v.split(",") if c.strip() and "${" not in c)
                if v:
                    lines.append(f"{f}: {v}")
            out.append("\n".join(lines) + "\n")
    sys.stdout.write("\n".join(out))
    return 0


# ----------------------------------------------------------------------------------------------- report

def report(arm, reds, warns, notes):
    for n in notes:
        annotate("notice", f"{arm}: {n}")
    for w in warns:
        annotate("warning", f"{arm}: {w}")
    for r in reds:
        annotate("error", f"RED {arm}: {r}")
    if reds:
        say(f"channel-installability {arm}: RED ({len(reds)}): a release may not leave a package uninstallable")
        return RED
    say(f"channel-installability {arm}: GREEN (every package that installed before still installs)")
    return GREEN


def ceiling_cmd(a):
    if a.kind == "deb":
        pub = deb_pkgs(parse_stanzas(open(a.published).read()))
        new = deb_pkgs(sum((parse_stanzas(open(f).read()) for f in a.new), []))
    else:
        pub = parse_rpm_query(open(a.published).read())
        new = sum((parse_rpm_query(open(f).read()) for f in a.new), [])
    return report("ceiling", *ceiling_check(a.kind, pub, new, a.same_pass))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    words = lambda s: s.split()  # noqa: E731

    def common(p):
        p.add_argument("--channel", default="https://www.openmixer.org/deb")
        p.add_argument("--arch", action="append")
        p.add_argument("--new-dir")
        p.add_argument("--same-pass", type=words, default=[])
        p.add_argument("--drop", action="append", help="leave this NAME or NAME=VERSION (rpm: a NEVRA glob) out of "
                                                       "the published channel")
        p.add_argument("--keep", action="store_true", help="keep the work directory")
        p.add_argument("--no-newest", action="store_true", help="skip the arm that installs each package alone")
        p.add_argument("--unbuilt-arch-pass", action="store_true",
                       help="a dry run: on an architecture with no binary package built, the binary packages built on "
                            "another count as released in the same pass")

    d = sub.add_parser("deb")
    common(d)
    d.add_argument("--suite", action="append")
    d.add_argument("--new-index", action="append")
    d.add_argument("--bg", action="append", help="background Packages files, instead of the Debian mirror")
    d.add_argument("--mirror", default="https://deb.debian.org/debian")
    d.add_argument("--security", default="https://security.debian.org/debian-security")
    r = sub.add_parser("rpm")
    common(r)
    r.add_argument("--fedora", action="append")
    r.add_argument("--reposdir", help="read the system repositories from here (an empty directory: none)")
    c = sub.add_parser("ceiling")
    c.add_argument("--kind", choices=["deb", "rpm"], required=True)
    c.add_argument("--published", required=True)
    c.add_argument("--new", action="append", required=True)
    c.add_argument("--same-pass", type=words, default=[])
    s = sub.add_parser("source-deb")
    s.add_argument("--control", required=True)
    s.add_argument("--changelog", required=True)
    s.add_argument("--arch", action="append")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "deb":
            if not (a.new_dir or a.new_index):
                ap.error("deb needs --new-dir or --new-index")
            return deb_arm(a)
        if a.cmd == "rpm":
            if a.channel.endswith("/deb"):
                a.channel = a.channel[:-4] + "/rpm"
            return rpm_arm(a)
        if a.cmd == "ceiling":
            return ceiling_cmd(a)
        return source_deb(a)
    except Cannot as e:
        annotate("error", f"channel-installability could not take the measurement: {e}")
        return CANNOT


if __name__ == "__main__":
    sys.exit(main())
