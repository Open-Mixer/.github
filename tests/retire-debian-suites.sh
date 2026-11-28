#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# tools/retire-debian-suites.sh on a stub channel built by the publish's own tree script (publish-debs/publish-tree.sh),
# signed by a throwaway key, holding bookworm and trixie in deb/ and an empty bookworm skeleton in staging/deb, as the
# real channel did on 2026-11-28. Proves, with the repository's own release-matrix lists (owner ruling 2026-11-28: Debian
# trixie only, the published bookworm packages removed from every channel):
#   - bookworm, in neither full.txt nor frozen.txt, leaves deb/ and staging/deb whole: packages, Packages, Release,
#     InRelease, Release.gpg; no path under debian/bookworm is left;
#   - trixie keeps its packages and its index byte for byte, and its InRelease still verifies against the served key;
#   - the changelog of a source version only bookworm served goes; one trixie serves too stays;
#   - cells.tsv names no bookworm cell, and nothing else of the channel changed;
#   - a second run finds nothing to retire and changes nothing; a devel tree with trixie alone is left as it is;
#   - a release frozen.txt lists stays (what the real frozen.txt did before the ruling: the suite stays);
#   - refused, nothing removed: a trixie InRelease that does not verify, a checkout with changes, lists naming no Debian
#     release, a tree outside deb, staging/deb and devel/<wave>/deb;
#   - sabotage: tree scripts that write anything else (a cells.sh writing a site file) are refused by the audit.
# Needs dpkg-dev apt-utils gnupg gpgv git (a debian:trixie container); writes nothing outside a scratch directory.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
root=$here/..
tool=$root/tools/retire-debian-suites.sh
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

export GNUPGHOME=$work/gnupg; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'Retire Test <retire@example.org>' ed25519 sign 1y
KEY=$(gpg --with-colons --fingerprint retire@example.org | awk -F: '/^fpr:/ {print $10; exit}')
export PINNED_FINGERPRINTS=$work/pinned.txt
printf '%s packages throwaway\n' "$KEY" > "$PINNED_FINGERPRINTS"
mkdir "$work/no-committed"; export SERVED_KEYS_DIR=$work/no-committed
export CHANGELOGS_URL=https://www.openmixer.org/deb/changelogs CHANNEL_REPO=Test/stub-channel
unset GITHUB_REPOSITORY_OWNER

mkdeb() { # <suite> <name> <version> <arch> [source]
    local d=$work/db-$1-$2-$3-$4
    mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$2" "$work/src-$1"
    printf '%s\n' "Package: $2" "Version: $3" "Architecture: $4" 'Maintainer: t <t@example.org>' 'Description: t' > "$d/DEBIAN/control"
    [ -z "${5:-}" ] || echo "Source: $5" >> "$d/DEBIAN/control"
    printf '%s (%s) unstable; urgency=medium\n\n  * t\n\n -- t <t@example.org>  Sat, 28 Nov 2026 12:00:00 +0100\n' "${5:-$2}" "$3" |
        gzip -9n > "$d/usr/share/doc/$2/changelog.Debian.gz"
    mkdir -p "$work/src-$1/$1"
    dpkg-deb --root-owner-group -b "$d" "$work/src-$1/$1/$2_$3_$4.deb" >/dev/null
}
ch=$work/channel
mkdir -p "$work/none" "$ch/deb" "$ch/staging/deb" "$ch/devel/devel-wave-t/deb"
echo '<html>site</html>' > "$ch/index.html"
git -C "$ch" init -q
commit() { (cd "$ch" && git add -A && git -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -q --allow-empty -m "$1"); }
# bookworm: a source only it serves (plugin-qualify 0.20.3), and one trixie serves too (clap-headers 1.2.10)
mkdeb bookworm plugin-qualify 0.20.3 amd64
mkdeb bookworm libsurface0 0.2.3 arm64 libsurface
mkdeb bookworm clap-headers 1.2.10-1 all
mkdeb trixie clap-headers 1.2.10-1 all
mkdeb trixie libomx-domain0 0.23.4 amd64 omx-contract
mkdeb trixie libsurface0 0.2.4 arm64 libsurface
for s in bookworm trixie; do "$root/.github/actions/publish-debs/publish-tree.sh" "$ch/deb" "$work/src-$s" "$KEY" >/dev/null; done
# staging: the empty bookworm skeleton a purge left; devel: a wave with trixie alone
SKELETON='bookworm trixie' LABEL=OpenMixer-Staging EMPTY_OK=true "$root/.github/actions/publish-debs/publish-tree.sh" "$ch/staging/deb" "$work/none" "$KEY" >/dev/null
"$root/.github/actions/publish-debs/publish-tree.sh" "$ch/devel/devel-wave-t/deb" "$work/src-trixie" "$KEY" >/dev/null
for p in deb/debian/bookworm/InRelease staging/deb/debian/bookworm/InRelease deb/changelogs/p/plugin-qualify/plugin-qualify_0.20.3_changelog \
    deb/changelogs/c/clap-headers/clap-headers_1.2.10-1_changelog; do
    [ -f "$ch/$p" ] || fail "the stub channel has no $p"
