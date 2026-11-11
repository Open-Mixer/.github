#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# Staged packages, offline: a layer of the release chain uploads its fc44 x86_64 RPMs and trixie amd64 DEBs to the
# prerelease staged-v<version> of its repository (stage-release), and the next layer installs them from there
# (install-staged) instead of waiting for the channel. Proves:
#   - install-staged picks the files of the container's target only (fc44 x86_64 / trixie amd64), never a debuginfo,
#     dbgsym or source package, honours a package list, and refuses clearly a missing staged release, a missing
#     package, a file of another version, and a version outside the consumer's floor and ceiling;
#   - the version comparisons are rpm's and dpkg's (a +git snapshot meets a floor, a ~git one does not);
#   - stage-release creates a prerelease (never a release, never latest), uploads, removes the stale files of its own
#     kind only, refuses a staged tag that is a real release and a file of another version;
#   - build-rpm.yml and build-deb.yml, rendered with staged on and off: the matrix narrows to the staged targets, the
#     channel publish is skipped, the staged job runs, the snapshot sorts above the release (DEB), and install-staged
#     runs after the channel is added and before the build.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
inst=$here/.github/actions/install-staged/install-staged.sh
lib=$here/.github/actions/install-staged/staged.py
stage=$here/.github/actions/stage-release/stage-release.sh
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }
for f in "$inst" "$lib" "$stage"; do [ -f "$f" ] || fail "missing $f"; done

# ---- version comparisons
vc() { python3 -I "$lib" vercmp "$@"; }
[ "$(vc rpm 0.20.3 0.20.10)" = -1 ] || fail "rpm 0.20.3 < 0.20.10"
[ "$(vc rpm 0.20.3 0.20.3)" = 0 ] || fail "rpm equal"
[ "$(vc rpm 0.20.3-1.git5f455d3.fc44 0.20.3-1.fc44)" = 1 ] || fail "rpm snapshot release sorts above"
[ "$(vc rpm 1.0~rc1 1.0)" = -1 ] || fail "rpm tilde"
[ "$(vc deb 0.20.3+git5f455d3 0.20.3)" = 1 ] || fail "deb +git above the release"
[ "$(vc deb 0.20.3~git5f455d3 0.20.3)" = -1 ] || fail "deb ~git below the release"
[ "$(vc deb 0.20.3~git5f455d3 0.20.3~)" = 1 ] || fail "deb ~git above a ~ floor"
[ "$(vc deb 0.20.3-1 0.20.3)" = 1 ] || fail "deb revision"
[ "$(vc deb 1:0.1 2.0)" = 1 ] || fail "deb epoch"
ok "vercmp: rpm and dpkg orderings"

# ---- a fixture release, served from file://
api=$t/api; dl=$t/dl; mkdir -p "$dl"
mkrel() { # <owner/repo> <tag> <prerelease:true|false> <asset>...
    local repo=$1 tag=$2 pre=$3; shift 3
    mkdir -p "$api/repos/$repo/releases/tags" "$dl/$repo/$tag"
    python3 -I - "$api/repos/$repo/releases/tags/$tag" "$dl/$repo/$tag" "$tag" "$pre" "$@" <<'PY'
import json, sys, os
out, d, tag, pre, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "true", sys.argv[5:]
assets = []
for n in names:
    open(os.path.join(d, n), "w").write(n)
    assets.append({"name": n, "browser_download_url": "file://" + os.path.join(d, n)})
json.dump({"tag_name": tag, "prerelease": pre, "assets": assets}, open(out, "w"))
PY
}
mkrel Open-Mixer/plugin-hostd staged-v0.20.3 true \
    plugin-hostd-0.20.3-1.git5f455d3.fc44.x86_64.rpm \
    plugin-hostd-contract-0.20.3-1.git5f455d3.fc44.noarch.rpm \
    plugin-hostd-devel-0.20.3-1.git5f455d3.fc44.noarch.rpm \
    plugin-hostd-debuginfo-0.20.3-1.git5f455d3.fc44.x86_64.rpm \
    plugin-hostd-debugsource-0.20.3-1.git5f455d3.fc44.x86_64.rpm \
    plugin-hostd-0.20.3-1.git5f455d3.fc44.src.rpm \
    plugin-hostd-0.20.3-1.git5f455d3.fc45.x86_64.rpm \
    plugin-hostd-0.20.3-1.git5f455d3.fc44.aarch64.rpm \
    plugin-hostd_0.20.3+git5f455d3_trixie_amd64.deb \
    plugin-hostd-contract_0.20.3+git5f455d3_trixie_all.deb \
    plugin-hostd-dbgsym_0.20.3+git5f455d3_trixie_amd64.deb \
    plugin-hostd_0.20.3+git5f455d3_bookworm_amd64.deb \
    plugin-hostd_0.20.3+git5f455d3_trixie_arm64.deb
