<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
# mod-host: one source, the OpenMixer fork

plugin-hostd and omx-clap-host link `libmod-host-protocol.so.0`, the socket and protocol library of mod-host. Every
mod-host package OpenMixer ships, and every source build of the library in CI, comes from one place: the
[OpenMixer fork of mod-host](https://github.com/Open-Mixer/mod-host), branch `freemixer`, which carries each change
as a commit and offers each one upstream. No patch is applied here.

## The fixes, and where they live

This repository used to carry the audinux spec of mod-host with one patch file per pull request
(`packaging/mod-host`). Each of those patches is a commit of the fork; with all of them applied to upstream
`f14a230` plus upstream's later #114, the tree equals the fork's `freemixer` branch, apart from the fork's own
additions (packaging, CI, fuzz harnesses, a test for #116).

| patch | upstream pull request | fork commit (subject) |
|---|---|---|
| `mod-host-100.patch` | mod-audio/mod-host#100 | Fix three crashes found running a large plugin catalog through mod-host (#100) |
| `mod-host-101.patch` | #101 | Let 'add' name its jack client, backwards compatible (#101) |
| `mod-host-98.patch` | #98 | Memory safety fixes (#98) |
| `mod-host-81.patch` | #81 | Fixes #80. (#81) |
| `mod-host-81b.patch` | follow-up to #81 | Start the next protocol word after a run of spaces (follow-up to #81) |
| `mod-host-82.patch` | #82 | Fixes #79. (#82) |
| `mod-host-104.patch` | #104 | Three small cleanups in the socket protocol code (#104) |
| `mod-host-105.patch` | #105 | Register the effect verbs through a backend interface (#105) |
| `mod-host-106.patch` | #106 | Tests for the socket protocol, no jack needed (#106) |
| `mod-host-107.patch` | #107 | Offer the socket protocol as an opt-in shared library (#107) |
| `mod-host-108.patch` | #108 | Let a backend answer monitor_output and send output_set (#108) |
| `mod-host-109.patch` | #109 | Add plugin info commands: param_info, remote_pages, track_info (#109) |
| `mod-host-112.patch` | #112 | Do not read before an empty string when trimming spaces (#112) |
| `mod-host-113.patch` | #113 | Split socket input into NUL-terminated commands (#113) |
| `mod-host-113b.patch` | follow-up to #113 | End each protocol test command with its NUL (follow-up to #113) |
| `mod-host-116.patch` | #116 | protocol: the command table holds 128 commands, and one past it is refused out loud |
| `mod-host-bind.patch` | Open-Mixer/mod-host#12 | socket: both ports listen on 127.0.0.1 unless told otherwise |

## What is built, and from where

`.github/pins.txt` names the fork's commit; `actions/mod-host-protocol/fetch-source.sh` lays it out.

| build | how | where it is used |
|---|---|---|
| RPMs `mod-host`, `mod-host-protocol`, `mod-host-protocol-devel` | `actions/mod-host-rpms` builds the fork's `packaging/mod-host.spec` | `build-rpm.yml` (BuildRequires), `mod-host-protocol-rpm.yml` (publishes to the channel) |
| DEBs `mod-host`, `libmod-host-protocol0`, `libmod-host-protocol-dev` | `actions/deb-deps` builds the fork's own `debian/` | `build-deb.yml` (Build-Depends), `mod-host-protocol-deb.yml` (publishes to the channel) |
| library in a prefix | `actions/mod-host-protocol` runs `make lib install-lib` | CI of plugin-hostd and omx-clap-host |

Every one of them installs the library and then runs `actions/mod-host-protocol/checks/framing-test.sh`: a command
of exactly 1024 bytes, two commands in one write and one command in two writes (#113), 65 commands registered
(#116), and the ports reached from 127.0.0.1 only (the bind-address change). `tests/mod-host-fork.sh` (the
`mod-host-fork` job of `ci.yml`) also runs the fork's tests, then takes the source part of each fix out again: without
#113, #116 or the bind-address change the check above must fail, without #112 its AddressSanitizer test must fail.

## Versions and releases

The fork's version is one for both formats: `packaging/mod-host.spec` Version equals the upstream part of
`debian/changelog`, and the fork's CI refuses a difference. A `v<version>` tag of the fork attaches the RPMs and DEBs
to its GitHub release. To publish into the channel, move the `mod-host` line of `pins.txt` to the tag's commit, then
run `mod-host-protocol-rpm.yml` and `mod-host-protocol-deb.yml` on main with `publish` set; the RPM workflow refuses
to publish a snapshot build.

The fork's versions (0.10.8 and later) sort above everything the channel carried before: the RPMs
`0.10.6.f14a230-11.x.omx` built from the patches here, audinux's `0.10.6.f14a230-12`, and the DEBs `0.1.0-8~omx`.
`ci.yml` checks those comparisons. A consumer states `mod-host-protocol >= 0.10.8 < 0.11` (RPM) or
`libmod-host-protocol-dev (>= 0.10.8~), libmod-host-protocol-dev (<< 0.11~)` (DEB).
