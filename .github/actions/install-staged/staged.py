# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""The decisions of install-staged, kept out of the shell so tests/staged-packages.sh can run them offline.

  staged.py vercmp <rpm|deb> <a> <b>
      prints -1, 0 or 1, rpm's or dpkg's ordering
  staged.py select --kind <rpm|deb> --target <fc44.x86_64|trixie.amd64> --repo <owner/repo> --version <v>
                   [--packages a,b] --release <release.json>
      prints name<TAB>version<TAB>url<TAB>file for each staged file the container takes; refuses (exit 1, the reason
      on stderr) a release that is not a prerelease, a target with no file, a named package that is absent, and a
      file whose upstream version is not <v>
  staged.py floor --kind <rpm|deb> --tree <dir> <name> <version>
      refuses (exit 1) a staged version outside a floor or ceiling the consumer's packaging/*.spec (rpm) or
      debian/control (deb) puts on <name>; silent when the consumer names no range for it
"""
import argparse, glob, json, os, re, sys


def _rpm_segcmp(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        while i < len(a) and not (a[i].isascii() and a[i].isalnum()) and a[i] not in "~^":
            i += 1
        while j < len(b) and not (b[j].isascii() and b[j].isalnum()) and b[j] not in "~^":
            j += 1
        ca = a[i] if i < len(a) else ""
        cb = b[j] if j < len(b) else ""
        if ca == "~" or cb == "~":
            if ca != "~":
                return 1
            if cb != "~":
                return -1
            i += 1; j += 1
            continue
        if ca == "^" or cb == "^":
            if not ca:
                return -1
            if not cb:
                return 1
            if ca != "^":
                return 1
            if cb != "^":
                return -1
            i += 1; j += 1
            continue
        if not ca or not cb:
            break
        num = ca.isdigit()
        test = (lambda c: c.isdigit()) if num else (lambda c: c.isascii() and c.isalpha())
        si = i
        while i < len(a) and test(a[i]):
            i += 1
        sj = j
        while j < len(b) and test(b[j]):
            j += 1
        s1, s2 = a[si:i], b[sj:j]
        if not s2:
            return 1 if num else -1
        if num:
            s1, s2 = s1.lstrip("0"), s2.lstrip("0")
            if len(s1) != len(s2):
                return 1 if len(s1) > len(s2) else -1
        if s1 != s2:
            return 1 if s1 > s2 else -1
    ea, eb = i >= len(a), j >= len(b)
    if ea and eb:
        return 0
    return -1 if ea else 1


def rpm_cmp(a, b):
    """EVR ordering; a side without a release compares on epoch and version only, as an rpm dependency does."""
    def split(s):
        e = "0"
        if ":" in s:
            e, s = s.split(":", 1)
        v, r = s.rsplit("-", 1) if "-" in s else (s, None)
        return int(e or 0), v, r
    ea, va, ra = split(a)
    eb, vb, rb = split(b)
    if ea != eb:
        return 1 if ea > eb else -1
    c = _rpm_segcmp(va, vb)
    if c or ra is None or rb is None:
        return c
    return _rpm_segcmp(ra, rb)


def _deb_order(c):
    if not c or c.isdigit():
        return 0
    if c.isascii() and c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _deb_verrev(a, b):
    i = j = 0
    while i < len(a) or j < len(b):
        first = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _deb_order(a[i] if i < len(a) else "")
            bc = _deb_order(b[j] if j < len(b) else "")
            if ac != bc:
                return ac - bc
            i += 1; j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and j < len(b) and a[i].isdigit() and b[j].isdigit():
            if not first:
                first = ord(a[i]) - ord(b[j])
            i += 1; j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first:
            return first
    return 0


def deb_cmp(a, b):
    def split(s):
        e, _, rest = s.partition(":") if ":" in s else ("0", "", s)
        u, r = rest.rsplit("-", 1) if "-" in rest else (rest, "")
        return int(e or 0), u, r
    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return 1 if ea > eb else -1
    c = _deb_verrev(ua, ub) or _deb_verrev(ra, rb)
    return (c > 0) - (c < 0)


CMP = {"rpm": rpm_cmp, "deb": deb_cmp}
SNAPSHOT = re.compile(r"[+~.]git[0-9a-f]+$")
DEBUG = re.compile(r"-(debuginfo|debugsource|dbgsym)$")


def parse(kind, f):
    """(name, full version, upstream version) of a staged file name, or None when it is not a package of kind."""
    if kind == "rpm":
        if not f.endswith(".rpm") or f.endswith(".src.rpm"):
            return None
        nvr = f[:-4].rsplit(".", 1)[0]
        parts = nvr.rsplit("-", 2)
        if len(parts) != 3:
            return None
        n, v, r = parts
        return n, f"{v}-{r}", v
    if not f.endswith(".deb"):
        return None
    parts = f[:-4].split("_")
    if len(parts) != 4:
        return None
    n, v = parts[0], parts[1]
    up = v.split(":", 1)[-1]
    if "-" in up:
        up = up.rsplit("-", 1)[0]
    return n, v, SNAPSHOT.sub("", up)


def takes(kind, target, f):
    rel, arch = target.split(".", 1)
    if kind == "rpm":
        return f.endswith(f".{rel}.{arch}.rpm") or f.endswith(f".{rel}.noarch.rpm")
    return f.endswith(f"_{rel}_{arch}.deb") or f.endswith(f"_{rel}_all.deb")


def die(msg):
    print(f"::error::install-staged: {msg}", file=sys.stderr)
    sys.exit(1)


def select(a):
    rel = json.load(open(a.release))
    tag = rel.get("tag_name", f"staged-v{a.version}")
    if not rel.get("prerelease"):
        die(f"{a.repo} {tag} is not a prerelease: a staged tag never names a real release")
    want = [p for p in (a.packages or "").split(",") if p]
    chosen, wrong = [], []
    for asset in rel.get("assets", []):
        f = asset["name"]
        if not takes(a.kind, a.target, f):
            continue
        p = parse(a.kind, f)
        if not p:
            continue
        n, full, up = p
        if DEBUG.search(n) or (want and n not in want):
            continue
        if up != a.version:
            wrong.append(f"{f} is version {up}, not {a.version}")
            continue
        chosen.append((n, full, asset["browser_download_url"], f))
    if wrong:
        die(f"{a.repo} {tag} holds files of another version: " + "; ".join(wrong))
    if not chosen:
        die(f"{a.repo} {tag} has no {a.kind.upper()} for {a.target}" + (f" among {','.join(want)}" if want else ""))
    missing = [p for p in want if p not in {c[0] for c in chosen}]
    if missing:
        die(f"{a.repo} {tag} has no {a.target} package {' '.join(missing)}")
    for c in chosen:
        print("\t".join(c))


OPS = {">=": lambda c: c >= 0, ">": lambda c: c > 0, ">>": lambda c: c > 0, "=": lambda c: c == 0,
       "<=": lambda c: c <= 0, "<": lambda c: c < 0, "<<": lambda c: c < 0}


def floor(a):
    name = re.escape(a.name)
    if a.kind == "rpm":
        files = sorted(glob.glob(os.path.join(a.tree, "packaging", "*.spec")))
        rx = re.compile(r"(?<![\w.+-])" + name + r"(?:%\{\?_isa\})?\s*(>=|<=|=|<|>)\s*([^\s)]+)")
    else:
        files = [p for p in [os.path.join(a.tree, "debian", "control")] if os.path.isfile(p)]
        rx = re.compile(r"(?<![\w.+-])" + name + r"\s*\(\s*(>=|<=|>>|<<|=)\s*([^)\s]+)\s*\)")
    bad = []
    for path in files:
        for op, ver in rx.findall(open(path).read()):
            if "%" in ver or "$" in ver:
                continue
            if not OPS[op](CMP[a.kind](a.version, ver)):
                bad.append(f"{a.name} {a.version} does not meet {op} {ver} ({os.path.relpath(path, a.tree)})")
    if bad:
        die("; ".join(bad))


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "vercmp":
        print(CMP[sys.argv[2]](sys.argv[3], sys.argv[4]))
        return
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    for o in ("kind", "target", "repo", "version", "release"):
        s.add_argument(f"--{o}", required=True)
    s.add_argument("--packages", default="")
    f = sub.add_parser("floor")
    f.add_argument("--kind", required=True)
    f.add_argument("--tree", required=True)
    f.add_argument("name")
    f.add_argument("version")
    a = ap.parse_args()
    {"select": select, "floor": floor}[a.cmd](a)


if __name__ == "__main__":
    main()
