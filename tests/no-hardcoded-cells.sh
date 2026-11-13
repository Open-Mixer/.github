#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# No workflow writes its own cell list (ruling D25, Open-Mixer/.github#59), offline. Every check or build matrix takes
# its cells from release-matrix (a build, a publish) or check-matrix (a check), which read quick.txt, the one list.
# Proves, over every file of .github/workflows:
#   A. a literal cell (debian:<suite>, fedora:<n>, fc<n>, a bare Debian suite) is one the quick set builds, except as the
#      releases / arches a plan step is handed (the whole matrix, declared once); bookworm
#      written into a workflow is red, because while the wave is quick nothing may build or check it;
#   B. a strategy.matrix dimension (suite, fedora, arch, image, include rows naming an image) is never a literal list:
#      it is fromJSON of a plan job's output;
#   C. a JSON array of cell names (["bookworm", "trixie"], ["x86_64", "aarch64"], ["44", "45"]) is written only as the
#      releases / arches input of a release-matrix or check-matrix step, the one place a workflow declares its whole
#      matrix, or in ALLOW below;
#   D. no shell loop runs over a literal list of suites;
#   E. ALLOW lists the places that stay literal, each with its reason, and every entry still matches a line (a stale
#      entry is red).
# Then, for each converted workflow, the plan step it carries is rendered as its action renders it, quick and full, and
# the cells are the ones expected: quick holds the quick set's cells alone and names what it skipped, full the whole
# matrix.
# Sabotage (below, run at the end): a literal bookworm put back into a copy of a workflow, and a literal matrix list,
# each go red.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
wf=${NO_HARDCODED_WORKFLOWS:-$here/.github/workflows}
actions=$here/.github/actions
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
: > "$t/log"; : > "$t/out"
fail=0
no() { echo "FAIL $*"; fail=1; }
yes() { echo "ok   $*"; }

cat > "$t/scan.py" <<'PY'
import glob, os, re, sys, yaml

wfdir, quick_txt = sys.argv[1], sys.argv[2]
quick_deb, quick_rpm = set(), set()
for line in open(quick_txt):
    p = line.split()
    if len(p) == 3 and not line.startswith("#"):
        (quick_rpm if p[0] == "rpm" else quick_deb).add(p[1])

# (file, regex of the line, reason): a literal that has to stay one. Whole-matrix declarations are inputs of the
# reusable workflows and tables of the callers: what is passed to release-matrix, never what a job runs.
ALLOW = [
    ("build-deb.yml", r"default: '\[\"amd64\", \"arm64\"\]'", "declares the caller's whole deb architectures, fed to release-matrix"),
    ("build-deb.yml", r"default: '\[\"bookworm\", \"trixie\"\]'", "declares the caller's whole Debian releases, fed to release-matrix"),
    ("build-deb.yml", r"bookworm is Raspberry Pi OS", "the input's description"),
    ("build-deb.yml", r"matrix\.suite == 'bookworm'", "a per-cell behaviour inside a cell: it only runs when bookworm is in the cells"),
    ("build-rpm.yml", r"default: '\[\"x86_64\", \"aarch64\"\]'", "declares the caller's whole rpm architectures, fed to release-matrix"),
    ("build-rpm.yml", r"default: '\[\"44\", \"45\"\]'", "declares the caller's whole Fedora releases, fed to release-matrix"),
    ("ci.yml", r"tests/bookworm-asan\.sh", "the name of a test script of this repository, not a cell"),
    ("publish-fedora.yml", r"\[\"45\"\]", "the Fedora releases the dispatcher asks for: the caller's whole matrix, passed to build-rpm.yml"),
    ("promote-staged.yml", r"default: '\[\"(x86_64|bookworm|amd64|44)\"", "declares the whole matrix the caller promotes (collect.py refuses a tree lacking a cell)"),
    ("purge-staging.yml", r"default: '\[\"(bookworm|44)\"", "the staging indexes that must exist, whole tree, whatever the wave builds"),
    ("publish-freereac.yml", r"deb_suites='\[\"(bookworm|trixie)\"", "each repository's own whole matrix, passed to build-deb.yml, which runs release-matrix"),
    ("publish-fedora.yml", r"arm='\[\"x86_64\"", "each repository's own whole matrix, passed to build-rpm.yml, which runs release-matrix"),
    ("release-c-lib.yml", r"arch-matrix: \$\{\{ inputs\.arm", "the caller's whole architectures, passed to build-rpm.yml and build-deb.yml"),
]
# a matrix of toolchain arms, each one image the quick set always builds (rule A holds the image to the set)
ALLOW_MATRIX = [
    ("ci.yml", "key-transition", "two arms (rpm, deb), each its own toolchain, on an image of the quick set"),
    ("ci.yml", "staging-publish", "two arms (rpm, deb), each its own toolchain, on an image of the quick set"),
    ("ci.yml", "staging-bootstrap", "two arms (rpm, deb), each its own toolchain, on an image of the quick set"),
    ("ci.yml", "channel-installability", "three arms, each its own toolchain, on an image of the quick set"),
]
used = set()

