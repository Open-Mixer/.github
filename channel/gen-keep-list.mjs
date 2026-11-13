#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
//
// Generate channel/keep-list.txt: every package version the package channel (Open-Mixer/open-mixer.github.io)
// must keep besides the newest builds, each with the pin that keeps it. The list is never edited by hand:
// tests/channel-keep-list.sh fails a line that no source in the header produced, and a file whose lines do
// not match its checksum.
//
//   gen-keep-list.mjs [--out channel/keep-list.txt] [--worker-image <owner/repo>] [--local <owner/repo>=<dir>]...
//
// A line is "<package> <version> <distro/arch> <pin>", tab separated. <version> is
//   0.10.11-1   that exact build: the prune keeps it
//   0.15.3      that upstream version (the newest build of it): the prune keeps it
//   >=0.19.0    a floor: keeps nothing extra, but the channel must serve a version at or above it
//   newest      the package is installed unversioned: the channel must serve it
// <package> is a binary package name, or source:<name> for every package built from that source. <distro/arch>
// is e.g. fedora/44/*, debian/bookworm/amd64.
//
// The sources (read from the default branch, or from a --local checkout):
//   the worker image's repository (private: --worker-image <owner/repo> or OMX_WORKER_IMAGE_REPO; it is named
//                         in the output by its role only)  k8s/omx-worker/images/*/baked-versions.yml   exact rpm rows, and the released floors
//   Open-Mixer/.github     .github/pins.txt                             lines that name a version
//   Open-Mixer/zynthian-sys scripts/recipes/install_openmixer.sh at every omx-track/* tag: what a device installs
//   Open-Mixer/plugin-qualify .github/actions/install-plugin-hostd/action.yml   the plugin-hostd it fetches
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const gh = (...a) => execFileSync('gh', ['api', ...a], { encoding: 'utf8', maxBuffer: 1 << 28 });

// reader: { text(repo, ref, file), sha(repo, ref), list(repo, ref, dir) } over gh or --local checkouts
export function makeReader(locals = {}) {
  const git = (dir, ...a) => execFileSync('git', ['-C', dir, ...a], { encoding: 'utf8', maxBuffer: 1 << 28 });
  return {
    text(repo, ref, file) {
      if (locals[repo]) return git(locals[repo], 'show', `${ref || 'HEAD'}:${file}`);
      return Buffer.from(gh(`repos/${repo}/contents/${file}${ref ? `?ref=${encodeURIComponent(ref)}` : ''}`, '--jq', '.content'), 'base64').toString('utf8');
    },
    sha(repo, ref) {
      if (locals[repo]) return git(locals[repo], 'rev-parse', `${ref || 'HEAD'}^{commit}`).trim();
      return gh(`repos/${repo}/commits/${encodeURIComponent(ref || 'HEAD')}`, '--jq', '.sha').trim();
    },
    files(repo, ref, re) {
      if (locals[repo]) return git(locals[repo], 'ls-tree', '-r', '--name-only', ref || 'HEAD').split('\n').filter((f) => re.test(f));
      return gh(`repos/${repo}/git/trees/${encodeURIComponent(ref || 'HEAD')}?recursive=1`, '--jq', '.tree[].path').split('\n').filter((f) => re.test(f));
    },
    tags(repo, prefix) {
      if (locals[repo]) return git(locals[repo], 'tag', '-l', `${prefix}*`).split('\n').filter(Boolean).sort();
      return gh(`repos/${repo}/git/matching-refs/tags/${prefix}`, '--jq', '.[].ref').split('\n').filter(Boolean).map((r) => r.replace('refs/tags/', '')).sort();
    },
  };
}

const NVR = /^(.+)-(\d[\w.~+]*)-(\d[\w.~+]*)\.fc(\d+)$/;

// baked-versions.yml -> exact rows from rpms:, floors from released:
export function bakedRows(text, pin) {
  const out = [];
  let section = null;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+#.*$/, '');
    const top = line.match(/^([a-z]+):\s*$/);
    if (top) { section = top[1]; continue; }
    if (section === 'rpms') {
      for (const tok of line.replace(/^\s*(- |[A-Za-z0-9_.+-]+:\s*)/, '').replace(/[\[\]]/g, '').split(',')) {
        const m = tok.trim().match(NVR);
        if (m) out.push({ pkg: m[1], version: `${m[2]}-${m[3]}`, where: `fedora/${m[4]}/*`, pin });
      }
    } else if (section === 'released') {
      const m = line.match(/^ {2}([A-Za-z0-9_.+-]+):\s*"?(\d[\w.~+-]*)"?\s*$/);
      if (m) out.push({ pkg: m[1], version: `>=${m[2]}`, where: 'fedora/44/*', pin });
    }
  }
  return out;
}

