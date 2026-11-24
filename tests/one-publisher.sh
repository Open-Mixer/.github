#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# One publisher per tag (.github#130, docs/release-operations.md "One publisher per tag"). Proves, offline:
#   - staged-holds/holds.py, on stub channel trees: staging holds a build of this version of this commit (rpm and deb,
#     names with and without the commit time, a glob name, a short or full commit), and does not for another commit,
#     another version, another package, a file in the channel root only, or the other kind; with --promoter, only when
#     the checkout has a workflow that calls promote-staged.yml;
#   - the decision, for every case (staged or not, a promote caller or not): a v* tag starts exactly one publisher when
#     the repository calls promote-staged.yml, and the release workflows alone when it does not;
#   - the workflows, rendered: build-rpm.yml and build-deb.yml ask staged-holds with the promoter check before the
#     release preflight, on a tag push alone, skip the preflight and plan no cell when it holds; promote-staged.yml's
#     find job asks it on a tag push alone and its publish jobs run only when it holds.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
holds=$here/.github/actions/staged-holds/holds.py
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

SHA=5f455d3c0ffee5f455d3c0ffee5f455d3c0ffee0
tree() { # the paths of a stub channel: omx-lib 3.14.0 staged of 5f455d3 (with the commit time) and of 0badc0d, 3.13.0 served
    cat <<EOF
staging/rpm/fedora/45/x86_64/omx-lib-3.14.0-1.git20261124093000.5f455d3.fc45.x86_64.rpm
staging/rpm/fedora/45/x86_64/omx-lib-devel-3.14.0-1.git20261124093000.5f455d3.fc45.x86_64.rpm
staging/rpm/fedora/45/SRPMS/omx-lib-3.14.0-1.git20261124093000.5f455d3.fc45.src.rpm
staging/rpm/fedora/45/x86_64/omx-lib-3.14.0-1.git0badc0d.fc45.x86_64.rpm
staging/deb/debian/trixie/arm64/libomx-lib0_3.14.0+git5f455d3_arm64.deb
staging/deb/debian/trixie/arm64/libomx-lib-dev_3.14.0+git5f455d3_arm64.deb
rpm/fedora/45/x86_64/omx-lib-3.13.0-1.fc45.x86_64.rpm
rpm/fedora/45/x86_64/omx-other-3.14.0-1.fc45.x86_64.rpm
deb/debian/trixie/arm64/libomx-lib0_3.13.0_arm64.deb
EOF
}
tree > "$t/tree"
grep -v '^staging/' "$t/tree" > "$t/root-only"

answer() { # <expected true|false> <what> <args>...: holds.py prints holds=<expected>
    local want=$1 what=$2; shift 2
    local got
    got=$(python3 -I "$holds" "$@" < "${IN:-$t/tree}" | sed -n 's/^holds=//p')
    [ "$got" = "$want" ] || fail "$what: holds=$got, wanted $want"
}
answer true  "rpm of the commit, full sha"            rpm 3.14.0 "$SHA" omx-lib
answer true  "rpm of the commit, short sha"           rpm 3.14.0 5f455d3 omx-lib-devel
answer true  "rpm of the commit, a glob name"         rpm 3.14.0 "$SHA" 'omx-lib*'
answer true  "deb of the commit"                      deb 3.14.0 "$SHA" libomx-lib0 libomx-lib-dev
answer true  "rpm of the other staged commit"         rpm 3.14.0 0badc0d omx-lib
answer false "rpm of a commit staging does not hold"  rpm 3.14.0 1234567 omx-lib
answer false "another version"                        rpm 3.15.0 "$SHA" omx-lib
answer false "another package"                        rpm 3.14.0 "$SHA" omx-other
answer false "the other kind"                         deb 3.14.0 "$SHA" omx-lib
answer false "a deb staged only for another commit"   deb 3.14.0 0badc0d libomx-lib0
IN=$t/root-only answer false "the channel root alone (the version served, not staged)" rpm 3.14.0 "$SHA" omx-other
ok "holds.py: staging holds a build of this version of this commit, and nothing else counts"

# --promoter: a checkout with a workflow that calls promote-staged.yml, and one without
mkdir -p "$t/with/.github/workflows" "$t/without/.github/workflows"
cat > "$t/with/.github/workflows/promote.yml" <<'EOF'
on: { push: { tags: ['v*'] } }
jobs:
  promote:
    uses: Open-Mixer/.github/.github/workflows/promote-staged.yml@openmixer-v1
EOF
cat > "$t/without/.github/workflows/release.yml" <<'EOF'
# promote-staged.yml is not called here; a comment naming it is not a caller
on: { push: { tags: ['v*'] } }
jobs:
  rpm:
    uses: Open-Mixer/.github/.github/workflows/build-rpm.yml@openmixer-v1
EOF
answer true  "staged, with a promote caller"    --promoter "$t/with" rpm 3.14.0 "$SHA" omx-lib
answer false "staged, with no promote caller"   --promoter "$t/without" rpm 3.14.0 "$SHA" omx-lib
answer false "not staged, with a promote caller" --promoter "$t/with" rpm 3.14.0 1234567 omx-lib
ok "holds.py --promoter: only a repository that calls promote-staged.yml hands its tag to the promotion"

# ---- the decision: exactly one publisher per tag. The release workflows publish unless holds --promoter answers true;
# the promotion exists only in a repository with a caller and publishes when holds answers true.
for staged in 5f455d3 1234567; do
    for repo in with without; do
        build=$(python3 -I "$holds" --promoter "$t/$repo" rpm 3.14.0 "$staged" omx-lib < "$t/tree" | sed -n 's/^holds=//p')
        promote=$(python3 -I "$holds" rpm 3.14.0 "$staged" omx-lib < "$t/tree" | sed -n 's/^holds=//p')
        n=0
        [ "$build" = true ] || n=$((n + 1))
        if [ "$repo" = with ] && [ "$promote" = true ]; then n=$((n + 1)); fi
        [ "$n" = 1 ] || fail "commit $staged, repository $repo: $n publishers start on the tag"
    done
