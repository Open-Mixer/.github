#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# json-schema-url-check check.sh [ROOT] | --self-test
#
# Every "$schema" and every "$id" in a tracked JSON file names an address on https://openmixer.org/schema/, or a path
# relative to the file. One that points at github.com or githubusercontent.com (any organisation, any subdomain) is
# refused by file and key: a schema's identity must not move when a repository does. Every object at every depth is
# read, so a nested definition's "$id" counts. A file that is not valid JSON is named and fails too, never skipped.
set -euo pipefail

READER=$(cat <<'PY'
import json, re, subprocess, sys
root = sys.argv[1]
host = re.compile(r'^[a-z][a-z0-9+.-]*://([^/?#]*@)?([^/?#:]*)', re.I)
def bad(value):
    m = host.match(value.strip())
    if not m:
        return False
    h = m.group(2).lower()
    return h == 'github.com' or h.endswith('.github.com') or h == 'githubusercontent.com' or h.endswith('.githubusercontent.com')
def walk(node, path, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in ('$schema', '$id') and isinstance(v, str) and bad(v):
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
        print('json-schema-url-check: %s is not readable JSON: %s' % (f, e), file=sys.stderr)
        rc = 1
        continue
    hits = []
    walk(doc, '', hits)
    for p, v in hits:
        print('json-schema-url-check: %s: %s is %s, a code-hosting address; name it under https://openmixer.org/schema/' % (f, p, v), file=sys.stderr)
        rc = 1
if n == 0:
    print('json-schema-url-check: git lists no JSON file', file=sys.stderr)
    rc = 1
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
  # a repository with no JSON file at all is an error, not a pass
  t=$tmp/none; mkdir -p "$t"; git -C "$t" init -q; : >"$t/a.txt"; git -C "$t" add a.txt
  if check "$t" 2>/dev/null; then echo "json-schema-url-check self-test: no-json tree passed" >&2; fail=1; fi
  [ "$fail" = 0 ] && echo "json-schema-url-check self-test: every case as wanted"
  exit "$fail"
fi

check "${1:-.}"
echo "json-schema-url-check: no \$schema or \$id names a code host"
