// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
//
//   node --test channel/test/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bakedRows, pinsTxtRows, installSet, pluginQualifyRows, render } from '../gen-keep-list.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const committed = fs.readFileSync(path.join(here, '..', 'keep-list.txt'), 'utf8');

test('baked-versions: exact name-version-release rows keep a build, released rows are floors, bare names pin nothing', () => {
  const rows = bakedRows(`repos:\n  x: {}\nrpms:\n  mod-host: [mod-host-0.10.11-1.fc44, mod-host-protocol-devel-0.10.11-1.fc44]\n  jalv: [jalv]\n  clap-plugins:\n    - clap-aida-x\nreleased:\n  plugin-hostd: 0.19.0\n  omx-contract: 3.9.1  # floor\npins:\n  foo-1.2.3-1.fc44: x\n`, 'p');
  assert.deepEqual(rows.map((r) => `${r.pkg} ${r.version} ${r.where}`), [
    'mod-host 0.10.11-1 fedora/44/*', 'mod-host-protocol-devel 0.10.11-1 fedora/44/*',
    'plugin-hostd >=0.19.0 fedora/44/*', 'omx-contract >=3.9.1 fedora/44/*']);
});

test('pins.txt: a line with a version or a source RPM pins; a commit alone pins nothing', () => {
  const rows = pinsTxtRows('# c\nclap-headers https://x/clap 195b42a004144fab0b3cf95e9c067187d15365b7\nfoo 1.2.3\nmod-host https://h/mod-host-0.10.6.f14a230-11.fc44.src.rpm\n', 'p');
  assert.deepEqual(rows.map((r) => `${r.pkg} ${r.version}`), ['source:foo 1.2.3', 'source:mod-host 0.10.6.f14a230-11']);
});

test('zynthian install set and plugin-qualify action', () => {
  const set = installSet('X=1\nPACKAGES="plugin-hostd omx-panel"\n', 'z');
  assert.deepEqual(set.map((r) => `${r.pkg} ${r.where}`), ['plugin-hostd debian/bookworm/*', 'plugin-hostd debian/trixie/*', 'omx-panel debian/bookworm/*', 'omx-panel debian/trixie/*']);
  const pq = pluginQualifyRows(`echo "deb [signed-by=/k] https://www.openmixer.org/deb/debian/bookworm ./" | sudo tee x\nsudo apt-get install -y --no-install-recommends plugin-hostd plugin-hostd-tests\ndpkg --compare-versions "$v" ge 0.15.3 || exit 1\n`, 'q');
  assert.deepEqual(pq.map((r) => `${r.pkg} ${r.version} ${r.where}`), ['plugin-hostd >=0.15.3 debian/bookworm/amd64', 'plugin-hostd-tests newest debian/bookworm/amd64']);
});

// the committed list: every line is the generator's, and names the pin that produced it
const body = committed.split('\n').filter((l) => l && !l.startsWith('#'));
const sources = committed.split('\n').filter((l) => l.startsWith('# source ')).map((l) => l.slice(9));

test('keep-list.txt: it is non-empty and every line has four columns', () => {
  assert.ok(body.length > 0);
  for (const l of body) assert.equal(l.split('\t').length, 4, l);
});

test('keep-list.txt: every line names a pin that one of the header sources produced (no hand line)', () => {
  for (const l of body) {
    const pin = l.split('\t')[3];
    const m = pin.match(/^([^@]+@[^:]+):(.+)$/);
    assert.ok(m, `no repo@ref:file pin in: ${l}`);
    const repo = m[1].split('@')[0];
    assert.ok(sources.some((s) => s.startsWith(repo + '@') && s.includes(` ${m[2]}`)), `no header source for the pin of: ${l}`);
  }
});

test('keep-list.txt: the sum matches the lines; a hand edit or a hand-added line breaks it', () => {
  const sum = (lines) => crypto.createHash('sha256').update(lines.join('\n') + '\n').digest('hex');
  const m = committed.match(/^# sum ([0-9a-f]{64})$/m);
  assert.ok(m, 'no sum');
  assert.equal(m[1], sum(body), 'edited by hand, or not made by the generator');
  assert.notEqual(m[1], sum([...body, 'hand-added\t1.0-1\tfedora/44/*\thand']));
  assert.notEqual(m[1], sum(body.slice(1)));
});

test('render: the same rows give the same file; the sum covers the sorted unique lines', () => {
  const rows = [{ pkg: 'b', version: '1.0-1', where: 'fedora/44/*', pin: 'r@main:f' }, { pkg: 'a', version: 'newest', where: 'debian/bookworm/*', pin: 'r@main:f' }, { pkg: 'a', version: 'newest', where: 'debian/bookworm/*', pin: 'r@main:f' }];
  const a = render({ rows, sources: ['r@abc f'] });
  assert.equal(a, render({ rows: [...rows].reverse(), sources: ['r@abc f'] }));
  assert.equal(a.split('\n').filter((l) => l && !l.startsWith('#')).length, 2);
});