done
ok "a v* tag starts exactly one publisher: staged or not, with a promote caller or not"

# ---- the workflows, rendered
cat > "$t/wf.py" <<'PY'
import sys, yaml
TAG = "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')"
def load(p):
    return yaml.safe_load(open(p))["jobs"]
def holds_steps(steps):
    return [i for i, s in enumerate(steps) if "/staged-holds@" in s.get("uses", "")]
for wf in sys.argv[2:4]:
    jobs = load(f"{sys.argv[1]}/{wf}")
    pre = jobs["preflight"]
    steps = pre["steps"]
    h = holds_steps(steps)
    assert len(h) == 1, f"{wf}: the preflight asks staged-holds {len(h)} times"
    s = steps[h[0]]
    assert s.get("id") == "promoted", f"{wf}: the staged-holds step has no id promoted"
    assert TAG in s.get("if", "") and "inputs.source-ref == ''" in s["if"] and "inputs.publish" in s["if"], \
        f"{wf}: staged-holds is asked off a publishing tag push of the repository's own tag"
    assert s["with"].get("promoter") == ".", f"{wf}: staged-holds does not check for a promote caller"
    rp = [i for i, x in enumerate(steps) if "/release-preflight@" in x.get("uses", "")]
    assert len(rp) == 1 and rp[0] > h[0], f"{wf}: the release preflight does not come after staged-holds"
    assert "steps.promoted.outputs.holds != 'true'" in steps[rp[0]].get("if", ""), \
        f"{wf}: the release preflight runs when the promotion publishes (its already-served check would go red)"
    assert "steps.promoted.outputs.holds == 'true' && '0'" in pre["outputs"]["count"], \
        f"{wf}: the preflight plans cells when the promotion publishes"
jobs = load(f"{sys.argv[1]}/promote-staged.yml")
steps = jobs["find"]["steps"]
h = holds_steps(steps)
assert len(h) == 1, f"promote-staged.yml: find asks staged-holds {len(h)} times"
s = steps[h[0]]
assert s.get("id") == "holds" and TAG in s.get("if", "") and "promoter" not in s.get("with", {}), \
    "promote-staged.yml: staged-holds is not asked on a tag push alone, without the promoter check"
assert jobs["find"]["outputs"].get("promote") == "${{ steps.holds.outputs.holds != 'false' }}", \
    "promote-staged.yml: find does not say whether the promotion publishes"
for i, x in enumerate(steps):
    if i > h[0] and x.get("id") in ("rpm", "deb", "commit"):
        assert "steps.holds.outputs.holds != 'false'" in x.get("if", ""), f"promote-staged.yml: find step {x['id']} runs when nothing is staged"
g = jobs["promote-go"]
assert g["needs"] == "find" and g["if"] == "${{ needs.find.outputs.promote == 'true' && " + TAG + " }}", \
    "promote-staged.yml: promote-go does not run on a tag push whose commit is staged alone"
assert not any("uses" in x for x in g["steps"]), "promote-go publishes something itself"
for j in ("rpm", "deb"):
    n = jobs[j]["needs"]
    assert "promote-go" in (n if isinstance(n, list) else [n]), f"promote-staged.yml: job {j} publishes when nothing is staged"
PY
python3 -I "$t/wf.py" "$here/.github/workflows" build-rpm.yml build-deb.yml || fail "the workflows do not ask the one question"
ok "build-rpm, build-deb and promote-staged ask staged-holds, and the answer stands one of them down"

# ---- sabotage: each guard, broken, goes red
sab() { # <what> <file> <sed expression>
    local what=$1 f=$2 e=$3
    rm -rf "$t/sab"; cp -r "$here/.github/workflows" "$t/sab"
    sed -i "$e" "$t/sab/$f"
    cmp -s "$t/sab/$f" "$here/.github/workflows/$f" && fail "sabotage: $what did not change $f"
    if python3 -I "$t/wf.py" "$t/sab" build-rpm.yml build-deb.yml >/dev/null 2>&1; then fail "sabotage: $what passes"; fi
}
sab "build-rpm preflight runs when promoted" build-rpm.yml "s/steps.promoted.outputs.holds != 'true'/true/"
sab "build-deb plans cells when promoted" build-deb.yml "s/steps.promoted.outputs.holds == 'true' \&\& '0' || //"
sab "promote deb job ungated" promote-staged.yml "s/needs: \[find, promote-go, rpm\]/needs: [find, rpm]/"
cp "$holds" "$t/holds-sab.py"
sed -i 's/return c.startswith(commit) or commit.startswith(c)/return True/' "$t/holds-sab.py"
cmp -s "$t/holds-sab.py" "$holds" && fail "sabotage: the commit match did not change"
cp "$here/.github/actions/promote-staged/collect.py" "$t/collect.py"
mkdir -p "$t/promote-staged"; cp "$t/collect.py" "$t/promote-staged/"; mkdir -p "$t/staged-holds"; mv "$t/holds-sab.py" "$t/staged-holds/holds.py"
got=$(python3 -I "$t/staged-holds/holds.py" rpm 3.14.0 1234567 omx-lib < "$t/tree" | sed -n 's/^holds=//p')
[ "$got" = false ] && fail "sabotage: holds.py matching any commit answers false"
ok "sabotage: an ungated preflight, an unplanned count, an ungated promotion and any-commit matching each go red"
echo "one-publisher: all passed"
