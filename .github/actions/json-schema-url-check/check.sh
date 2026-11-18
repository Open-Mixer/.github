#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# json-schema-url-check check.sh [ROOT] | --self-test
#
# Allow-list. Every "$schema" and every "$id" in a tracked JSON object is https://openmixer.org/schema/..., or a path
# relative to the file (and a "$schema" may be on json-schema.org). Any other host (github.com, githubusercontent.com,
# anything) is refused by file and key: a schema's identity must not move when a repository does. Every object at every
# depth is read. A file that is empty, or not a JSON object, is no schema document and is skipped; a file that does not
# parse but carries "$schema" or "$id" text is refused. A tree with no tracked JSON passes with a note.
set -euo pipefail

READER=$(cat <<'PY'
import json, re, subprocess, sys
root = sys.argv[1]
host = re.compile(r'^([a-z][a-z0-9+.-]*)://([^/?#]*@)?([^/?#:]*)', re.I)
def bad(key, value):
    v = value.strip()
    m = host.match(v)
    if not m:
        return False          # relative, or a bare name: no host named
    h = m.group(3).lower()
    if h == 'openmixer.org' and m.group(1).lower() == 'https' and v[m.end():].startswith(('/schema/', ':443/schema/')):
        return False
    if key == '$schema' and h == 'json-schema.org':
        return False
    return True
def walk(node, path, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ('$schema', '$id') and isinstance(v, str) and bad(k, v):
                out.append((path + '/' + k, v))
            walk(v, path + '/' + k, out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + '/' + str(i), out)
files = subprocess.run(['git', '-c', 'safe.directory=' + root, '-C', root, 'ls-files', '-z'],
                       check=True, capture_output=True).stdout.decode('utf-8', 'surrogateescape').split('\0')
rc, n = 0, 0
for f in files:
    if not f.endswith('.json'):
        continue
    n += 1
    try:
        with open(root + '/' + f, encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        # an empty or non-JSON file is no schema document; refuse only one that carries schema text
        try:
            text = open(root + '/' + f, encoding='utf-8', errors='replace').read()
        except OSError:
            text = ''
        if '"$schema"' in text or '"$id"' in text:
            print('json-schema-url-check: %s carries $schema or $id text but is not readable JSON: %s' % (f, e), file=sys.stderr)
            rc = 1
        continue
    if not isinstance(doc, dict):
        continue
    hits = []
    walk(doc, '', hits)
    for p, v in hits:
        print('json-schema-url-check: %s: %s is %s, a host the rule does not allow; name it under https://openmixer.org/schema/' % (f, p, v), file=sys.stderr)
        rc = 1
if n == 0:
    print('json-schema-url-check: note: git lists no JSON file, nothing to read')
sys.exit(rc)
PY
)

check() { python3 -I -c "$READER" "$1"; }

if [ "${1:-}" = --self-test ]; then
  fail=0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  plant() { # <name> <file content>
    local t=$tmp/$1; mkdir -p "$t"; git -C "$t" init -q
    printf '%s\n' "$2" >"$t/f.json"; git -C "$t" add f.json
    echo "$t"
  }
  expect() { # <name> <want 0|1> <content>
    local t rc=0; t=$(plant "$1" "$3")
    check "$t" 2>/dev/null || rc=$?
    if [ "$rc" != "$2" ]; then echo "json-schema-url-check self-test: $1 gave $rc, wanted $2" >&2; fail=1; fi
  }
  expect clean-absolute 0 '{"$schema":"https://openmixer.org/schema/omx-contract/v3/omx-contract.schema.json"}'
  expect clean-relative 0 '{"$schema":"../schema/omx-contract.schema.json","$id":"https://openmixer.org/schema/x/y.schema.json"}'
  expect prose-mentions-host 0 '{"description":"see https://github.com/Open-Mixer/x","$comment":"github.com"}'
  expect github-schema 1 '{"$schema":"https://github.com/FreeMixer/omx-contract/raw/v3/schema/omx-contract.schema.json"}'
  expect github-id 1 '{"$id":"https://github.com/Open-Mixer/omx-panel/schema/panel.schema.json"}'
  expect raw-host 1 '{"$schema":"https://raw.githubusercontent.com/Open-Mixer/x/main/s.json"}'
  expect nested-id 1 '{"a":[{"b":{"$id":"http://www.github.com/o/r/s.json"}}]}'
  expect broken-json 1 '{"$schema":'
  expect other-host 1 '{"$id":"https://example.com/s.json"}'
  expect json-schema-org 0 '{"$schema":"https://json-schema.org/draft/2020-12/schema"}'
  expect json-schema-org-id 1 '{"$id":"https://json-schema.org/x"}'
  expect empty-file 0 ''
  expect array-file 0 '[{"$id":"https://github.com/x"}]'
  expect non-json-plain 0 'not json at all'
  # a repository with no JSON file at all passes, with a note
  t=$tmp/none; mkdir -p "$t"; git -C "$t" init -q; : >"$t/a.txt"; git -C "$t" add a.txt
  check "$t" >/dev/null 2>&1 || { echo "json-schema-url-check self-test: no-json tree refused" >&2; fail=1; }
  [ "$fail" = 0 ] && echo "json-schema-url-check self-test: every case as wanted"
  exit "$fail"
fi

check "${1:-.}"
echo "json-schema-url-check: every \$schema and \$id is on the allow-list"
