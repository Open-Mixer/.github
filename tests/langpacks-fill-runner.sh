#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Owner ruling 2026-11-20: vars.OMX_RUNNER stays ubuntu-latest for everything; ONLY the language-pack fill job names the
# self-hosted label (arc-freemixer, the ARC scale set; build-rpm.yml and public-sources-check.yml name it the same way).
# The fill workflow's job runs on that label, never reads vars.OMX_RUNNER, always hands its container the cluster DNS
# (no condition: it only ever runs on our pool), and never runs for a fork or outside a pull request. The caller's
# check-only job stays on vars.OMX_RUNNER with no DNS (the langpacks action documents that split).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/check.py" <<'PY'
import sys, yaml
f = sys.argv[1]
d = yaml.safe_load(open(f))
j = d["jobs"]["fill"]
assert j["runs-on"] == "arc-freemixer", f"fill runs-on is {j['runs-on']!r}, not the self-hosted label arc-freemixer"
opts = str(j["container"]["options"])
assert "${{" not in opts, f"the cluster DNS is conditional: {opts}"
assert "--dns 10.43.0.10" in opts, f"the cluster DNS is not handed to the fill container: {opts}"
cond = " ".join(str(j.get("if", "")).split())
want = "github.event_name == 'pull_request' && !github.event.pull_request.head.repo.fork || github.event_name == 'workflow_dispatch'"
assert cond == want, f"the fill's job if is not the same-repository pull request or a dispatch: {cond!r}"
steps = j["steps"]
chk = [i for i, x in enumerate(steps) if "pulls?head=" in str(x.get("run", "")) and "state=open" in str(x.get("run", ""))]
fill = [i for i, x in enumerate(steps) if "actions/langpacks@" in str(x.get("uses", ""))]
assert chk and fill and chk[0] < fill[0], "the open-pull-request check does not come before the fill"
assert "steps.pr.outputs.head-sha" in str(steps[fill[0]]["with"].get("dispatch-head")), "the fill is not given the proved head sha"
# the caller's packages are OpenMixer's (omx-contract-devel): installed only once the OpenMixer channel is added (.github#333)
add = [i for i, x in enumerate(steps) if "actions/add-openmixer@" in str(x.get("uses", ""))]
pk = [i for i, x in enumerate(steps) if "inputs.packages" in str(x.get("run", ""))]
assert add and len(pk) == 1 and add[0] < pk[0] < fill[0], f"the caller's packages install at step {pk}, not once after the channel (step {add}) and before the fill"
# one language of a whole new catalog is ~1000 keys in batches of 40 through the router (omx-plugins#124: es alone ran
# past 45 minutes): the job's time is one language's at the least, since a language is pushed only once it is whole
tm = j.get("timeout-minutes", 360)
assert isinstance(tm, int) and tm >= 240, f"the fill's timeout-minutes is {tm}: a language of a new catalog does not fit"
print("ok   langpacks-fill.yml fill")
PY
check() { python3 -I "$t/check.py" "$1"; }
w=$here/.github/workflows/langpacks-fill.yml
check "$w" || fail=1
grep -q 'langpacks-fill.yml fill' "$here/tests/fixtures/needs-private-jobs.txt" || { echo "FAIL the fill job is not listed as needing a private runner"; fail=1; }
grep -q 'vars.OMX_RUNNER' "$w" && { echo "FAIL the fill workflow reads vars.OMX_RUNNER"; fail=1; }
sab() { # name sed-expr
  sed "$2" "$w" > "$t/s.yml"; cmp -s "$w" "$t/s.yml" && { echo "FAIL sabotage $1: nothing to break"; fail=1; return; }
  if check "$t/s.yml" >/dev/null 2>&1; then echo "FAIL sabotage: $1 passes"; fail=1; else echo "ok   sabotage: $1 is red"; fi
}
sab "the fill on the organisation variable" 's/^    runs-on: arc-freemixer/    runs-on: ${{ vars.OMX_RUNNER || '"'ubuntu-latest'"' }}/'
sab "the fill on a hosted label" 's/^    runs-on: arc-freemixer/    runs-on: ubuntu-latest/'
sab "a conditional cluster DNS" 's/options: --dns 10.43.0.10/options: ${{ vars.OMX_RUNNER \&\& '"'--dns 10.43.0.10'"' }} --dns 10.43.0.10/'
sab "a dispatch fill with no open-pull-request check" 's/pulls?head=/pulls?x=/'
sab "a fill that is dispatch only" "s/if: github.event_name == 'pull_request' \&\& !github.event.pull_request.head.repo.fork || /if: /"
sab "a fill not told the proved head" 's/dispatch-head: /x-head: /'
sab "no cluster DNS" 's/--dns 10.43.0.10 //'
sab "a fill for a fork" "s/ && !github.event.pull_request.head.repo.fork//"
sab "the caller's packages before the channel" 's/^      - run: dnf install -y --setopt=install_weak_deps=False git python3 nodejs gnupg2$/& ${{ inputs.packages }}/'