done
grep -q bookworm "$ch/deb/cells.tsv" || fail "the stub channel's cells.tsv names no bookworm cell"
commit stub
gpg --batch --export "$KEY" > "$work/keyring.gpg"
fingerprint() { (cd "$ch" && find deb/debian/trixie staging/deb/debian/trixie deb/openmixer.asc -type f | LC_ALL=C sort | xargs sha256sum); }
fingerprint > "$work/trixie.before"

# ---- a frozen release stays: the real frozen.txt before the 2026-11-28 ruling listed deb bookworm
printf 'deb bookworm\n' > "$work/frozen-bookworm.txt"
FROZEN=$work/frozen-bookworm.txt "$tool" "$ch" deb > "$work/frozen.log" 2>&1 || { cat "$work/frozen.log"; fail "a run with bookworm frozen failed"; }
[ -d "$ch/deb/debian/bookworm" ] && [ -z "$(git -C "$ch" status --porcelain)" ] || fail "a frozen bookworm was retired"
grep -q 'nothing to retire' "$work/frozen.log" || fail "a frozen bookworm run does not say there is nothing to retire: $(cat "$work/frozen.log")"
ok "a Debian release frozen.txt lists stays, and the tree is left as it is"

# ---- refusals, nothing removed
refused() { # <what> <pattern> <command...>
    local what=$1 pat=$2; shift 2
    if "$@" > "$work/r.log" 2>&1; then cat "$work/r.log"; fail "$what: not refused"; fi
    grep -q -- "$pat" "$work/r.log" || fail "$what: refused without naming it: $(cat "$work/r.log")"
    [ -z "$(git -C "$ch" status --porcelain)" ] || { git -C "$ch" status --short | head; fail "$what: the refusal changed the channel"; }
    ok "refused: $what"
}
refused "a tree outside deb, staging/deb and devel/<wave>/deb" "not 'rpm'" "$tool" "$ch" rpm
printf '# none\nrpm 45 x86_64\n' > "$work/no-deb.txt"
refused "lists naming no Debian release" 'name no Debian release' env FULL_MATRIX="$work/no-deb.txt" FROZEN="$work/no-deb.txt" "$tool" "$ch" deb
cp "$ch/deb/debian/trixie/InRelease" "$work/InRelease.keep"
sed -i 's/^Suite: trixie/Suite: trixie2/' "$ch/deb/debian/trixie/InRelease"; commit tampered
printf 'rpm 44\n' > "$work/frozen-none.txt"
refused "a trixie InRelease that does not verify" 'does not verify' env FROZEN="$work/frozen-none.txt" "$tool" "$ch" deb
cp "$work/InRelease.keep" "$ch/deb/debian/trixie/InRelease"; commit restored
echo x > "$ch/stray"
if FROZEN=$work/frozen-none.txt "$tool" "$ch" deb > "$work/r.log" 2>&1; then fail "a checkout with changes: not refused"; fi
grep -q 'changes before the run' "$work/r.log" && [ -d "$ch/deb/debian/bookworm" ] || fail "a checkout with changes: $(cat "$work/r.log")"
rm -f "$ch/stray"
ok "refused: a checkout with changes"

