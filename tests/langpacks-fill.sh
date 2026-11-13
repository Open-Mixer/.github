#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# The language packs fill (Open-Mixer/.github#46):  tests/langpacks-fill.sh
#
# A fixture owner (tests/fixtures/langpacks-fill: languages ca and es, one source with a kept code, a changed sentence, a
# new code and a code a person wrote) and a FIXTURE ROUTER (router.py, a local HTTP server answering /v1/chat/completions
# for one key). The check (omx-contract translate --check) is red naming the changed sentence and the new code in each
# language; the fill makes exactly those, as machine entries with their model and source hash, in each language; the
# check is then green; a person's entry beside them is byte-identical. Red arms: a fill that writes a person's entry, a
# fill that skips a missing key, a fork, a GitHub-hosted runner, no key and no signing key each refuse, naming the
# entries (catalog, key) and the command a person runs, and write nothing; a person's own stale entry is named for a person
# and never written. The push arm commits the entries signed to the pull request's branch of a local remote.
# Needs python3, node, git, gpg and omx-contract: OMX_CONTRACT names its command (default omx-contract on PATH, 3.16 or later).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fill=$root/.github/actions/langpacks/fill.py
fix=$root/tests/fixtures/langpacks-fill
oc=${OMX_CONTRACT:-omx-contract}
work=$(mktemp -d)
router_pid=
trap '[ -z "$router_pid" ] || kill "$router_pid" 2>/dev/null; rm -rf "$work"' EXIT
failures=0
step() {
    if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures + 1)); fi
}
export OMX_CONTRACT_DATADIR=$fix
KEY=fixture-router-key-not-a-secret

python3 "$fix/router.py" "$work/port" "$KEY" 2>"$work/router.log" &
router_pid=$!
for _ in $(seq 100); do [ -s "$work/port" ] && break; python3 -c 'import time; time.sleep(0.05)'; done
URL=http://127.0.0.1:$(cat "$work/port")

fresh() {  # fresh <name>: a copy of the fixture at $work/<name>
    mkdir -p "$work/$1" && cp -r "$fix/catalogs" "$fix/source.json" "$fix/languages.json" "$work/$1/"
}
GATE="$oc translate --check --source source.json --catalogs catalogs"
FILL="$oc translate --source source.json --catalogs catalogs"
# run_fill <dir> [env assignments...] -- [extra fill.py args]: fill.py in <dir>, the router's URL and key, a same-repo
# runner of our own, nothing to push unless the caller adds it
run_fill() {
    local d=$1; shift
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    (cd "$d" && env OMX_TRANSLATE_URL="$URL" OMX_TRANSLATE_KEY="$KEY" RUNNER_ENVIRONMENT=self-hosted "${envs[@]}" \
        python3 "$fill" --gate "$GATE" --fill "$FILL" --languages languages.json --model draft-prose "$@")
}
catalog_keys() {  # catalog_keys <file> <by>: the keys whose entry is by <by>, sorted
    python3 -I - "$1" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["messages"]
print(" ".join(sorted(k for k, v in m.items() if isinstance(v, dict) and v.get("by") == sys.argv[2])))
PY
}
human_line() { grep '"fix.human"' "$1/catalogs/$2.json"; }

# ---- the check is red, naming both, in each language
fresh red
(cd "$work/red" && $GATE) >"$work/red.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && for l in ca es; do
    grep -q "catalogs/$l.json: fix.changed: stale" "$work/red.out" && grep -q "catalogs/$l.json: fix.new: missing" "$work/red.out" || rc=9
done
step $((rc == 1 ? 0 : 1)) "the check is red naming the changed sentence and the new code in ca and es"

# ---- the fill: exactly two machine entries a language, the check green, a person's entry untouched
fresh fill
human_ca=$(human_line "$work/fill" ca); human_es=$(human_line "$work/fill" es)
run_fill "$work/fill" -- --no-push >"$work/fill.out" 2>&1
step $? "the fill makes the entries and the check is green after: $(tail -1 "$work/fill.out")"
(cd "$work/fill" && $GATE) >/dev/null 2>&1
step $? "translate --check is green on the filled catalogs"
for l in ca es; do
    # the two made ones are the changed and the new, by machine with the served model and a source hash
    [ "$(python3 -I - "$work/fill/catalogs/$l.json" <<'PY'
import hashlib, json, sys
m = json.load(open(sys.argv[1]))["messages"]
new = m["fix.new"]; ch = m["fix.changed"]
ok = all(e["by"] == "machine" and e["model"] == "draft-prose" and e["text"].startswith("[%s] " % sys.argv[1].split("/")[-1][:-5]) for e in (new, ch))
ok = ok and ch["source"] == hashlib.sha256("The fixture refuses {what} now.".encode()).hexdigest()
ok = ok and new["source"] == hashlib.sha256("The fixture says something new.".encode()).hexdigest()
ok = ok and "{what}" in ch["text"]
print("yes" if ok else "no")
PY
)" = yes ]
    step $? "$l: fix.changed and fix.new are machine entries by draft-prose from their source sentences"
    [ "$(catalog_keys "$work/fill/catalogs/$l.json" machine)" = "fix.changed fix.kept fix.new" ] &&
        [ "$(catalog_keys "$work/fill/catalogs/$l.json" machine | wc -w)" -eq 3 ]
    step $? "$l: exactly two entries were made (three machine entries now, one of them the kept one)"
    cmp -s <(grep '"fix.kept"' "$fix/catalogs/$l.json") <(grep '"fix.kept"' "$work/fill/catalogs/$l.json")
    step $? "$l: the kept machine entry is byte-identical"