# fill.py refuses by name a push to the default branch or a kept name (main, openmixer-v*, release/*, settle/*), on the pull
# request (GITHUB_HEAD_REF) and the dispatch (GITHUB_REF_NAME, which the action hands over as GITHUB_HEAD_REF) path alike
cat > "$t/kept.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fill", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for r in ("main", "openmixer-v1", "openmixer-v2", "release/3.1", "settle/12", "trunk"):
    assert m.kept_ref(r, "trunk"), f"{r} is not refused"
for r in ("lane/langpacks", "lane/main-fix", "feature", "releases/x", "mainline"):
    assert not m.kept_ref(r, "trunk"), f"{r} is refused"
print("ok   fill.py refuses the default branch and every kept name, allows lane/*")
PY
fillpy=$here/.github/actions/langpacks/fill.py
python3 -I "$t/kept.py" "$fillpy" || fail=1
ksab() { # name sed-expr
  sed "$2" "$fillpy" > "$t/fill-s.py"; cmp -s "$fillpy" "$t/fill-s.py" && { echo "FAIL sabotage $1: nothing to break"; fail=1; return; }
  if python3 -I "$t/kept.py" "$t/fill-s.py" >/dev/null 2>&1; then echo "FAIL sabotage: $1 passes"; fail=1; else echo "ok   sabotage: $1 is red"; fi
}
ksab "the kept-name check removed" 's/^    return bool(ref) and (ref == default.*/    return False/'
ksab "the release branches no longer kept" 's/"openmixer-v", "release\/", "settle\/"/"openmixer-v", "settle\/"/'
ksab "the default branch no longer kept" 's/ref == default or //'
grep -q 'kept_ref(env\["GITHUB_HEAD_REF"\]' "$fillpy" || { echo "FAIL fill.py does not apply kept_ref to the push target"; fail=1; }
# The dispatch check, run for real (its inline script is lifted out of the workflow, the API is a fixture server). %7 ruling
# 2026-11-20 (plugin-qualify run 44796868078): a dispatch on a KEPT ref (default branch, main, openmixer-v*, release/*,
# settle/*) SKIPS the fill cleanly, exit 0, output kept=true and one named line; every later step runs only when kept is not
# true, so nothing is checked out, filled or pushed there. A lane ref with ONE open same-repository pull request still fills
# (head-sha output, no kept); a lane ref with none still fails by name (a misuse, not a release).
cat > "$t/extract.py" <<'PY'
import sys, textwrap, yaml
d = yaml.safe_load(open(sys.argv[1]))
st = [x for x in d["jobs"]["fill"]["steps"] if x.get("id") == "pr"]
assert len(st) == 1, "no single step with id pr"
run = st[0]["run"]
body = run.split("<<'PYEOF'\n", 1)[1].rsplit("PYEOF", 1)[0]
sys.stdout.write(textwrap.dedent(body))
PY
cat > "$t/api.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ref = self.path.split("head=owner:", 1)[1].split("&", 1)[0] if "head=owner:" in self.path else ""
        prs = []
        if ref == "lane/with-pr":
            prs = [{"number": 7, "head": {"sha": "abc123", "ref": ref, "repo": {"full_name": "owner/repo", "fork": False}}, "base": {"ref": "trunk"}}]
        b = json.dumps(prs).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
