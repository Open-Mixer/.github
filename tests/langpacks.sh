#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# The language packs (Open-Mixer/.github#37), on one distribution:  tests/langpacks.sh rpm|deb
#
# The owner fixture (tests/fixtures/langpacks/owner, catalogs ca and es, languages.json shipping both) builds its base
# package and one pack per language from its own spec or debian/, each pack owning exactly its catalog, noarch / all,
# with Supplements on the base (rpm) or a Depends on its version (deb); the packs install. The meta pack of each language, built by
# packaging/openmixer-langpacks/build.sh for the fixture owner, installs and pulls the owner's pack. Red arms: a listed
# language with no catalog, a catalog of an unlisted language, a generated block edited by hand and a spec without
# its markers are refused by langpacks.py; a meta pack naming an owner whose pack is not there does not install.
# Run as root in a container: fedora:44 or fedora:45 with rpm-build, dnf and python3; debian:bookworm or
# debian:trixie with build-essential, dpkg-dev, debhelper, lintian and python3.
set -uo pipefail
kind=${1:?usage: tests/langpacks.sh rpm|deb}
root=$(cd "$(dirname "$0")/.." && pwd)
gen=$root/.github/actions/langpacks/langpacks.py
fix=$root/tests/fixtures/langpacks
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
step() {
    if [ "$1" -eq 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failures=$((failures + 1)); fi
}
# refused <what> <expected message> <command...>: the command exits 1 and says why
refused() {
    local what=$1 want=$2 out rc
    shift 2
    out=$("$@" 2>&1); rc=$?
    [ "$rc" -eq 1 ] && grep -q -- "$want" <<<"$out"
    step $? "$what: refused ($(head -1 <<<"$out"))"
}
owner_args() {  # owner_args <dir>: the fixture owner's arguments to langpacks.py rpm|deb
    local d=$1
    if [ "$kind" = rpm ]; then echo --spec "$d/omx-fixture-owner.spec"; else echo --debian "$d/debian"; fi
    echo --name omx-fixture-owner --owner omx-fixture-owner --catalogs "$d/catalogs"
}

# ---- the generator
# shellcheck disable=SC2046
python3 "$gen" "$kind" --check $(owner_args "$fix/owner") --languages "$fix/languages.json"
step $? "the fixture's generated packs are current"

cp -r "$fix/owner" "$work/missing"
printf '{"languages": ["ca", "es", "fr"]}\n' > "$work/three.json"
# shellcheck disable=SC2046
refused "a listed language with no catalog" "no catalog for fr" \
    python3 "$gen" "$kind" --check $(owner_args "$work/missing") --languages "$work/three.json"

cp -r "$fix/owner" "$work/extra"
cp "$work/extra/catalogs/es.json" "$work/extra/catalogs/de.json"
# shellcheck disable=SC2046
refused "a catalog of a language the list does not ship" "de.json is a language the list does not ship" \
    python3 "$gen" "$kind" --check $(owner_args "$work/extra") --languages "$fix/languages.json"

cp -r "$fix/owner" "$work/stale"
if [ "$kind" = rpm ]; then f=$work/stale/omx-fixture-owner.spec; else f=$work/stale/debian/control; fi
sed -i 's/catalog of omx-fixture-owner/catalog by hand of omx-fixture-owner/' "$f"
# shellcheck disable=SC2046
refused "a generated block edited by hand" "is not what langpacks.py writes" \
    python3 "$gen" "$kind" --check $(owner_args "$work/stale") --languages "$fix/languages.json"

cp -r "$fix/owner" "$work/nomarkers"
if [ "$kind" = rpm ]; then f=$work/nomarkers/omx-fixture-owner.spec; else f=$work/nomarkers/debian/control; fi
sed -i '/^# END langpacks$/d' "$f"
# shellcheck disable=SC2046
refused "a file without its markers" "must each appear once" \
    python3 "$gen" "$kind" --check $(owner_args "$work/nomarkers") --languages "$fix/languages.json"

if [ "$kind" = deb ]; then
    cp -r "$fix/owner" "$work/moved"
    python3 "$gen" deb --debian "$work/moved/debian" --name omx-fixture-owner --owner omx-fixture-owner \
        --catalogs "$work/moved/catalogs" --languages "$fix/languages.json" --moved ca:1.0.0
    awk '/^Package: omx-fixture-owner-l10n-ca$/,/^$/' "$work/moved/debian/control" > "$work/moved.ca"
    grep -qx 'Breaks: omx-fixture-owner (<< 1.0.0~)' "$work/moved.ca" &&
        grep -qx 'Replaces: omx-fixture-owner (<< 1.0.0~)' "$work/moved.ca" &&
        ! awk '/^Package: omx-fixture-owner-l10n-es$/,/^$/' "$work/moved/debian/control" | grep -q '^Breaks:'
    step $? "a language that moves out of the owner breaks and replaces the owner before its first pack, the others do not"
    refused "a moved language the list does not name" "a listed language and the first version" \
        python3 "$gen" deb --debian "$work/moved/debian" --name omx-fixture-owner --owner omx-fixture-owner \
        --catalogs "$work/moved/catalogs" --languages "$fix/languages.json" --moved fr:1.0.0
fi

# ---- the owner's packages, from its own spec or debian/
mkdir -p "$work/out"
cp -r "$fix/owner" "$work/build"
case "$kind" in
rpm)
    rpmbuild --quiet --define "_topdir $work/rpm" --define "_sourcedir $work/build" -bb \
        "$work/build/omx-fixture-owner.spec" >"$work/build.log" 2>&1
    step $? "the owner fixture builds its base and its packs from one spec"
    find "$work/rpm/RPMS" -name '*.rpm' -exec cp {} "$work/out/" \;
    base=$(ls "$work"/out/omx-fixture-owner-1.0.0-*.rpm 2>/dev/null | grep -v langpack | head -1)
    for lang in ca es; do
        p=$(ls "$work"/out/omx-fixture-owner-langpack-$lang-1.0.0-*.noarch.rpm 2>/dev/null | head -1)
        [ -n "$p" ]
        step $? "omx-fixture-owner-langpack-$lang is built, noarch"
        [ "$(rpm -qpl "$p" 2>/dev/null)" = "/usr/share/omx-fixture-owner/catalogs/$lang.json" ]
        step $? "omx-fixture-owner-langpack-$lang owns its catalog alone: $(rpm -qpl "$p" 2>/dev/null | tr '\n' ' ')"
        [ "$(rpm -qp --supplements "$p" 2>/dev/null)" = "(omx-fixture-owner and langpacks-$lang)" ]
        step $? "it supplements the owner on a host with langpacks-$lang: $(rpm -qp --supplements "$p" 2>/dev/null)"
    done
    ! rpm -qpl "$base" 2>/dev/null | grep -q '/catalogs/'
    step $? "the owner's base package carries no catalog"
    dnf -y -q install "$base" "$work"/out/omx-fixture-owner-langpack-*.rpm >"$work/install.log" 2>&1
    step $? "the owner and its packs install"
    ;;
