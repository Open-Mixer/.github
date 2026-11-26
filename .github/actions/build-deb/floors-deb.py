#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""Generated lower-layer floors for debs (owner ruling 2026-11-26, .github#312), the twin of build-rpm/floors.sh.

    floors-deb.py apply-deb <deb>...       every bare name in a BUILT package's Depends/Pre-Depends (DEBIAN/control) that
                                           is an installed OpenMixer package becomes "<name> (>= <its upstream version>)";
                                           each .deb is unpacked, floored and packed again in place. The source tree's
                                           debian/control is never touched, so a repository's own no-typed-floors test,
                                           which runs inside the build, still reads its bare names
    floors-deb.py apply <debian/control>   the same on a control file (the tests' entry; build-deb.sh uses apply-deb)
    floors-deb.py check <deb>...           fails, naming each, a built package depending on an installed OpenMixer
                                           package with no version

An OpenMixer package is one whose installed version apt took from an openmixer.org source, or that was installed from a
local file (the contract-bootstrap siblings: no source but /var/lib/dpkg/status). The floor is the upstream version: a
staged sibling's +git/~git suffix and a Debian revision are dropped, so the floor still holds once the real version is
the channel's. An alternative (a | b), a versioned name, a substvar (${...}) and an architecture-qualified name are left
as they are. The source stanza (Build-Depends) is never touched. Exit 0 done, 1 a check found one, 2 usage.
FLOORS_DPKG_QUERY, FLOORS_APT_CACHE, FLOORS_DPKG_DEB name the tools (tests).
"""
import os
import re
import subprocess
import sys

DPKG_QUERY = os.environ.get('FLOORS_DPKG_QUERY', 'dpkg-query')
APT_CACHE = os.environ.get('FLOORS_APT_CACHE', 'apt-cache')
DPKG_DEB = os.environ.get('FLOORS_DPKG_DEB', 'dpkg-deb')
PLAIN = re.compile(r'^[a-z0-9][a-z0-9.+-]+$')
FIELDS = ('Depends', 'Pre-Depends')


def run(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ''


def installed_sources(policy):
    """The sources apt-cache policy lists under the installed version (the line marked ***)."""
    out, on = [], False
    for line in policy.splitlines():
        if line.startswith(' *** '):
            on = True
        elif re.match(r'^ {5}\S', line):
            on = False
        elif on and re.match(r'^ {8}-?\d+ ', line):
            out.append(line.split(None, 1)[1].strip())
    return out


def ours(name, cache={}):
    """The upstream version of an installed OpenMixer package, else None."""
    if name in cache:
        return cache[name]
    v = run(DPKG_QUERY, '-W', '-f=${Status} ${Version}\n', name).strip()
    got = None
    if v.startswith('install ok installed '):
        inst = v.split()[-1]
        sources = installed_sources(run(APT_CACHE, 'policy', name))
        if any('openmixer.org' in src for src in sources) or sources == ['/var/lib/dpkg/status']:
            up = re.split(r'[+~]git', inst)[0]
            got = up.rsplit('-', 1)[0] if '-' in up else up
    cache[name] = got
    return got


def floor_field(value, sep=',\n '):
    out, n = [], 0
    for dep in value.split(','):
        d = dep.strip()
        if not d:
            continue
        if '|' not in d and '(' not in d and '$' not in d and ':' not in d and PLAIN.match(d):
            v = ours(d)
            if v:
                print(f'floor: {d} (>= {v}) (installed in the build root)')
                out.append(f'{d} (>= {v})')
                n += 1
                continue
        out.append(d)
    return sep.join(out), n


def apply(path, sep=',\n '):
    text = open(path, encoding='utf-8').read()
    stanzas = re.split(r'\n\s*\n', text.strip('\n'))
    total = 0
    for i, st in enumerate(stanzas):
        if not re.search(r'(?m)^Package:', st):
            continue   # the source stanza
        lines, out, j = st.split('\n'), [], 0
        while j < len(lines):
            m = re.match(r'^(' + '|'.join(FIELDS) + r'):(.*)$', lines[j])
            if not m:
                out.append(lines[j]); j += 1; continue
            value, j = m.group(2), j + 1
            while j < len(lines) and lines[j][:1] in (' ', '\t'):
                value += ' ' + lines[j].strip(); j += 1
            new, n = floor_field(value, sep)
            total += n
            out.append(f'{m.group(1)}: {new}')
        stanzas[i] = '\n'.join(out)
    open(path, 'w', encoding='utf-8').write('\n\n'.join(stanzas) + '\n')
    print(f'floors: {total} generated in {path}')
    return 0


def apply_deb(debs):
    import shutil
    import tempfile
    for deb in debs:
        work = tempfile.mkdtemp()
        try:
            root = os.path.join(work, 'root')
            subprocess.run([DPKG_DEB, '-R', deb, root], check=True)
            print(f'{os.path.basename(deb)}:')
            apply(os.path.join(root, 'DEBIAN', 'control'), sep=', ')
            subprocess.run([DPKG_DEB, '--root-owner-group', '-b', root, deb], check=True, stdout=subprocess.DEVNULL)
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return 0


def check(debs):
    bad = 0
    for deb in debs:
        for field in FIELDS:
            value = run(DPKG_DEB, '-f', deb, field)
            for dep in value.replace('\n', ' ').split(','):
                d = dep.strip()
                if d and PLAIN.match(d) and ours(d):
                    print(f'{os.path.basename(deb)} {field} {d} with no version: an OpenMixer package of a lower layer '
                          f'needs its generated floor (.github#312)')
                    bad = 1
    return bad


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'apply':
        sys.exit(apply(sys.argv[2]))
    if len(sys.argv) >= 3 and sys.argv[1] == 'apply-deb':
        sys.exit(apply_deb(sys.argv[2:]))
    if len(sys.argv) >= 3 and sys.argv[1] == 'check':
        sys.exit(check(sys.argv[2:]))
    print('usage: floors-deb.py apply-deb <deb>... | apply <debian/control> | check <deb>...', file=sys.stderr)
    sys.exit(2)