mkrel Open-Mixer/omx-clap-core staged-v0.31.2 true omx-clap-host-0.31.1-1.gitabcdef0.fc44.x86_64.rpm
mkrel Open-Mixer/omx-plugins staged-v0.19.3 true omx-plugins_0.19.3~gitabcdef0_trixie_amd64.deb

# a consumer tree, its spec and debian/control naming plugin-hostd-contract with a floor and a ceiling
cons() { # <floor> <ceiling>
    rm -rf "$t/tree"; mkdir -p "$t/tree/packaging" "$t/tree/debian"
    printf 'Name: omx-panel\nVersion: 0.13.3\nBuildRequires: (plugin-hostd-contract >= %s with plugin-hostd-contract < %s)\nBuildRequires: (plugin-hostd%%{?_isa} >= %s with plugin-hostd%%{?_isa} < %s)\n' "$1" "$2" "$1" "$2" > "$t/tree/packaging/omx-panel.spec"
    printf 'Source: omx-panel\nBuild-Depends: debhelper-compat (= 13),\n               plugin-hostd-contract (>= %s~) <!nocheck>,\n               plugin-hostd-contract (<< %s~) <!nocheck>,\n               omx-plugins (>= 0.19.3)\n' "$1" "$2" > "$t/tree/debian/control"
}
run() { # <target> <packages...>; prints the chosen files, one per line
    local target=$1; shift
    STAGED_API="file://$api" STAGED_TARGET=$target STAGED_DRY=1 STAGED_DIR="$t/got" STAGED_TREE="$t/tree" \
        bash "$inst" "$@"
}
cons 0.20.3 0.21

out=$(run rpm:fc44.x86_64 plugin-hostd@0.20.3) || fail "rpm: a staged release refused: $out"
want='plugin-hostd-0.20.3-1.git5f455d3.fc44.x86_64.rpm
plugin-hostd-contract-0.20.3-1.git5f455d3.fc44.noarch.rpm
plugin-hostd-devel-0.20.3-1.git5f455d3.fc44.noarch.rpm'
[ "$(echo "$out" | grep '^staged: ' | sed 's/^staged: //' | xargs -n1 basename | sort)" = "$want" ] ||
    fail "rpm: wrong files: $out"
ok "rpm: the fc44 x86_64 and noarch binaries, no debuginfo, source, fc45 or aarch64"

out=$(run deb:trixie.amd64 Open-Mixer/plugin-hostd@0.20.3) || fail "deb: refused: $out"
want='plugin-hostd-contract_0.20.3+git5f455d3_trixie_all.deb
plugin-hostd_0.20.3+git5f455d3_trixie_amd64.deb'
[ "$(echo "$out" | grep '^staged: ' | sed 's/^staged: //' | xargs -n1 basename | sort)" = "$want" ] ||
    fail "deb: wrong files: $out"
ok "deb: trixie amd64 and all, no dbgsym, bookworm or arm64"

out=$(run rpm:fc44.x86_64 'plugin-hostd@0.20.3:plugin-hostd-contract') || fail "rpm list: $out"
[ "$(echo "$out" | grep -c '^staged: ')" = 1 ] && echo "$out" | grep -q 'plugin-hostd-contract-0.20.3' || fail "package list ignored: $out"
ok "a package list installs only the packages it names"

two=$(run rpm:fc44.x86_64 'plugin-hostd@0.20.3:plugin-hostd-contract' 'omx-clap-core@0.31.2' 2>&1) && fail "a mismatched version passed: $two"
echo "$two" | grep -q 'omx-clap-host-0.31.1.*not 0.31.2' || fail "mismatch not named: $two"
ok "a staged file of another version is refused, by name"

