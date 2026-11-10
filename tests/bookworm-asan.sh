#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# A bookworm package build lowers mmap_rnd_bits before anything runs: bookworm's gcc 12 AddressSanitizer loops on
# DEADLYSIGNAL under the hosted runners' 32 bits until the job times out (plugin-hostd-protocol v0.5.2).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$here/.github/workflows/build-deb.yml" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["build"]
opts = job["container"].get("options", "")
assert "matrix.suite == 'bookworm'" in opts and "--privileged" in opts, f"FAIL bookworm build container not privileged: {opts!r}"
first = job["steps"][0]
assert first.get("if") == "matrix.suite == 'bookworm'" and "mmap_rnd_bits" in first["run"] and "-le 28" in first["run"], \
    "FAIL the first step of a bookworm build does not lower and check mmap_rnd_bits"
print("ok   a bookworm package build lowers mmap_rnd_bits to 28 first, privileged for it")
PY