done
[ "$(human_line "$work/fill" ca)" = "$human_ca" ] && [ "$(human_line "$work/fill" es)" = "$human_es" ]
step $? "the person's entries beside them are byte-identical"
[ "$(grep -c '^router: ' "$work/router.log")" -ge 2 ] && ! grep -q 'refused a call' "$work/router.log"
step $? "the router answered with the key, one call a language at least"

# ---- a green check fills nothing and says so
run_fill "$work/fill" -- --no-push >"$work/again.out" 2>&1
step $? "a whole set of catalogs is left alone: $(head -1 "$work/again.out")"

# ---- the refusals: each names the entries and the command, writes nothing
refusal() {  # refusal <what> <dir> <reason text> [env...]: fill.py refuses (exit 1) naming every entry and a command
    local what=$1 d=$2 want=$3; shift 3
    fresh "$d"
    cp -r "$work/$d/catalogs" "$work/$d.before"
    run_fill "$work/$d" "$@" -- --no-push >"$work/$d.out" 2>&1
    local rc=$?
    local ok=0
    [ "$rc" -eq 1 ] || ok=1
    grep -q -- "$want" "$work/$d.out" || ok=2
    for e in 'catalogs/ca.json: fix.changed' 'catalogs/ca.json: fix.new' 'catalogs/es.json: fix.changed' 'catalogs/es.json: fix.new'; do
        grep -q -- "$e" "$work/$d.out" || ok=3
    done
    grep -q 'OMX_TRANSLATE_URL=<' "$work/$d.out" && grep -q -- '--lang ca --model draft-prose' "$work/$d.out" || ok=4
    grep -q "$KEY" "$work/$d.out" && ok=5
    diff -r "$work/$d.before" "$work/$d/catalogs" >/dev/null || ok=6
    step $ok "$what: refused naming the four entries and the command (rc=$rc ok=$ok)"
}
refusal "a fork pull request" fork "fork" FILL_FORK=true
refusal "a GitHub-hosted runner" hosted "GitHub-hosted" RUNNER_ENVIRONMENT=github-hosted
refusal "no router key" nokey "OMX_ROUTER_KEY" OMX_TRANSLATE_KEY=
refusal "no router address" nourl "router" OMX_TRANSLATE_URL=

