#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
# doc-gate (.github/actions/doc-gate): the shared documentation gate, proven on a scratch repository under a stand-in
# doxygen (its warnings a file, its pages written as doxygen names them) and then the real one: the set compare (a new
# row, a stale row, a swapped row, a duplicate, a missing last newline, continuation lines joined), --update only ever
# lower, --list; a missing Doxyfile, baseline or pin, another doxygen version, no doxygen, no log, no page, a run from
# a subdirectory, each refused by name; a header with no @file, an untracked header, @cond and @internal, each red by
# name; a Doxyfile that silences the gate red by key, a setting behind @INCLUDE read; against the base: a watched
# setting changed red by key with both values and the accept flag one-shot, a baseline row added red, a base without
# the gate named, an empty, unknown and stale remote base refused through resolve-base; the Python half: a ruff
# finding, every form of noqa counted by ruff, a changed ruff configuration, no ruff, no configuration; sabotage: a
# count compare passes the swap, no settings check passes EXTRACT_ALL; the real doxygen: documented headers of one
# name give no row, a dropped @return warns by name, a planted EXTRACT_ALL is read back. The job installs doxygen and
# ruff; their absence is red, by name.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/.github/actions/doc-gate/doc-gate.sh" --self-test