# ---- sabotage: tree scripts that write anything else are refused by the audit
sab=$work/sab
mkdir -p "$sab/tools" "$sab/.github/actions"
cp "$tool" "$sab/tools/"; cp -r "$root/.github/actions/release-matrix" "$sab/.github/actions/"
printf '#!/bin/bash\necho site > "%s/index.html"\n' "$ch" >> "$sab/.github/actions/release-matrix/cells.sh"
if FROZEN=$work/frozen-none.txt "$sab/tools/retire-debian-suites.sh" "$ch" deb > "$work/sab.log" 2>&1; then cat "$work/sab.log"; fail "sabotage: a cells.sh writing index.html passed the audit"; fi
grep -q 'refused: index.html changed' "$work/sab.log" || fail "sabotage: the audit does not name index.html: $(cat "$work/sab.log")"
ok "sabotage: a tree script that writes a site file is refused by the audit"
git -C "$ch" reset -q --hard; git -C "$ch" clean -qfd

# ---- the retirement, with the repository's own full.txt and frozen.txt
base=$(git -C "$ch" rev-parse HEAD)
# one tree a run, as the workflow's retire jobs push them: each starts from a clean checkout
for t in deb staging/deb devel/devel-wave-t/deb; do
    "$tool" "$ch" "$t" > "$work/run-${t//\//_}.log" 2>&1 || { cat "$work/run-${t//\//_}.log"; fail "$t: the retirement failed"; }
    commit "retired $t"
done
cat "$work/run-deb.log"
left=$(cd "$ch" && git ls-files --others --cached --exclude-standard | grep -E '(^|/)bookworm(/|$)' || true)
[ ! -e "$ch/deb/debian/bookworm" ] && [ ! -e "$ch/staging/deb/debian/bookworm" ] && [ -z "$left" ] ||
    fail "bookworm is still served (frozen.txt or full.txt still keeps it?): $(find "$ch" -path '*bookworm*' | head)"
for f in debian/bookworm/InRelease debian/bookworm/Packages debian/bookworm/amd64/plugin-qualify_0.20.3_amd64.deb; do
    grep -qx "removed deb/$f" "$work/run-deb.log" || fail "deb/$f is not named as removed"
done
grep -qx 'removed staging/deb/debian/bookworm/Release.gpg' "$work/run-staging_deb.log" || fail "the staging skeleton's index is not named as removed"
ok "bookworm leaves deb/ and staging/deb whole, packages and index, each path named"
fingerprint | cmp -s - "$work/trixie.before" || fail "trixie or the key file changed: $(fingerprint | diff "$work/trixie.before" - | head)"
for d in deb staging/deb devel/devel-wave-t/deb; do
    gpgv --keyring "$work/keyring.gpg" "$ch/$d/debian/trixie/InRelease" >/dev/null 2>&1 || fail "$d trixie InRelease does not verify"
done
ok "trixie keeps its packages and index byte for byte, and its InRelease verifies with the key"
[ ! -e "$ch/deb/changelogs/p/plugin-qualify" ] || fail "the changelog only bookworm served stayed"
[ -f "$ch/deb/changelogs/c/clap-headers/clap-headers_1.2.10-1_changelog" ] || fail "the changelog trixie serves too went"
[ -f "$ch/deb/changelogs/libs/libsurface/libsurface_0.2.4_changelog" ] && [ ! -e "$ch/deb/changelogs/libs/libsurface/libsurface_0.2.3_changelog" ] ||
    fail "libsurface: the 0.2.3 changelog only bookworm served should go, the 0.2.4 trixie serves stay"
ok "a changelog only bookworm served goes, one trixie serves stays"
! grep -q bookworm "$ch/deb/cells.tsv" "$ch/staging/deb/cells.tsv" || fail "cells.tsv still names bookworm"
grep -q 'trixie/all' "$ch/deb/cells.tsv" || fail "cells.tsv lost trixie"
[ -z "$(git -C "$ch" diff --name-only "$base" HEAD -- . ':(exclude)deb' ':(exclude)staging/deb')" ] || fail "the retirement wrote outside the deb trees"
grep -q 'nothing to retire' "$work/run-devel_devel-wave-t_deb.log" || fail "the devel tree with trixie alone was not left as it is"
ok "cells.tsv names no bookworm; nothing outside the deb trees changed; the trixie-only devel tree is untouched"

# ---- again: nothing to retire, nothing changes
for t in deb staging/deb; do
    "$tool" "$ch" "$t" > "$work/again.log" 2>&1 || { cat "$work/again.log"; fail "$t: the second run failed"; }
    grep -q 'nothing to retire' "$work/again.log" || fail "$t: the second run does not say there is nothing to retire"
done
[ -z "$(git -C "$ch" status --porcelain)" ] || fail "the second run changed the channel"
ok "a second run finds nothing and changes nothing"
echo "retire-debian-suites: ok"