# ---- sabotage: a translator that writes a person's entry, and one that skips a missing key
cat > "$work/evil.sh" <<'EOS'
#!/bin/bash
# the real translate, then a person's entry rewritten
"$@" || exit $?
sed -i 's/"fix.human": { "text": "[^"]*"/"fix.human": { "text": "overwritten"/' catalogs/*.json
EOS
cat > "$work/lazy.sh" <<'EOS'
#!/bin/bash
# the real translate, then one made key dropped again
"$@" || exit $?
sed -i '/"fix.new"/d' catalogs/es.json
EOS
chmod +x "$work/evil.sh" "$work/lazy.sh"
fresh evil; cp -r "$work/evil/catalogs" "$work/evil.before"
(cd "$work/evil" && env OMX_TRANSLATE_URL="$URL" OMX_TRANSLATE_KEY="$KEY" RUNNER_ENVIRONMENT=self-hosted \
    python3 "$fill" --gate "$GATE" --fill "$work/evil.sh $FILL" --languages languages.json --model draft-prose --no-push) >"$work/evil.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q 'fix.human' "$work/evil.out" && grep -qi 'person' "$work/evil.out" && diff -r "$work/evil.before" "$work/evil/catalogs" >/dev/null
step $? "a fill that writes a person's entry is refused and its catalogs restored (rc=$rc)"
fresh lazy
(cd "$work/lazy" && env OMX_TRANSLATE_URL="$URL" OMX_TRANSLATE_KEY="$KEY" RUNNER_ENVIRONMENT=self-hosted \
    python3 "$fill" --gate "$GATE" --fill "$work/lazy.sh $FILL" --languages languages.json --model draft-prose --no-push) >"$work/lazy.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q 'catalogs/es.json: fix.new' "$work/lazy.out" && ! grep -q 'catalogs/ca.json: fix.new' "$work/lazy.out"
step $? "a fill that skips one missing key is red naming that key alone (rc=$rc)"

# ---- a person's own stale entry is named for a person, never written
fresh stale
python3 -I - "$work/stale/catalogs/ca.json" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace('"fix.human": { "text": "Una persona ho va escriure.", "by": "human" }',
                           '"fix.human": { "text": "Una persona ho va escriure.", "by": "human", "source": "0000" }')
open(p, "w").write(t)
PY
cp -r "$work/stale/catalogs" "$work/stale.before"
run_fill "$work/stale" -- --no-push >"$work/stale.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && grep -q 'catalogs/ca.json: fix.human' "$work/stale.out" && grep -qi 'person' "$work/stale.out" &&
    [ "$(grep '"fix.human"' "$work/stale/catalogs/ca.json")" = "$(grep '"fix.human"' "$work/stale.before/ca.json")" ]
step $? "a person's stale entry is named for a person and left as written (rc=$rc)"

# ---- the push: a signed commit on the pull request's branch of a local remote, then red with the line that says so
if command -v gpg >/dev/null; then
    export GNUPGHOME=$work/gnupg; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --quiet --passphrase '' --quick-gen-key 'CI Fixture <ci-fixture@example.invalid>' ed25519 sign 0 2>/dev/null
    kid=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')
    git init -q --bare "$work/remote.git"
    git init -q -b feature "$work/push" && cp -r "$fix/catalogs" "$fix/source.json" "$fix/languages.json" "$work/push/"
    git -C "$work/push" add -A && git -C "$work/push" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m start
    git -C "$work/push" push -q "$work/remote.git" HEAD:refs/heads/feature
    start=$(git -C "$work/push" rev-parse HEAD)
    run_fill "$work/push" GITHUB_HEAD_REF=feature SIGNING_KEY_ID="$kid" COMMITTER_NAME=CI COMMITTER_EMAIL=ci-fixture@example.invalid -- \
        --remote "$work/remote.git" >"$work/push.out" 2>&1
    rc=$?
    new=$(git --git-dir="$work/remote.git" rev-parse refs/heads/feature)
    [ "$rc" -eq 1 ] && [ "$new" != "$start" ] && grep -q 'pushed' "$work/push.out" && grep -q 're-runs' "$work/push.out"
    step $? "the entries are pushed to the branch and this run is red saying the new head re-runs (rc=$rc)"
    git --git-dir="$work/remote.git" verify-commit "$new" >/dev/null 2>&1
    step $? "the pushed commit is signed"
    [ "$(git --git-dir="$work/remote.git" show -s --format=%P "$new")" = "$start" ] &&
        [ "$(git --git-dir="$work/remote.git" diff --name-only "$start" "$new" | tr '\n' ' ')" = "catalogs/ca.json catalogs/es.json " ]
    step $? "it is one commit on the old head touching the two catalogs only"
    git -C "$work/push" clean -fdq; git -C "$work/push" fetch -q "$work/remote.git" feature && git -C "$work/push" reset -q --hard FETCH_HEAD
    (cd "$work/push" && $GATE) >/dev/null 2>&1
    step $? "the new head's check is green"
    msg=$(git --git-dir="$work/remote.git" log -1 --format=%B "$new") && [ -n "$msg" ] && ! grep -qi 'claude\|co-authored' <<<"$msg"
    step $? "the commit message carries no attribution"
    # no signing key: nothing pushed, the failing path
    fresh nosign
    git init -q -b feature "$work/nosign.git"
    run_fill "$work/nosign" GITHUB_HEAD_REF=feature -- --remote "$work/remote.git" >"$work/nosign.out" 2>&1
    rc=$?
    [ "$rc" -eq 1 ] && grep -q 'signing key' "$work/nosign.out" && [ "$(git --git-dir="$work/remote.git" rev-parse refs/heads/feature)" = "$new" ]
    step $? "no signing key: nothing pushed, the entries named (rc=$rc)"
else
    echo "skip the push arm: no gpg"
fi

if [ "$failures" -ne 0 ]; then
    echo "--- router.log"; tail -5 "$work/router.log"
    echo "langpacks-fill: $failures failed"
    exit 1
fi
echo "langpacks-fill: ok"