dispatch_check() { # workflow-file ref -> sets rc, out (stdout+stderr), outputs file content
  python3 -I "$t/extract.py" "$1" > "$t/step.py" || { echo "FAIL cannot lift the dispatch check out of $1"; fail=1; return 1; }
  : > "$t/gh_out"
  rc=0; out=$(env -i PATH="$PATH" GITHUB_REF_NAME="$2" GITHUB_REF_TYPE=branch GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_OWNER=owner \
    GITHUB_API_URL="http://127.0.0.1:$port" GH_TOKEN=x DEFAULT_BRANCH=trunk GITHUB_OUTPUT="$t/gh_out" python3 -I "$t/step.py" 2>&1) || rc=$?
  outputs=$(cat "$t/gh_out")
}
python3 -I "$t/api.py" > "$t/port" & apid=$!
trap 'kill "$apid" 2>/dev/null; rm -rf "$t"' EXIT
for _ in $(seq 50); do [ -s "$t/port" ] && break; sleep 0.1; done
port=$(cat "$t/port")
nokept() { grep -q 'kept=true' <<<"$outputs" && return 1; return 0; }
case_all() { # workflow-file tag
  local w=$1 n=$2 r
  for r in release/plugin-qualify-0.20.7 settle/12 openmixer-v1 main trunk; do
    dispatch_check "$w" "$r" || continue
    if [ "$rc" = 0 ] && grep -q '^kept=true$' <<<"$outputs" && grep -qF "fill skipped: $r is a kept ref; no strings are filled on a release branch" <<<"$out"; then echo "ok   $n: a dispatch on $r skips cleanly"; else echo "FAIL $n: a dispatch on $r: rc=$rc outputs=[$outputs] out=[$out]"; fail=1; fi
  done
  dispatch_check "$w" lane/with-pr
  if [ "$rc" = 0 ] && grep -q '^head-sha=abc123$' <<<"$outputs" && nokept; then echo "ok   $n: a lane with an open pull request still fills"; else echo "FAIL $n: lane with a PR: rc=$rc outputs=[$outputs] out=[$out]"; fail=1; fi
  dispatch_check "$w" lane/no-pr
  if [ "$rc" != 0 ] && nokept && grep -q '0 open pull requests' <<<"$out"; then echo "ok   $n: a lane with no open pull request still fails by name"; else echo "FAIL $n: lane without a PR: rc=$rc outputs=[$outputs] out=[$out]"; fail=1; fi
}
case_all "$w" "fill"
# every step after the check is guarded by it, so the push stays behind the proved branch
python3 -I - "$w" <<'PY' || fail=1
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["fill"]["steps"]
i = [k for k, x in enumerate(steps) if x.get("id") == "pr"][0]
for x in steps[i + 1:]:
    assert "steps.pr.outputs.kept != 'true'" in str(x.get("if", "")), f"step after the check is not skipped on a kept ref: {x}"
print("ok   every step after the dispatch check is skipped on a kept ref")
PY
ssab() { # name sed-expr: the workflow with a fault must make the cases red
  sed "$2" "$w" > "$t/ss.yml"; cmp -s "$w" "$t/ss.yml" && { echo "FAIL sabotage $1: nothing to break"; fail=1; return; }
  if ( fail=0; case_all "$t/ss.yml" sab >/dev/null 2>&1; [ "$fail" = 0 ] ) && python3 -I - "$t/ss.yml" >/dev/null 2>&1 <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["fill"]["steps"]
i = [k for k, x in enumerate(steps) if x.get("id") == "pr"][0]
for x in steps[i + 1:]:
    assert "steps.pr.outputs.kept != 'true'" in str(x.get("if", ""))
PY
  then echo "FAIL sabotage: $1 passes"; fail=1; else echo "ok   sabotage: $1 is red"; fi
}
ssab "a skip on ANY ref (a lane with a pull request no longer fills)" 's/^          if ref == e\["DEFAULT_BRANCH"\] or ref == "main" or ref.startswith/          if True or ref.startswith/'
ssab "a skip that does not say so" 's/fill skipped: /fill: /'
ssab "a skip that still fails" 's/sys.exit(0)  # kept/sys.exit(1)  # kept/'
ssab "a push step not guarded by the skip" "s/steps.pr.outputs.kept != 'true'/true/"
exit "$fail"