err=$(run rpm:fc44.x86_64 'plugin-hostd@0.20.3:plugin-hostd-nonesuch' 2>&1) && fail "a missing package passed"
echo "$err" | grep -q 'plugin-hostd-nonesuch' || fail "missing package not named: $err"
err=$(run rpm:fc44.x86_64 plugin-hostd@0.20.4 2>&1) && fail "a missing staged release passed"
echo "$err" | grep -q 'staged-v0.20.4' || fail "missing release not named: $err"
err=$(run rpm:fc45.x86_64 plugin-hostd@0.20.3 2>&1) && fail "an unstaged target passed"
echo "$err" | grep -q 'fc44.x86_64' || fail "unstaged target not explained: $err"
err=$(run rpm:fc44.x86_64 plugin-hostd 2>&1) && fail "a spec without a version passed"
echo "$err" | grep -q 'repo@version' || fail "bad spec not explained: $err"
ok "refused clearly: a missing package, a missing staged release, an unstaged target, a spec without @version"

cons 0.20.4 0.21
err=$(run rpm:fc44.x86_64 plugin-hostd@0.20.3 2>&1) && fail "rpm: below the floor passed"
echo "$err" | grep -q 'plugin-hostd-contract 0.20.3.*>= 0.20.4' || fail "rpm floor not named: $err"
err=$(run deb:trixie.amd64 plugin-hostd@0.20.3 2>&1) && fail "deb: below the floor passed"
echo "$err" | grep -q 'plugin-hostd-contract 0.20.3+git5f455d3.*>= 0.20.4~' || fail "deb floor not named: $err"
cons 0.19.0 0.20
err=$(run rpm:fc44.x86_64 plugin-hostd@0.20.3 2>&1) && fail "rpm: at the ceiling passed"
echo "$err" | grep -q '< 0.20' || fail "ceiling not named: $err"
ok "a staged version under the consumer's floor or at its ceiling is refused (rpm and deb)"

cons 0.20.3 0.21
err=$(run deb:trixie.amd64 omx-plugins@0.19.3 2>&1) && fail "a ~git snapshot met a plain floor"
echo "$err" | grep -q 'omx-plugins 0.19.3~gitabcdef0.*>= 0.19.3' || fail "~git floor not named: $err"
ok "sabotage: a ~git snapshot (sorts below its release) does not meet a plain floor; staged DEBs are +git"

# ---- stage-release, against a fake gh that records its calls
mkdir -p "$t/bin" "$t/rpms" "$t/debs/trixie"
cat > "$t/bin/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
if [ "$1 $2" = "release view" ]; then
    [ -f "$GH_VIEW" ] || exit 1
    cat "$GH_VIEW"; exit 0
fi
exit 0
SH
chmod +x "$t/bin/gh"
touch "$t/rpms/plugin-hostd-0.20.3-1.git5f455d3.fc44.x86_64.rpm" "$t/rpms/plugin-hostd-contract-0.20.3-1.git5f455d3.fc44.noarch.rpm" \
      "$t/rpms/plugin-hostd-0.20.3-1.git5f455d3.fc44.src.rpm"
touch "$t/debs/trixie/plugin-hostd_0.20.3+git5f455d3_amd64.deb" "$t/debs/trixie/plugin-hostd-contract_0.20.3+git5f455d3_all.deb"
st() { # <kind> <dir> [view json]
    : > "$t/log"; rm -f "$t/view.json"
    [ -z "${3:-}" ] || echo "$3" > "$t/view.json"
    PATH=$t/bin:$PATH GH_LOG=$t/log GH_VIEW=$t/view.json GITHUB_REPOSITORY=Open-Mixer/plugin-hostd GITHUB_SHA=5f455d37cfb5 \
        STAGED_OUT=$t/out-$1 bash "$stage" "$1" 0.20.3 "$2"
}
st rpm "$t/rpms" >/dev/null || fail "stage-release rpm on a fresh version"
grep -q '^gh release create staged-v0.20.3 .*--prerelease' "$t/log" || fail "no prerelease created: $(cat "$t/log")"
grep -q -- '--latest=false' "$t/log" || fail "the staged release may become latest"
grep -q -- '--target 5f455d37cfb5' "$t/log" || fail "the staged tag is not at the built commit"
grep '^gh release upload staged-v0.20.3' "$t/log" | grep -q 'plugin-hostd-contract-0.20.3-1.git5f455d3.fc44.noarch.rpm' || fail "nothing uploaded: $(cat "$t/log")"
grep '^gh release upload' "$t/log" | grep -q 'src.rpm' && fail "a source RPM was staged"
grep -q 'delete-asset' "$t/log" && fail "deleted on a fresh release"
ok "stage-release: a fresh version creates a prerelease at the commit, never latest, binaries only"