suite_re = re.compile(r"\b(bookworm|trixie|bullseye|forky|sid)\b")
img_re = re.compile(r"\b(debian|fedora):(\w+)")
fc_re = re.compile(r"\bfc(\d+)\b")
vocab = re.compile(r"\b(bookworm|trixie|bullseye|forky|x86_64|aarch64|amd64|arm64)\b|^\d\d$")
arr_re = re.compile(r"""\[\s*(?:["'][\w.-]+["']|[\w.-]+)(?:\s*,\s*(?:["'][\w.-]+["']|[\w.-]+))*\s*\]""")
errs = []

def allowed(f, line):
    for i, (af, rx, _) in enumerate(ALLOW):
        if af == f and re.search(rx, line):
            used.add(("line", i)); return True
    return False

def cellish(v):
    return isinstance(v, str) and (img_re.match(v) or vocab.search(v))

for path in sorted(glob.glob(os.path.join(wfdir, "*.yml"))):
    f = os.path.basename(path)
    lines = open(path).read().split("\n")
    # --- the lines: rules A, C, D
    plan_keys = ("releases", "arches", "rpm-releases", "rpm-arches", "deb-releases", "deb-arches")
    for n, raw in enumerate(lines, 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        code = re.sub(r"\s#\s.*$", "", raw)
        if allowed(f, code):
            continue
        key = re.match(r"\s*([\w-]+):", code)
        key = key.group(1) if key else ""
        if key not in plan_keys:  # the whole matrix a plan step is handed is the one place a cell is written
            for m in suite_re.finditer(code):
                if m.group(1) not in quick_deb:
                    errs.append(f"{f}:{n}: A: '{m.group(1)}' is written into the workflow and the quick set does not build it: {s}")
            for m in img_re.finditer(code):
                k, v = m.groups()
                if v.isdigit() or v in ("trixie", "bookworm", "bullseye", "forky"):
                    if v not in (quick_rpm if k == "fedora" else quick_deb):
                        errs.append(f"{f}:{n}: A: image {k}:{v} is written into the workflow and the quick set does not build it: {s}")
            for m in fc_re.finditer(code):
                if m.group(1) not in quick_rpm:
                    errs.append(f"{f}:{n}: A: fc{m.group(1)} is written into the workflow and the quick set does not build it: {s}")
        for m in arr_re.finditer(code):
            items = [x.strip().strip("\"'") for x in m.group(0)[1:-1].split(",")]
            if items and all(vocab.search(x) for x in items) and key not in plan_keys:
                errs.append(f"{f}:{n}: C: a literal list of cells {items} outside a releases/arches input: {s}")
        if re.search(r"\bfor\s+\w*suite\w*\s+in\s+(?!\$)[a-z]", code):
            errs.append(f"{f}:{n}: D: a loop over literal suites: {s}")
    # --- the matrices: rule B
    d = yaml.safe_load("\n".join(lines))
    for job, j in (d.get("jobs") or {}).items():
        m = (j.get("strategy") or {}).get("matrix")
        if not isinstance(m, dict):
            continue
        for k, v in m.items():
            if k == "include":
                rows = v if isinstance(v, list) else []
                if any(isinstance(r, dict) and (any(x in r for x in ("suite", "fedora", "arch")) or cellish(r.get("image")))
                       for r in rows):
                    ok = [i for i, (af, aj, _) in enumerate(ALLOW_MATRIX) if af == f and aj == job]
                    if ok:
                        used.add(("matrix", ok[0]))
                    else:
                        errs.append(f"{f}: B: job {job} writes its matrix rows (include) as a literal list")
            elif k in ("suite", "fedora", "arch", "image", "cell") and isinstance(v, list):
                errs.append(f"{f}: B: job {job} writes matrix.{k} as a literal list {v}")
for i, (af, rx, why) in enumerate(ALLOW):
    if ("line", i) not in used:
        errs.append(f"ALLOW: {af} '{rx}' ({why}) matches no line: a stale entry")
for i, (af, aj, why) in enumerate(ALLOW_MATRIX):
    if ("matrix", i) not in used:
        errs.append(f"ALLOW_MATRIX: {af} job {aj} ({why}) matches no matrix: a stale entry")
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY

scan() { python3 -I "$t/scan.py" "$1" "$actions/release-matrix/quick.txt"; }
if out=$(scan "$wf"); then yes "no workflow writes a cell list of its own"; else no "literal cells in the workflows"; echo "$out" | sed 's/^/     /'; fi

# ---- the plan step of each converted workflow, rendered quick and full
cat > "$t/plans.py" <<'PY'
import glob, json, os, re, sys, yaml
wfdir = sys.argv[1]
for path in sorted(glob.glob(os.path.join(wfdir, "*.yml"))):
    f = os.path.basename(path)
    d = yaml.safe_load(open(path))
    on = d.get(True) or d.get("on") or {}
    defaults = {}
    for ev in ("workflow_call", "workflow_dispatch"):
        for k, v in ((on.get(ev) or {}).get("inputs") or {}).items():
            defaults.setdefault(k, v.get("default", ""))
    def sub(v):
        v = str(v)
        v = re.sub(r"\$\{\{\s*inputs\.([\w-]+)\s*\}\}", lambda m: str(defaults.get(m.group(1), "")), v)
        return "" if "${{" in v else v
    for job, j in (d.get("jobs") or {}).items():
        for s in j.get("steps") or []:
            u = s.get("uses", "")
            mm = re.search(r"/actions/(release-matrix|check-matrix)(@|$)", u)
            if mm:
                w = {k: sub(v) for k, v in (s.get("with") or {}).items()}
                print(json.dumps({"file": f, "job": job, "action": mm.group(1), "with": w,
                                  "wave": str((s.get("with") or {}).get("wave", ""))}))
PY
python3 -I "$t/plans.py" "$wf" > "$t/plans.jsonl"

# every plan step reads the organisation variable, or its quick/full could never follow the wave
bad=$(python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    p = json.loads(l)
    if "vars.OMX_RELEASE_MATRIX" not in p["wave"]:
        print(p["file"] + " job " + p["job"])' "$t/plans.jsonl")
if [ -z "$bad" ] && [ -s "$t/plans.jsonl" ]; then yes "every plan step reads OMX_RELEASE_MATRIX"; else no "a plan step does not read OMX_RELEASE_MATRIX: ${bad:-none found}"; fi

field() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["with"].get(sys.argv[2], ""))' "$1" "$2"; }
plan_of() { grep -F "\"file\": \"$1\"" "$t/plans.jsonl" | grep -F "\"job\": \"$2\""; }
# <file> <job>: run the plan step's action as a run of this kind would, for the wave quick and full
render_plan() { # <file> <job> <wave> <event> <ref type>: key=value lines in $t/out, the notice in $t/log
    local p m=''; p=$(plan_of "$1" "$2" | head -1)
    # clap-rpm.yml is also a pull-request check: its matrix input is the variable there
    [ "$4" != pull_request ] || m=$3
    [ -n "$p" ] || { no "$1 job $2 has no release-matrix or check-matrix step"; return 1; }
    : > "$t/out"
    case $(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["action"])' "$p") in
    release-matrix)
        KIND=$(field "$p" kind) RELEASES=$(field "$p" releases) ARCHES=$(field "$p" arches) MATRIX=$m WAVE=$3 STAGED='' \
            SOURCE_REF='' CATCH_UP='' EVENT=$4 REF_TYPE=$5 GITHUB_OUTPUT=$t/out "$actions/release-matrix/matrix.sh" > "$t/log" 2>&1 ;;
    check-matrix)
        GITHUB_OUTPUT=$t/out GITHUB_ACTION_PATH=$actions/check-matrix WAVE=$3 MATRIX='' RPM_RELEASES=$(field "$p" rpm-releases) \
            RPM_ARCHES=$(field "$p" rpm-arches) DEB_RELEASES=$(field "$p" deb-releases) DEB_ARCHES=$(field "$p" deb-arches) \
            "$actions/check-matrix/check-matrix.sh" > "$t/log" 2>&1 ;;
    esac
}
cells_of() { # the cells of $t/out as 'rel arch, rel arch'
    local c; c=$(sed -n 's/^cells=//p' "$t/out")
    grep -oE '"(fedora|suite)":"[^"]+","arch":"[^"]+"' <<< "$c" | sed -E 's/"(fedora|suite)":"([^"]+)","arch":"([^"]+)"/\2 \3/' | paste -sd, - | sed 's/,/, /g' || true
}
# <label> <file> <job> <event> <ref type> <quick cells> <full cells> <skipped named while quick>
check_plan() {
    local label=$1 file=$2 job=$3 ev=$4 rt=$5 q=$6 f=$7 skipped=$8 got
    render_plan "$file" "$job" quick "$ev" "$rt" || { no "$label: quick render failed"; cat "$t/log"; return; }
    got=$(cells_of)
    if [ "$got" = "$q" ]; then yes "$label: quick builds/checks: $q"; else no "$label: quick cells '$got', want '$q'"; fi
    if [ -n "$skipped" ]; then
        if grep -q "skipped while quick: $skipped" "$t/log"; then yes "$label: the notice names '$skipped' as skipped"
        else no "$label: the notice does not name '$skipped' as skipped"; cat "$t/log"; fi
    fi
    render_plan "$file" "$job" full "$ev" "$rt" || { no "$label: full render failed"; cat "$t/log"; return; }
    got=$(cells_of)
    if [ "$got" = "$f" ]; then yes "$label: full: $f"; else no "$label: full cells '$got', want '$f'"; fi
}
D=workflow_dispatch
DEB2='bookworm amd64, bookworm arm64, trixie amd64, trixie arm64'
check_plan "pugl-nanovg deb" pugl-nanovg-deb.yml plan $D '' 'trixie amd64, trixie arm64' "$DEB2" 'bookworm amd64, bookworm arm64'
check_plan "pugl-nanovg rpm" pugl-nanovg-rpm.yml plan $D '' '44 x86_64' '44 x86_64, 44 aarch64' 'fc44 aarch64'
check_plan "clap-headers deb" clap-headers-deb.yml plan $D '' 'trixie amd64' 'bookworm amd64, trixie amd64' 'bookworm amd64'
check_plan "mod-host-protocol deb" mod-host-protocol-deb.yml plan $D '' 'trixie amd64, trixie arm64' "$DEB2" 'bookworm amd64, bookworm arm64'
check_plan "mod-host-protocol rpm" mod-host-protocol-rpm.yml plan $D '' '44 x86_64, 45 x86_64' '44 x86_64, 44 aarch64, 45 x86_64, 45 aarch64' 'fc44 aarch64, fc45 aarch64'
check_plan "surge-xt deb" surge-xt-deb.yml plan $D '' 'trixie amd64, trixie arm64' "$DEB2" 'bookworm amd64, bookworm arm64'
check_plan "surge-xt rpm" surge-xt-rpm.yml plan $D '' '44 x86_64' '44 x86_64, 44 aarch64' 'fc44 aarch64'
check_plan "clap rpm" clap-rpm.yml plan pull_request '' '44 x86_64, 45 x86_64' '44 x86_64, 44 aarch64, 45 x86_64, 45 aarch64' 'fc44 aarch64, fc45 aarch64'
# the release package: an Architecture: all deb, built and laid out for the suites of the set; its install check after the publish
check_plan "openmixer-release deb" release-package.yml plan push tag 'trixie amd64' 'bookworm amd64, trixie amd64' 'bookworm amd64'
render_plan release-package.yml verify-plan quick push tag && [ "$(sed -n 's/^images=//p' "$t/out")" = '["fedora:44","fedora:45","debian:trixie"]' ] \
    && yes "openmixer-release verify, quick: fedora:44, fedora:45, debian:trixie" || { no "openmixer-release verify, quick: images $(sed -n 's/^images=//p' "$t/out")"; cat "$t/log"; }