deb)
    (cd "$work/build" && dpkg-buildpackage -b -uc -us) >"$work/build.log" 2>&1
    step $? "the owner fixture builds its base and its packs from one debian/"
    cp "$work"/*.deb "$work/out/"
    base=$(ls "$work"/out/omx-fixture-owner_1.0.0-1_*.deb | head -1)
    for lang in ca es; do
        p=$(ls "$work"/out/omx-fixture-owner-l10n-${lang}_1.0.0-1_all.deb 2>/dev/null | head -1)
        [ -n "$p" ]
        step $? "omx-fixture-owner-l10n-$lang is built, Architecture all"
        [ "$(dpkg-deb -c "$p" | awk '$6 ~ /\.json$/ {print $6}')" = "./usr/share/omx-fixture-owner/catalogs/$lang.json" ]
        step $? "omx-fixture-owner-l10n-$lang owns its catalog alone"
        [ "$(dpkg-deb -f "$p" Section)" = localization ] && [ "$(dpkg-deb -f "$p" Depends)" = "omx-fixture-owner (= 1.0.0-1)" ]
        step $? "it is localization and depends on the owner of its version: $(dpkg-deb -f "$p" Depends)"
    done
    ! dpkg-deb -c "$base" | grep -q '/catalogs/'
    step $? "the owner's base package carries no catalog"
    apt-get install -y -qq "$base" "$work"/out/omx-fixture-owner-l10n-*.deb >"$work/install.log" 2>&1
    step $? "the owner and its packs install"
    ;;
*)
    echo "usage: tests/langpacks.sh rpm|deb" >&2
    exit 2
    ;;
esac
[ -f /usr/share/omx-fixture-owner/catalogs/ca.json ] && [ -f /usr/share/omx-fixture-owner/catalogs/es.json ]
step $? "the catalogs are where the readers look: /usr/share/omx-fixture-owner/catalogs/{ca,es}.json"

# ---- the meta packs
printf 'omx-fixture-owner omx-fixture-owner\n' > "$work/owners.txt"
"$root/packaging/openmixer-langpacks/build.sh" "$kind" "$fix/languages.json" "$work/meta" "$work/owners.txt" \
    >"$work/meta.log" 2>&1
step $? "the meta packs build for the fixture owner"
if [ "$kind" = rpm ]; then
    meta=$work/meta/$(ls "$work/meta" | grep '^openmixer-langpack-ca-' | head -1)
    dnf -y -q install "$meta" >>"$work/install.log" 2>&1
else
    meta=$work/meta/$(ls "$work/meta" | grep '^openmixer-l10n-ca_' | head -1)
    apt-get install -y -qq "$meta" >>"$work/install.log" 2>&1
fi
step $? "openmixer meta pack for ca installs over the owner's ca pack"

printf 'omx-fixture-owner omx-fixture-owner\nomx-missing-owner omx-missing-owner\n' > "$work/owners-missing.txt"
"$root/packaging/openmixer-langpacks/build.sh" "$kind" "$fix/languages.json" "$work/meta-missing" \
    "$work/owners-missing.txt" >>"$work/meta.log" 2>&1
step $? "a meta pack naming an owner with no pack still builds"
if [ "$kind" = rpm ]; then
    m=$work/meta-missing/$(ls "$work/meta-missing" | grep '^openmixer-langpack-es-' | head -1)
    ! dnf -y -q install "$m" >"$work/missing.log" 2>&1 && grep -qi "omx-missing-owner-langpack-es" "$work/missing.log"
else
    m=$work/meta-missing/$(ls "$work/meta-missing" | grep '^openmixer-l10n-es_' | head -1)
    ! apt-get install -y "$m" >"$work/missing.log" 2>&1 && grep -qi "omx-missing-owner-l10n-es" "$work/missing.log"
fi
step $? "a meta pack whose owner has no pack does not install: $(grep -oi 'omx-missing-owner[a-z0-9-]*' "$work/missing.log" | head -1)"

if [ "$failures" -ne 0 ]; then
    for f in build meta install missing; do echo "--- $f.log"; tail -15 "$work/$f.log" 2>/dev/null; done
    echo "langpacks ($kind): $failures failed"
    exit 1
fi
echo "langpacks ($kind): ok"
