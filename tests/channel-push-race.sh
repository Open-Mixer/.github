#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# The push of the channel-push action against a remote that loses the race once: another publish lands on the
# branch between our commit and our push. With a rebuild command the action resets to the new tip, assembles
# the tree again, signs a new commit and pushes it: the remote ends with both publishes. Without one (the
# sabotage arm) the same race must fail the step.
#
#   channel-push-race.sh          runs both arms; needs git, gpg, python3 with PyYAML
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
action=$here/../.github/actions/channel-push/action.yml
work=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT; [ -z "${KEEP:-}" ] || echo "$work"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' "$action" > "$work/step.sh"

# a signing key for the site commits, in a keyring of its own
export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "site <site@example.org>" ed25519 sign never 2>/dev/null
SITE_GPG_KEY=$(gpg --batch --armor --export-secret-keys)
unset GNUPGHOME

# the action sleeps between attempts; the test does not wait
mkdir "$work/bin"; printf '#!/bin/sh\nexit 0\n' > "$work/bin/sleep"; chmod +x "$work/bin/sleep"

arm() { # arm <name> <rebuild command or empty>
    local name=$1 rebuild=$2 dir=$work/$1 rc=0
    mkdir -p "$dir" "$dir/tmp"
    git init -q --bare -b main "$dir/remote.git"
    git clone -q "$dir/remote.git" "$dir/seed" 2>/dev/null
    (cd "$dir/seed" && git -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m seed && git push -q origin HEAD:main)
    # the first push is overtaken: the hook moves the branch to another publish (made beforehand, so its object
    # is in the repository) and the update of the pusher is refused as not a fast-forward
    other=$(cd "$dir/remote.git" && GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=o@example.org GIT_COMMITTER_NAME=o \
        GIT_COMMITTER_EMAIL=o@example.org git commit-tree "main^{tree}" -p main -m "other publish")
    cat > "$dir/remote.git/hooks/pre-receive" <<HOOK
#!/bin/sh
[ -e "$dir/raced" ] && exit 0
touch "$dir/raced"
env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \\
  git --git-dir="$dir/remote.git" update-ref refs/heads/main $other
exit 0
HOOK
    chmod +x "$dir/remote.git/hooks/pre-receive"
    mkdir -p "$dir/run/build" && git clone -q "$dir/remote.git" "$dir/run/build/channel" 2>/dev/null
    mkdir -p "$dir/run/build/channel/rpm" && echo "package one" > "$dir/run/build/channel/rpm/one.txt"
    (cd "$dir/run" && env PATH="$work/bin:$PATH" RUNNER_TEMP="$dir/tmp" GITHUB_OUTPUT="$dir/gh-output" GITHUB_REPOSITORY=Open-Mixer/t \
        PUBLISH_TOKEN=x SITE_GPG_KEY="$SITE_GPG_KEY" BRANCH=main CHANNEL="$dir/remote.git" TAG=v1 WHAT=rpm \
        REBUILD="$rebuild" ATTEMPTS=3 bash "$work/step.sh" > "$dir/out.log" 2>&1) || rc=$?
    echo "$rc" > "$dir/rc"
}

arm with-retry 'mkdir -p build/channel/rpm && echo "package one" > build/channel/rpm/one.txt'
[ "$(cat "$work/with-retry/rc")" = 0 ] || { cat "$work/with-retry/out.log"; fail "the push did not survive one lost race"; }
files=$(git -C "$work/with-retry/remote.git" ls-tree -r --name-only main | tr '\n' ' ')
[ "$files" = "rpm/one.txt " ] || fail "the remote holds '$files', want rpm/one.txt"
git -C "$work/with-retry/remote.git" log --format=%s main | grep -qx 'other publish' || fail "the other publish was lost"
git -C "$work/with-retry/remote.git" log -1 --format=%G? main | grep -qE '^[GUE]$' || fail "the retried commit is not signed"
grep -q 'lost a race' "$work/with-retry/out.log" || fail "the retry was not announced"
[ "$(sed -n s/^commit=//p "$work/with-retry/gh-output")" = "$(git -C "$work/with-retry/remote.git" rev-parse main)" ] || fail "the commit output is not the pushed tip"

arm no-retry ''
[ "$(cat "$work/no-retry/rc")" != 0 ] || fail "without a rebuild command the lost race passed"
git -C "$work/no-retry/remote.git" ls-tree -r --name-only main | grep -q one.txt && fail "the lost push landed anyway"
echo "ok: the lost race is repeated on the new tip, and fails without the retry"

# The rebuild command is run by `bash -c` inside the job's container. A `github.action_path` expression in it is
# expanded by the runner on the HOST (/home/runner/work/...), a path the container does not have (/__w/...): the
# retry died with exit 127 on the tag run of openmixer-release-1-4. Every `rebuild:` handed to channel-push must
# name its script by a run-time variable, and hold no host path and no expression that expands to one.
python3 - "$here/../.github" <<'PY' || fail "a rebuild: input is built from the host (github.action_path or an absolute path)"
import glob, re, sys, yaml
bad, seen = [], 0
for f in sorted(glob.glob(sys.argv[1] + "/**/*.yml", recursive=True)):
    doc = yaml.safe_load(open(f))
    steps = (doc.get("runs") or {}).get("steps", []) if isinstance(doc, dict) else []
    for st in steps:
        if "channel-push" in str(st.get("uses", "")) and "rebuild" in (st.get("with") or {}):
            seen += 1
            r = str(st["with"]["rebuild"])
            if re.search(r"github\.(action_path|workspace)|runner\.(temp|workspace)|/home/runner|/__w/", r) or re.search(r'(^|[\s"\'=])/[A-Za-z_]', r):
                bad.append(f"{f}: {r}")
if seen < 2: bad.append(f"only {seen} rebuild: inputs found, want publish-rpms and publish-debs")
for b in bad: print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
echo "ok: no rebuild: input names a host path"