grep -q 'skipped while quick: bookworm amd64' "$t/log" && yes "openmixer-release verify: the notice names bookworm as skipped" || no "openmixer-release verify: the notice does not name bookworm"
render_plan release-package.yml verify-plan full push tag && [ "$(sed -n 's/^images=//p' "$t/out")" = '["fedora:44","fedora:45","debian:bookworm","debian:trixie"]' ] \
    && yes "openmixer-release verify, full: all four images" || { no "openmixer-release verify, full: images $(sed -n 's/^images=//p' "$t/out")"; cat "$t/log"; }
# .github's own CI: the language packs
render_plan ci.yml plan quick push '' && [ "$(sed -n 's/^images=//p' "$t/out")" = '["fedora:44","fedora:45","debian:trixie"]' ] \
    && yes "ci langpacks, quick: fedora:44, fedora:45, debian:trixie" || { no "ci langpacks, quick: images $(sed -n 's/^images=//p' "$t/out")"; cat "$t/log"; }
grep -q 'skipped while quick: bookworm amd64' "$t/log" && yes "ci langpacks: the notice names bookworm as skipped" || no "ci langpacks: the notice does not name bookworm"
render_plan ci.yml plan full push '' && [ "$(sed -n 's/^images=//p' "$t/out")" = '["fedora:44","fedora:45","debian:bookworm","debian:trixie"]' ] \
    && yes "ci langpacks, full: all four images" || { no "ci langpacks, full: images $(sed -n 's/^images=//p' "$t/out")"; cat "$t/log"; }
