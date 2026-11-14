#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""fill: the language packs' catalogs fill their own gaps in CI, or name them (Open-Mixer/.github#46).

Runs the catalogs' release gate (--gate, `omx-contract translate --check ...`). Green: nothing to do. Red: the problems
it names as `<catalog>: <key>: missing|stale|no catalog` are the entries to make; any other problem, and a stale entry
of a person (`"by": "human"`), is for a person and never written here. Then one of two outcomes, never silence:

  - this run can fill and push (a pull request of this repository, a router address and key, a runner that is not
    GitHub-hosted, a signing key, the checkout at the pull request's head): it runs --fill (`omx-contract translate ...`)
    with `--lang <xx> --model <alias>` once per language with a gap, holds the result to what it may change (only the
    entries named, only as `"by": "machine"` with a model; any other entry byte for byte what it was, or the catalogs are
    put back and the run is red), runs the gate again, commits the catalogs signed and pushes them to the pull
    request's branch. The run is then RED, with a line saying what was pushed: the check that counts is the one of the
    new head, which a push by a token that starts workflows (--push-token) starts and one by the job's own token does not
    (re-run the job on the new head);
  - or it fails naming each entry (catalog, key) and the exact command a person runs, with placeholders for the router's
    address and key, never a value. A fork never takes the first path, nor does a run with no key.

  fill.py --gate <cmd> --fill <cmd> --languages <file> --model <alias> [--no-push] [--remote <git remote>] [--expect-head <sha>]

Environment: OMX_TRANSLATE_URL, OMX_TRANSLATE_KEY (read by omx-contract translate), FILL_FORK=true (a pull request from a
fork), RUNNER_ENVIRONMENT (github-hosted refuses), GITHUB_HEAD_REF (the pull request's branch; none, nothing to push to),
SIGNING_KEY (armored; or SIGNING_KEY_ID of one already imported), SIGNING_PASSPHRASE, PUSH_TOKEN, COMMITTER_NAME, COMMITTER_EMAIL. Exit 0 whole, 1 a gap left or pushed, 2 usage.
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

INVALID = object()  # a catalog that is no JSON catalog
PROBLEM = re.compile(r"^(?P<file>\S+\.json): (?P<key>\S+): (?P<what>missing|stale|no catalog)(?P<rest>.*)$")


# a translate that never got an answer: the router was not reached (a refused or failed connection, no name, a
# timeout), which is the network's, not the model's
TRANSPORT = re.compile(r"[^\n]*(fetch failed|ECONNREFUSED|ECONNRESET|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EHOSTUNREACH|ENETUNREACH|"
                       r"socket hang up|operation was aborted|timed? ?out)[^\n]*", re.I)


def run(cmd, env=None):
    p = subprocess.run(cmd if isinstance(cmd, list) else ["bash", "-c", cmd], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, env=env)
    return p.returncode, p.stdout


def read(path):
    return open(path).read() if os.path.exists(path) else None


def entries(path):
    t = read(path)
    if t is None:
        return None
    try:
        return json.loads(t)["messages"]
    except (ValueError, KeyError, TypeError):
        return INVALID


def parse(output):
    """(fillable, for a person, others): (file, key, what) of each problem line"""
    fillable, person, other = [], [], []
    for line in output.splitlines():
        m = PROBLEM.match(line)
        if not m:
            if line.strip():
                other.append(line)
            continue
        item = (m["file"], m["key"], m["what"])
        (person if "a person's entry" in m["rest"] else fillable).append(item)
    return fillable, person, other


def command_for(fill, lang, model):
    return ("OMX_TRANSLATE_URL=<router base url> OMX_TRANSLATE_KEY=<router key> %s --lang %s --model %s"
            % (fill, lang, model))


def lang_of(path):
    return os.path.basename(path)[: -len(".json")]


def name_the_gaps(fillable, person, other, fill, model, why):
    print("langpacks fill: the catalogs have gaps and this run does not write them: %s" % why)
    for f, k, what in fillable:
        print("  %s: %s: %s" % (f, k, what))
    for f, k, what in person:
        print("  %s: %s: stale, a person's entry: a person reviews it" % (f, k))
    for line in other:
        print("  %s" % line)
    langs = sorted({lang_of(f) for f, _, _ in fillable})
    if langs:
        print("to make the entries, a person with the router runs, in this repository:")
        for l in langs:
            print("  " + command_for(fill, l, model))
        print("  (then commit the catalogs; a person's entries are never touched)")


def held_to(before, after, made, path):
    """why the catalogs after the fill are not what the fill may write, or None: an entry that is not named is unchanged,
    one that is named is a machine entry with a model"""
    if after is None:
        return "%s is gone" % path
    if after is INVALID:
        return "%s is no longer a catalog" % path
    problems = []
    for key, old in (before or {}).items():
        if key not in made and after.get(key) != old:
            who = "a person's entry" if (isinstance(old, str) or old.get("by") == "human") else "an entry it was not asked for"
            problems.append("%s: %s: %s was changed" % (path, key, who))
    for key in made:
        new = after.get(key)
        if new is not None and not (isinstance(new, dict) and new.get("by") == "machine" and new.get("model")):
            problems.append("%s: %s: made without its provenance (by machine, with a model)" % (path, key))
    return "; ".join(problems) or None


def git(*args, check=True, env=None):
    p = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, env=env)
    if check and p.returncode != 0:
        raise RuntimeError("git %s: %s" % (args[0], p.stdout.strip()))
    return p.stdout.strip()


def import_signing_key(env):
    """the armored key in SIGNING_KEY imported the way the import-gpg-key action does (loopback pinentry, an optional
    passphrase file), the fingerprint of its primary key returned; without SIGNING_KEY, SIGNING_KEY_ID as it is"""
    armored = env.get("SIGNING_KEY", "")
    if not armored:
        return env["SIGNING_KEY_ID"]
    home = os.path.expanduser("~/.gnupg") if not env.get("GNUPGHOME") else env["GNUPGHOME"]
    os.makedirs(home, mode=0o700, exist_ok=True)
    shown = subprocess.run(["gpg", "--batch", "--with-colons", "--import-options", "show-only", "--import"], input=armored,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    fpr, primary = "", False
    for line in shown.stdout.splitlines():
        f = line.split(":")
        if f[0] in ("pub", "sec"):
            primary = True
        elif f[0] == "fpr" and primary:
            fpr = f[9]
            break
    if not fpr:
        raise RuntimeError("no key readable from the signing key")
    imp = subprocess.run(["gpg", "--batch", "--import"], input=armored, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         universal_newlines=True)
    if imp.returncode != 0:
        raise RuntimeError("gpg could not import the signing key")
    with open(os.path.join(home, "gpg-agent.conf"), "a") as f:
        f.write("allow-loopback-pinentry\n")
    with open(os.path.join(home, "gpg.conf"), "a") as f:
        f.write("pinentry-mode loopback\n")
        if env.get("SIGNING_PASSPHRASE"):
            pf = os.path.join(home, "passphrase")
            with open(pf, "w") as g:
                g.write(env["SIGNING_PASSPHRASE"])
            os.chmod(pf, 0o600)
            f.write("passphrase-file %s\n" % pf)
    subprocess.run(["gpgconf", "--kill", "gpg-agent"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return fpr


def main(argv):
    ap = argparse.ArgumentParser(prog="fill.py", description=__doc__.split("\n")[0])
    ap.add_argument("--gate", required=True)
    ap.add_argument("--fill", required=True)
    ap.add_argument("--languages", required=True)
    ap.add_argument("--model", default="draft-prose")
    ap.add_argument("--no-push", action="store_true", help="make the entries, push nothing (tests)")
    ap.add_argument("--remote", default="origin")
    ap.add_argument("--expect-head", default="")
    a = ap.parse_args(argv)

    rc, out = run(a.gate)
    if rc == 0:
        print(out.strip())
        return 0
    fillable, person, other = parse(out)
    if not fillable:
        sys.stdout.write(out)
        print("langpacks fill: nothing here is a missing or stale entry of a machine: %s" % (
            "a person reviews the entries named above" if person else "the gate's own problems above are not gaps"))
        return rc or 1

    env = os.environ
    why = []
    if env.get("FILL_FORK") == "true":
        why.append("a pull request from a fork is never given the router key")
    if env.get("RUNNER_ENVIRONMENT") == "github-hosted":
        why.append("the runner is GitHub-hosted: the router answers in the cluster only")
    if not env.get("OMX_TRANSLATE_KEY"):
        why.append("no router key (the organisation secret OMX_ROUTER_KEY, passed as router-key)")
    if not env.get("OMX_TRANSLATE_URL"):
        why.append("no router address (router-url)")
    if not a.no_push:
        if not env.get("GITHUB_HEAD_REF"):
            why.append("this is not a pull request's branch to push to")
        if not (env.get("SIGNING_KEY_ID") or env.get("SIGNING_KEY")):
            why.append("no signing key (the organisation secret OPENMIXER_CI_SIGNING_KEY, passed as signing-key)")
        elif not shutil.which("gpg"):
            why.append("gpg is not installed on this runner (install gnupg2 before this step)")
        if a.expect_head and git("rev-parse", "HEAD", check=False) != a.expect_head:
            why.append("the checkout is not the pull request's head %s (check out github.event.pull_request.head.sha)" % a.expect_head[:12])
    if why:
        name_the_gaps(fillable, person, other, a.fill, a.model, "; ".join(why))
        return 1

    # the entries to make, by catalog; the catalogs as they are, to put back
    by_file = {}
    for f, k, _ in fillable:
        by_file.setdefault(f, []).append(k)
    before = {f: read(f) for f in by_file}
    parsed = {f: entries(f) for f in by_file}
    parsed = {f: (None if v is INVALID else v) for f, v in parsed.items()}
    langs = sorted({lang_of(f) for f in by_file})
    restore = lambda: [open(f, "w").write(t) if t is not None else os.path.exists(f) and os.remove(f) for f, t in before.items()]
    fill_env = dict(os.environ)
    for lang in langs:
        rc, out = run("%s --lang %s --model %s" % (a.fill, shlex.quote(lang), shlex.quote(a.model)), fill_env)
        sys.stdout.write(out)
        if rc != 0:
            restore()
            transport = TRANSPORT.search(out)
            if transport:
                where = "router not reached (%s, %s)" % (os.environ.get("OMX_TRANSLATE_URL", "no address"), transport.group(0).strip())
                print("langpacks fill: translate --lang %s: %s; the catalogs are put back" % (lang, where))
                name_the_gaps(fillable, person, other, a.fill, a.model, where)
            else:
                print("langpacks fill: translate --lang %s refused some entries; the catalogs are put back" % lang)
                name_the_gaps(fillable, person, other, a.fill, a.model, "the router's answer was refused (above)")
            return 1
    for f, keys in by_file.items():
        made = [k for k in keys if k != "-"]
        bad = held_to(parsed[f], entries(f), made, f)
        if bad:
            print("langpacks fill: the fill changed more than the entries it was asked for, so nothing is kept: %s" % bad)
            restore()
            name_the_gaps(fillable, person, other, a.fill, a.model, "a person's entry may never be written")
            return 1
    rc, out = run(a.gate)
    if rc != 0:
        print("langpacks fill: the check is still red after the fill; the catalogs are put back")
        restore()
        left_fill, left_person, left_other = parse(out)
        name_the_gaps(left_fill or fillable, left_person, left_other, a.fill, a.model, "the fill left these (above)")
        return 1

    made_list = ["%s: %s" % (f, k) for f, ks in sorted(by_file.items()) for k in sorted(ks)]
    model = a.model
    print("langpacks fill: made %d entr%s by %s:" % (len(made_list), "y" if len(made_list) == 1 else "ies", model))
    for line in made_list:
        print("  " + line)
    if a.no_push:
        return 0

    ref = env["GITHUB_HEAD_REF"]
    name, email = env.get("COMMITTER_NAME", "Pau Aliagas"), env.get("COMMITTER_EMAIL", "linuxnow@gmail.com")
    try:
        key_id = import_signing_key(env)
        git("add", "--", *sorted(by_file))
        msg = "catalogs: %d entr%s made by %s in %s\n\nMade by the language packs fill through omx-contract translate; translate --check is whole.\n\n%s\n" % (
            len(made_list), "y" if len(made_list) == 1 else "ies", model, ", ".join(langs), "\n".join(made_list))
        cenv = dict(os.environ, GIT_COMMITTER_NAME=name, GIT_COMMITTER_EMAIL=email)
        git("-c", "user.name=" + name, "-c", "user.email=" + email, "-c", "user.signingkey=" + key_id,
            "commit", "-q", "-S", "-m", msg, env=cenv)
        sha = git("rev-parse", "HEAD")
        # a remote that carries its own token must not meet the checkout's persisted one
        no_header = ["-c", "http.https://github.com/.extraheader="] if env.get("PUSH_TOKEN") else []
        git(*no_header, "push", "-q", a.remote, "HEAD:refs/heads/%s" % ref)
    except RuntimeError as e:
        print("langpacks fill: the entries were made but not pushed (%s)" % str(e).replace(env.get("PUSH_TOKEN", "\0"), "***"))
        name_the_gaps(fillable, person, other, a.fill, a.model, "the push to the branch failed (above)")
        return 1
    print("langpacks fill: pushed %s to %s with %d entries; the new head's check re-runs (a push by the job's own token starts"
          " no run: re-run the job on the new head). This run is red: its head is the one without them." % (sha[:12], ref, len(made_list)))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
