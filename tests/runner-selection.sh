#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Runner selection of the package builds: a real release (a tag push or a release event) of a PUBLIC repository
# builds its x86 jobs on GitHub-hosted ubuntu-latest, so a release never queues behind pull-request CI on the
# self-hosted pool; aarch64/arm64 keeps ubuntu-24.04-arm; a pull request or a branch push keeps the caller's runner;
# a PRIVATE repository always keeps its own runner, so nothing private runs on a GitHub-hosted runner.
# The check evaluates every runs-on expression of the matrix and single-runner jobs for each case.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/eval.py" <<'PY'
import re, sys, yaml

class C(dict):
    def __getattr__(self, k): return self.get(k)

def build(case):
    ev, ref, private, fork, arch = case
    pr = C(head=C(repo=C(full_name="x/y" if fork else "o/r", fork=fork)))
    event = C(repository=C(private=private), pull_request=pr)
    return dict(github=C(event_name=ev, ref=ref, repository="o/r", event=event),
                inputs=C(runner="arc-freemixer"), vars=C(OMX_RUNNER="arc-freemixer"), matrix=C(arch=arch))

def evaluate(expr, env):
    e = expr.strip()
    assert e.startswith("${{") and e.endswith("}}"), expr
    e = e[3:-2]
    e = re.sub(r"startsWith\(([^,]+),\s*([^)]+)\)", r"(\1).startswith(\2)", e)
    e = e.replace("||", " or ").replace("&&", " and ").replace("!=", " != ")
    e = e.replace("false", "False").replace("true", "True")
    for k in ("github", "inputs", "vars", "matrix"):
        e = re.sub(rf"\b{k}\.", f"{k}.", e)
    return eval(e, {"__builtins__": {}}, env)

f, ev, ref, private, fork, arch, want = sys.argv[1:8]
case = (ev, ref, private == "private", fork == "fork", arch)
d = yaml.safe_load(open(f))
n = 0
for name, job in d["jobs"].items():
    ro = str(job.get("runs-on", ""))
    if "inputs.runner" not in ro and "vars.OMX_RUNNER" not in ro:
        continue
    a = arch
    if arch == "ARM":
        m = re.search(r"matrix\.arch == '(aarch64|arm64)'", ro)
        if not m:
            continue
        a = m.group(1)
    got = evaluate(ro, build(case[:4] + (a,)))
    n += 1
    assert got == want, f"{f}: job {name} ({ev} {ref} {private} {fork} {arch}) -> {got!r}, want {want!r}"
assert n or arch == "ARM", f"{f}: no caller-chosen runs-on found"
PY
cases() { # name event ref visibility fork arch want
  cat <<'C'
public-tag push refs/tags/v1.2.3 public nofork x86 ubuntu-latest
public-release release refs/tags/v1.2.3 public nofork x86 ubuntu-latest
public-tag-arm push refs/tags/v1.2.3 public nofork ARM ubuntu-24.04-arm
public-pr pull_request refs/pull/5/merge public nofork x86 arc-freemixer
public-branch push refs/heads/main public nofork x86 arc-freemixer
public-fork-pr pull_request refs/pull/5/merge public fork x86 ubuntu-latest
private-tag push refs/tags/v1.2.3 private nofork x86 arc-freemixer
private-release release refs/tags/v1.2.3 private nofork x86 arc-freemixer
private-pr pull_request refs/pull/5/merge private nofork x86 arc-freemixer
C
}
run() { # file
  local f=$1 n ev ref vis fork arch want a
  while read -r n ev ref vis fork arch want; do
    a=$arch; [ "$a" = x86 ] && a=x86_64
    python3 -I "$t/eval.py" "$f" "$ev" "$ref" "$vis" "$fork" "$a" "$want" >"$t/out" 2>&1 \
      || { echo "FAIL $(basename "$f") $n: $(tail -1 "$t/out")"; return 1; }
    echo "ok   $(basename "$f") $n"
  done < <(cases)
}
# an ARM case only reads the arm jobs; the x86_64 jobs of the same file are covered by the other cases
for w in build-rpm build-deb surge-xt-rpm surge-xt-deb pugl-nanovg-rpm pugl-nanovg-deb mod-host-protocol-rpm \
         mod-host-protocol-deb clap-headers-deb; do
  run "$here/.github/workflows/$w.yml" || fail=1
done
# sabotage: with the release clause taken out, a public tag no longer reaches ubuntu-latest and the check goes red
sed "s/(startsWith(github.ref, 'refs\/tags\/') || github.event_name == 'release') \&\& github.event.repository.private == false \&\& 'ubuntu-latest' || //" \
  "$here/.github/workflows/build-rpm.yml" > "$t/build-rpm.yml"
if run "$t/build-rpm.yml" >/dev/null 2>&1; then echo "FAIL sabotage: no release clause passes"; fail=1
else echo "ok   sabotage: no release clause is red"; fi
# sabotage: a release clause that ignores the repository's visibility sends a private tag to a hosted runner
sed "s/ \&\& github.event.repository.private == false//" "$here/.github/workflows/build-rpm.yml" > "$t/build-rpm.yml"
if run "$t/build-rpm.yml" >/dev/null 2>&1; then echo "FAIL sabotage: private tag on hosted passes"; fail=1
else echo "ok   sabotage: a private tag on a hosted runner is red"; fi
exit "$fail"