view='{"isPrerelease": true, "assets": [{"name": "plugin-hostd-0.20.3-1.gitaaaaaaa.fc44.x86_64.rpm"}, {"name": "plugin-hostd-contract-0.20.3-1.git5f455d3.fc44.noarch.rpm"}, {"name": "plugin-hostd_0.20.3+gitaaaaaaa_trixie_amd64.deb"}]}'
st rpm "$t/rpms" "$view" >/dev/null || fail "stage-release over an existing staged release"
grep -q '^gh release create' "$t/log" && fail "created over an existing release"
grep -q '^gh release delete-asset staged-v0.20.3 plugin-hostd-0.20.3-1.gitaaaaaaa.fc44.x86_64.rpm' "$t/log" || fail "the stale RPM stays: $(cat "$t/log")"
grep 'delete-asset' "$t/log" | grep -q '\.deb' && fail "the RPM job deleted a DEB"
grep 'delete-asset' "$t/log" | grep -q 'contract-0.20.3-1.git5f455d3' && fail "deleted a file it re-uploads"
up=$(grep -n '^gh release upload' "$t/log" | cut -d: -f1); del=$(grep -n 'delete-asset' "$t/log" | head -1 | cut -d: -f1)
[ "$up" -lt "$del" ] || fail "stale files go before the new ones arrive"
ok "stage-release: a rebuild uploads first, then removes its own kind's stale files, never the other kind's"

st deb "$t/debs" "$view" >/dev/null || fail "stage-release deb"
grep '^gh release upload' "$t/log" | grep -q 'plugin-hostd_0.20.3+git5f455d3_trixie_amd64.deb' || fail "DEB not named by Debian release: $(cat "$t/log")"
grep -q 'delete-asset staged-v0.20.3 plugin-hostd_0.20.3+gitaaaaaaa_trixie_amd64.deb' "$t/log" || fail "stale DEB stays"
grep 'delete-asset' "$t/log" | grep -q '\.rpm' && fail "the DEB job deleted an RPM"
ok "stage-release: DEBs carry their Debian release in the name, as the tag release names them"

err=$(st rpm "$t/rpms" '{"isPrerelease": false, "assets": []}' 2>&1) && fail "staged over a real release"
echo "$err" | grep -q 'not a prerelease' || fail "real release not named: $err"
touch "$t/rpms/plugin-hostd-0.20.2-1.fc44.x86_64.rpm"
err=$(st rpm "$t/rpms" 2>&1) && fail "a file of another version was staged"
echo "$err" | grep -q 'plugin-hostd-0.20.2-1.fc44.x86_64.rpm' || fail "other version not named: $err"
rm "$t/rpms/plugin-hostd-0.20.2-1.fc44.x86_64.rpm"
ok "stage-release refuses a staged tag that is a real release, and a file of another version"

# ---- the reusable workflows, rendered with staged on and off
python3 -I - "$here/.github/workflows/build-rpm.yml" "$here/.github/workflows/build-deb.yml" <<'PY'
import json, re, sys, yaml

class O(dict):
    __getattr__ = dict.get