// .github/pins.txt: "<name> <version> ..." lines and source RPM names
export function pinsTxtRows(text, pin) {
  const out = [];
  for (const raw of text.split('\n')) {
    const line = raw.replace(/#.*$/, '').trim();
    if (!line) continue;
    const [name, ...rest] = line.split(/\s+/);
    const v = rest.map((t) => t.match(/^v?(\d+\.\d+\.\d+)$/)).find(Boolean);
    if (v) out.push({ pkg: `source:${name}`, version: v[1], where: '*', pin });
    for (const t of rest) {
      const s = t.split('/').pop().match(/^(.+)-([^-]+)-([^-]+?)(?:\.fc\d+)?\.src\.rpm$/);
      if (s) out.push({ pkg: `source:${s[1]}`, version: `${s[2]}-${s[3]}`, where: 'fedora/*', pin });
    }
  }
  return out;
}

// install_openmixer.sh: PACKAGES="a b c"
export function installSet(text, pin) {
  const m = text.match(/^PACKAGES="([^"]*)"/m);
  if (!m) return [];
  return m[1].split(/\s+/).filter(Boolean).flatMap((pkg) =>
    ['bookworm', 'trixie'].map((s) => ({ pkg, version: 'newest', where: `debian/${s}/*`, pin })));
}

// the plugin-qualify action: apt-get install ... plugin-hostd plugin-hostd-tests; dpkg --compare-versions ... ge X
export function pluginQualifyRows(text, pin) {
  const out = [];
  const suite = (text.match(/debian\/(\w+)\s+\.\/\s*"?\s*\|/) || text.match(/debian\/(\w+) \.\//) || [])[1];
  const inst = text.match(/apt-get install\b[^\n]*?--no-install-recommends\s+([^\n]+)/);
  const floor = text.match(/compare-versions\s+"\$v"\s+ge\s+(\d[\w.~+-]*)/);
  if (!suite || !inst) return out;
  const pkgs = inst[1].trim().split(/\s+/);
  for (const pkg of pkgs) out.push({ pkg, version: pkg === 'plugin-hostd' && floor ? `>=${floor[1]}` : 'newest', where: `debian/${suite}/amd64`, pin });
  return out;
}

export function collect(reader, workerImage) {
  const rows = [];
  const sources = [];
  // this file is public: a private repository is named by its role and a file name, never by its path
  const PRIVATE = { [workerImage]: 'worker-image' };
  const src = (repo, ref, file, fn) => {
    const sha = reader.sha(repo, ref);
    const label = PRIVATE[repo] || repo;
    const shown = PRIVATE[repo] ? path.basename(file) : file;
    const pin = `${label}@${ref || 'default'}:${shown}`;
    sources.push(`${label}@${sha.slice(0, 12)} ${shown}${ref ? ` (${ref})` : ''}`);
    rows.push(...fn(reader.text(repo, ref, file), pin));
  };
  for (const f of reader.files(workerImage, 'main', /^k8s\/omx-worker\/images\/[^/]+\/baked-versions\.yml$/)) {
    src(workerImage, 'main', f, bakedRows);
  }
  src('Open-Mixer/.github', 'main', '.github/pins.txt', pinsTxtRows);
  for (const tag of reader.tags('Open-Mixer/zynthian-sys', 'omx-track/')) {
    src('Open-Mixer/zynthian-sys', tag, 'scripts/recipes/install_openmixer.sh', installSet);
  }
  src('Open-Mixer/plugin-qualify', 'main', '.github/actions/install-plugin-hostd/action.yml', pluginQualifyRows);
  return { rows, sources };
}

const key = (r) => [r.pkg, r.version, r.where, r.pin].join('\t');
export function render({ rows, sources }) {
  const lines = [...new Set(rows.map(key))].sort();
  const sum = crypto.createHash('sha256').update(lines.join('\n') + '\n').digest('hex');
  return [
    '# GENERATED by channel/gen-keep-list.mjs from the pins named below. Never edit by hand: tests/channel-keep-list.sh fails a',
    '# line no source produced and a file whose lines do not match the sum.',
    '# columns (tab separated): package, version (N-R | N | >=floor | newest), distro/arch, the pin that keeps it',
    ...sources.map((s) => `# source ${s}`),
    ...lines,
    `# sum ${sum}`,
    '',
  ].join('\n');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const locals = {};
  let out = 'channel/keep-list.txt';
  let workerImage = process.env.OMX_WORKER_IMAGE_REPO || '';
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--out') out = args[++i];
    else if (args[i] === '--worker-image') workerImage = args[++i];
    else if (args[i] === '--local') { const [r, d] = args[++i].split('='); locals[r] = d; }
    else { console.error(`unknown argument ${args[i]}`); process.exit(2); }
  }
  if (!workerImage) { console.error('the worker image repository is needed: --worker-image <owner/repo> or OMX_WORKER_IMAGE_REPO'); process.exit(2); }
  const text = render(collect(makeReader(locals), workerImage));
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, text);
  console.log(`${out}: ${text.split('\n').filter((l) => l && !l.startsWith('#')).length} line(s)`);
}
