#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A release builds only a commit whose cluster/verify is success. Arms: the action's own
# self-test; the read door against a stub curl (a success passes; a failure, no status, a pending one, an HTTP 404 and
# a short sha are refused, each naming the repository and the sha); with the red rule taken out of check.sh, or the
# absent rule, the self-test goes red; and the wiring: the preflight job of build-rpm.yml and of build-deb.yml calls
# the action after its checkout and before release-preflight, on every tag or source-ref run whatever publish says,
# with bootstrap-only the one exemption.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
act=$here/.github/actions/verified-at-sha
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha=0123456789abcdef0123456789abcdef01234567

"$act/check.sh" --self-test >/dev/null || fail "the self-test of verified-at-sha is red"

# the read door, against a stub curl that answers $STUB_CODE with $STUB_BODY
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/bash
out=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; esac; shift; done
printf '%s' "$STUB_BODY" > "$out"
printf '%s' "$STUB_CODE"
STUB
chmod +x "$tmp/bin/curl"
run() {  # run <code> <statuses json array> [sha]
  STUB_CODE=$1 STUB_BODY="{\"statuses\":$2}" PATH=$tmp/bin:$PATH "$act/check.sh" Open-Mixer/x "${3:-$sha}" > "$tmp/out" 2>&1
}
named() { grep -q "Open-Mixer/x@$sha" "$tmp/out" || { cat "$tmp/out"; fail "$1 does not name the repository and sha"; }; }
run 200 '[{"context":"cluster/verify","state":"success"}]' || { cat "$tmp/out"; fail "a success cluster/verify was refused"; }
named "the pass"
run 200 '[{"context":"cluster/verify","state":"failure"}]' && fail "a failed cluster/verify passed"
named "the failure refusal"; grep -q 'cluster/verify is failure' "$tmp/out" || fail "the refusal does not name the context and its state"
run 200 '[]' && fail "a commit with no status passed"
named "the absent refusal"; grep -q 'no cluster/verify status' "$tmp/out" || fail "the absent refusal does not name the context"
run 200 '[{"context":"cluster/verify","state":"pending"}]' && fail "a pending cluster/verify passed"
named "the pending refusal"
run 404 '[]' && fail "an HTTP 404 passed"
named "the unread refusal"; grep -q 'HTTP 404' "$tmp/out" || fail "the unread refusal does not name the answer"
run 200 '[{"context":"cluster/verify","state":"success"}]' 0123456 && fail "a short sha passed"

# sabotage: each refusal rule taken out must turn the self-test red (the guard is not decoration)
cp "$act/check.sh" "$tmp/no-red.sh"
python3 -I - "$tmp/no-red.sh" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
s = t.replace("if red:\n", "if False:\n", 1)
assert s != t; open(p, "w").write(s)
PY
bash "$tmp/no-red.sh" --self-test > "$tmp/out" 2>&1 && fail "with the red rule removed the self-test still passes"
grep -q 'self-test FAILED' "$tmp/out" || { cat "$tmp/out"; fail "the sabotaged red rule did not fail by name"; }
cp "$act/check.sh" "$tmp/no-absent.sh"
python3 -I - "$tmp/no-absent.sh" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
s = t.replace('green = [c for c in contexts if seen.get(c) == "success"]', 'green = contexts[:1]', 1)
assert s != t; open(p, "w").write(s)
PY
bash "$tmp/no-absent.sh" --self-test > "$tmp/out" 2>&1 && fail "with every commit read as green the self-test still passes"

# the wiring, read from both workflows
python3 -I - "$here/.github/workflows/build-rpm.yml" "$here/.github/workflows/build-deb.yml" <<'PY'
import sys, yaml
for f in sys.argv[1:]:
    steps = yaml.safe_load(open(f))["jobs"]["preflight"]["steps"]
    uses = [str(s.get("uses", "")) for s in steps]
    idx = [i for i, u in enumerate(uses) if "/actions/verified-at-sha@" in u]
    assert len(idx) == 1, "%s: the preflight calls verified-at-sha %d times" % (f, len(idx))
    i = idx[0]
    co = [j for j, u in enumerate(uses) if u.startswith("actions/checkout@")]
    rp = [j for j, u in enumerate(uses) if "/actions/release-preflight@" in u]
    assert co and co[0] < i, "%s: verified-at-sha runs before the checkout it reads" % f
    assert rp and i < rp[0], "%s: verified-at-sha runs after release-preflight" % f
    s = steps[i]
    cond = s.get("if", "")
    for want in ("github.ref_type == 'tag'", "inputs.source-ref != ''", "!inputs.bootstrap-only"):
        assert want in cond, "%s: the step's condition lacks %s: %s" % (f, want, cond)
    assert "publish" not in cond, "%s: the step is skipped by publish; a tag run is judged whatever it publishes" % f
    w = s.get("with", {})
    assert "inputs.source-repository" in w.get("repository", "") and "github.repository" in w.get("repository", ""), f
print("wiring ok")
PY

echo "verified-at-sha: OK"