# promote-staged.yml stays as it is, by design: it promotes the whole matrix (collect.py refuses a staged tree that lacks
# any release or architecture), so its install checks cover what it promotes; its lists are inputs, never literals in a job.

# ---- sabotage: a literal bookworm put back, and a literal matrix list, each go red
mkdir "$t/sab"; cp "$wf"/*.yml "$t/sab/"
sed -i "0,/debian:trixie/s//debian:bookworm/" "$t/sab/clap-headers-deb.yml"
if scan "$t/sab" > /dev/null 2>&1; then no "sabotage: a literal debian:bookworm passes"; else yes "sabotage: a literal debian:bookworm is red"; fi
cp "$wf"/*.yml "$t/sab/"
python3 -I - "$t/sab/surge-xt-deb.yml" <<'PY2'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r"(      matrix:\n)(        )include: \$\{\{ fromJSON\([^\n]*\n", r"\1\2suite: [trixie]\n", s, count=1)
assert s2 != s, "no include matrix to sabotage"
open(p, "w").write(s2)
PY2
if scan "$t/sab" > /dev/null 2>&1; then no "sabotage: a literal matrix list passes"; else yes "sabotage: a literal matrix list is red"; fi

# sabotage: a plan step that does not read the variable
cp "$wf"/*.yml "$t/sab/"
sed -i '/wave: \${{ vars.OMX_RELEASE_MATRIX }}/d' "$t/sab/surge-xt-rpm.yml"
python3 -I "$t/plans.py" "$t/sab" | python3 -I -c '
import json, sys
sys.exit(0 if any("vars.OMX_RELEASE_MATRIX" not in json.loads(l)["wave"] for l in sys.stdin) else 1)' \
    && yes "sabotage: a plan step that ignores the variable is seen" || no "sabotage: a plan step that ignores the variable passes"

[ "$fail" = 0 ] && echo "no-hardcoded-cells: all passed" || exit 1