def ev(expr, inputs, needs=None, matrix=None):
    e = expr.strip()
    if e.startswith("${{") and e.endswith("}}"):
        e = e[3:-2].strip()
    e = re.sub(r"\binputs\.([a-z0-9-]+)", lambda m: f'inputs["{m.group(1)}"]', e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    env = {"inputs": inputs, "fromJSON": json.loads, "cancelled": lambda: False, "true": True, "false": False,
           "github": O(ref_type="branch", event_name="workflow_dispatch", ref="refs/heads/x", repository="o/r",
                       event=O(pull_request=O(head=O(repo=O(full_name="o/r"))))),
           "needs": needs or O(), "matrix": matrix or O(), "vars": O(), "startsWith": lambda a, b: str(a).startswith(b)}
    return eval(e, {"__builtins__": {}}, env)

def defaults(d):
    on = d.get(True) or d.get("on")
    return {k: v.get("default") for k, v in on["workflow_call"]["inputs"].items()}, on["workflow_call"]["inputs"]

def check(path, kind):
    d = yaml.safe_load(open(path))
    base, decl = defaults(d)
    for name, typ in (("staged", "boolean"), ("staged-deps", "string")):
        assert name in decl and decl[name]["type"] == typ, f"{path}: input {name} ({typ}) not declared"
    assert base["staged"] is False and base["staged-deps"] == "", f"{path}: staged must default off"
    jobs = d["jobs"]
    build = jobs["build"]
    m = build["strategy"]["matrix"]
    first, second = ("fedora", "arch") if kind == "rpm" else ("suite", "arch")
    want_on = (["44"], ["x86_64"]) if kind == "rpm" else (["trixie"], ["amd64"])
    caller = dict(base, **({"arch-matrix": '["x86_64", "aarch64"]'} if kind == "rpm" else {"arch-matrix": '["amd64", "arm64"]'}))
    on = dict(caller, staged=True, publish=False)
    off = dict(caller, staged=False, publish=False)
    assert (ev(m[first], on), ev(m[second], on)) == want_on, f"{path}: staged matrix is {ev(m[first], on)} x {ev(m[second], on)}"
    assert ev(m[second], off) == json.loads(caller["arch-matrix"]), f"{path}: unstaged matrix changed"
    assert ev(m[first], off) == json.loads(caller["fedora-versions" if kind == "rpm" else "suite-matrix"]), f"{path}: unstaged releases changed"
    pub = jobs["publish"]
    assert "if" in pub and not ev(pub["if"], on, needs=O(build=O(result="success"))), f"{path}: publish runs on a staged run"
    assert ev(pub["if"], off, needs=O(build=O(result="success"))), f"{path}: publish skipped on an ordinary run"
    st = jobs["staged"]
    assert ev(st["if"], on, needs=O(build=O(result="success"))) and not ev(st["if"], off, needs=O(build=O(result="success"))), \
        f"{path}: the staged job runs on the wrong runs"
    assert "build" in (st["needs"] if isinstance(st["needs"], list) else [st["needs"]]), f"{path}: staged job does not need build"
    assert st.get("permissions", {}).get("contents") == "write", f"{path}: staged job cannot write the release"
    steps = build["steps"]
    uses = [s.get("uses", "") for s in steps]
    def at(name):
        i = [k for k, u in enumerate(uses) if f"/actions/{name}@" in u]
        assert i, f"{path}: build job has no {name} step"
        return i[0]
    i_add, i_inst, i_build = at("add-openmixer"), at("install-staged"), at(f"build-{kind}")
    assert i_add < i_inst < i_build, f"{path}: install-staged must run after add-openmixer and before the build"
    s = steps[i_inst]
    assert not ev(s["if"], dict(off, **{"staged-deps": ""})) and ev(s["if"], dict(off, **{"staged-deps": "plugin-hostd@0.20.3"})), \
        f"{path}: install-staged runs on the wrong runs"
    assert "inputs.staged-deps" in s["with"]["packages"], f"{path}: install-staged does not get staged-deps"
    if kind == "deb":
        sep = steps[i_build]["with"].get("separator")
        assert sep is not None and ev(sep, on) == "+git" and ev(sep, off) == "~git", f"{path}: staged DEB snapshot separator {sep}"
    pre = " ".join(str(s.get("run", "")) for s in jobs["preflight"]["steps"])
    assert "staged" in pre.lower() and "publish" in pre, f"{path}: preflight does not refuse staged with publish"
    print(f"ok   {path.split('/')[-1]}: staged narrows the matrix, skips the publish, stages; off is unchanged")

check(sys.argv[1], "rpm")
check(sys.argv[2], "deb")
PY

# build-deb takes the separator the workflow passes, and hands it to build-deb.sh as -s
python3 -I - "$here/.github/actions/build-deb/action.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["inputs"].get("separator", {}).get("default") == "~git", "build-deb action: no separator input defaulting to ~git"
step = d["runs"]["steps"][0]
assert "SEPARATOR" in step.get("env", {}) and '-s "$SEPARATOR"' in step["run"], "build-deb action: separator not passed as -s"
print("ok   build-deb action: the snapshot separator reaches build-deb.sh")
PY

# the step scripts parse
for f in "$inst" "$stage"; do bash -n "$f" || fail "syntax $f"; done
echo "staged-packages: all passed"
