#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""The plan of a unit run (release-unit.yml): read units/<unit>.txt, name one commit per member, and write the
build jobs of every dependency level, rpm and deb apart, as GitHub outputs.

    unit-plan.py <repo root> <unit> <ref> [<heads>] [--levels N] [--resolve-offline]

<ref> is the branch every member's commit is read from (devel for the continuous run and a testing dry run).
<heads> overrides members, space separated <repo>=<40-hex sha> (a lane proof on its PR heads, section 5.6). A
manifest reship=<sha> wins over the branch (section 5.1). Outputs: rpm-<n> and deb-<n> for n < N (a JSON array of
the members of level n, [] for none), members (a JSON object repo -> sha), and a table on stdout.

The defaults a manifest field leaves empty are read from build-rpm.yml and build-deb.yml themselves, never written
again here. --resolve-offline names commits from OFFLINE_HEADS (repo=sha ...) instead of the network: the tests.
"""
import json
import os
import re
import subprocess
import sys

import yaml

ORG = "Open-Mixer"
SHA = re.compile(r"^[0-9a-f]{40}$")
KEYS = {"level", "rpm", "deb", "rpm-bins", "deb-bins", "rpm-arches", "deb-arches", "channel-deps", "needs-mod-host",
        "deb-deps", "build-packages", "bootstrap", "reship"}


class Refused(Exception):
    pass


def defaults(root):
    out = {}
    for kind in ("rpm", "deb"):
        with open(os.path.join(root, ".github/workflows", f"build-{kind}.yml"), encoding="utf-8") as f:
            d = yaml.safe_load(f)
        on = d.get(True) or d.get("on")
        out[kind] = {k: v.get("default", "") for k, v in on["workflow_call"]["inputs"].items()}
    return out


def manifest(root, unit):
    path = os.path.join(root, "units", f"{unit}.txt")
    if not re.fullmatch(r"[a-z][a-z0-9-]*", unit) or not os.path.isfile(path):
        raise Refused(f"no unit manifest units/{unit}.txt")
    members = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            repo, *fields = line.split()
            m = {"repo": repo}
            for field in fields:
                k, sep, v = field.partition("=")
                if not sep or k not in KEYS:
                    raise Refused(f"units/{unit}.txt:{n}: '{field}' is not one of {' '.join(sorted(KEYS))}=<value>")
                m[k] = v
            for k in ("level", "rpm", "deb"):
                if k not in m:
                    raise Refused(f"units/{unit}.txt:{n}: {repo} has no {k}=")
            if not m["level"].isdigit():
                raise Refused(f"units/{unit}.txt:{n}: level={m['level']} is not a number")
            if "reship" in m and not SHA.match(m["reship"]):
                raise Refused(f"units/{unit}.txt:{n}: reship={m['reship']} is not a full commit")
            if any(x["repo"] == repo for x in members):
                raise Refused(f"units/{unit}.txt:{n}: {repo} is named twice")
            if members and int(m["level"]) < int(members[-1]["level"]):
                raise Refused(f"units/{unit}.txt:{n}: {repo} (level {m['level']}) comes after a level "
                              f"{members[-1]['level']} member: the manifest is in build order")
            members.append(m)
    if not members:
        raise Refused(f"units/{unit}.txt names no member")
    return members


def tip(repo, ref):
    offline = os.environ.get("OFFLINE_HEADS")
    if offline is not None:
        heads = dict(w.split("=", 1) for w in offline.split())
        if repo not in heads:
            raise Refused(f"{repo}: no {ref} (offline)")
        return heads[repo]
    out = subprocess.run(["git", "ls-remote", f"https://github.com/{ORG}/{repo}", f"refs/heads/{ref}"],
                         capture_output=True, text=True, timeout=60, check=False)
    sha = out.stdout.split()[0] if out.returncode == 0 and out.stdout.strip() else ""
    if not SHA.match(sha):
        raise Refused(f"{ORG}/{repo} has no branch {ref}")
    return sha


def jsonlist(csv):
    return json.dumps([x for x in csv.split(",") if x]) if csv else ""


def plan(root, unit, ref, heads, levels):
    d = defaults(root)
    members = manifest(root, unit)
    override = {}
    for w in heads.split():
        repo, sep, sha = w.partition("=")
        if not sep or not SHA.match(sha):
            raise Refused(f"heads: '{w}' is not <repo>=<full commit>")
        if not any(m["repo"] == repo for m in members):
            raise Refused(f"heads: {repo} is not a member of {unit}")
        override[repo] = sha
    sha = {}
    why = {}
    for m in members:
        r = m["repo"]
        if r in override:
            sha[r], why[r] = override[r], "head"
        elif "reship" in m:
            sha[r], why[r] = m["reship"], "reship"
        else:
            sha[r], why[r] = tip(r, ref), ref
    top = max(int(m["level"]) for m in members)
    if top >= levels:
        raise Refused(f"units/{unit}.txt reaches level {top}, and release-unit.yml has jobs for levels 0-{levels - 1}")
    out = {f"{k}-{n}": [] for k in ("rpm", "deb") for n in range(levels)}
    for m in members:
        r = m["repo"]
        boot = ""
        if m.get("bootstrap"):
            src, sep, pkg = m["bootstrap"].partition(":")
            if not sep or src not in sha:
                raise Refused(f"{r}: bootstrap={m['bootstrap']} is not <member repo>:<package>")
            boot = f"{ORG}/{src}@{sha[src]}:{pkg}"
        for kind in ("rpm", "deb"):
            src = m[kind]
            if src == "-":
                continue
            job = {
                "repo": f"{ORG}/{r}", "sha": sha[r], "name": src,
                "bins": " ".join(x for x in m.get(f"{kind}-bins", "").split(",") if x),
                "arches": jsonlist(m.get(f"{kind}-arches", "")) or d[kind]["arch-matrix"],
                "channel-deps": m.get("channel-deps", "true") == "true",
                "build-packages": " ".join(x for x in m.get("build-packages", "").split(",") if x),
                "bootstrap": boot,
            }
            if kind == "rpm":
                job["needs-mod-host"] = m.get("needs-mod-host", "false") == "true"
            else:
                job["deps"] = " ".join(x for x in m.get("deb-deps", "").split(",") if x)
            out[f"{kind}-{m['level']}"].append(job)
    table = [f"{m['level']:>5}  {m['repo']:<26} {sha[m['repo']][:12]}  ({why[m['repo']]})  rpm={m['rpm']} deb={m['deb']}"
             for m in members]
    return out, {m["repo"]: sha[m["repo"]] for m in members}, table


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    levels = 8
    for a in argv:
        if a.startswith("--levels="):
            levels = int(a.split("=", 1)[1])
    if len(args) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    root, unit, ref = args[:3]
    heads = args[3] if len(args) == 4 else ""
    try:
        out, members, table = plan(root, unit, ref, heads, levels)
    except Refused as e:
        print(f"::error::{e}")
        return 1
    print("level  member                     commit        from      sources")
    print("\n".join(table))
    lines = [f"{k}={json.dumps(v)}" for k, v in out.items()] + [f"members={json.dumps(members)}"]
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    else:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
