<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->
<img src="openmixer-logo.svg" alt="openmixer" width="330">

# OpenMixer

**openmixer** is a free, real-time digital mixing console for Linux: a live mixer
you run on a PC, with a web UI on any tablet and hardware control surfaces.
→ https://www.openmixer.org

## What you can install

Each row is a piece you can use without the rest, with a badge that links to its latest release. Add the repository ([Install](#install))
and install by name; a dash means the piece does not ship in that form.

| Piece | Version | What it gives you | Fedora | Debian / Raspberry Pi OS | npm |
|---|---|---|---|---|---|
| [plugin-hostd](https://github.com/Open-Mixer/plugin-hostd) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/plugin-hostd?sort=semver&label=)](https://github.com/Open-Mixer/plugin-hostd/releases/latest) | CLAP and LV2 plugins, each format in a native host, in worker processes behind one mod-host socket; a crash restarts only that worker | `plugin-hostd` | `plugin-hostd` | - |
| [plugin-hostd-protocol](https://github.com/Open-Mixer/plugin-hostd-protocol) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/plugin-hostd-protocol?sort=semver&label=)](https://github.com/Open-Mixer/plugin-hostd-protocol/releases/latest) | the plugin-hostd protocol as a small C library: a superset of mod-host's text protocol, so any mod-host client works unchanged, with the verb table and its grammar | `plugin-hostd-protocol`, `plugin-hostd-protocol-devel`, `plugin-hostd-protocol-contract` | `libplugin-hostd-protocol0`, `libplugin-hostd-protocol-dev`, `plugin-hostd-protocol-contract` | - |
| [omx-clap-core](https://github.com/Open-Mixer/omx-clap-core) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/omx-clap-core?sort=semver&label=)](https://github.com/Open-Mixer/omx-clap-core/releases/latest) | `omx-clap-host`, a headless CLAP and LV2 host that speaks mod-host's protocol, one JACK client per plugin; the CLAP hosting library; the LV2 adapter library | `omx-clap-host`, `omx-clap-core`, `omx-clap-core-devel`, `omx-clap-lv2-devel` | `omx-clap-host`, `libomx-clap-core-dev`, `libomx-clap-lv2-dev` | - |
| [omx-panel](https://github.com/Open-Mixer/omx-panel) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/omx-panel?sort=semver&label=)](https://github.com/Open-Mixer/omx-panel/releases/latest) | a panel for any LV2 or CLAP plugin without drawing one: MOD GUI, controller pages, host layout | `omx-panel` | `omx-panel` | `@openmixer/omx-panel` |
| [omx-plugins](https://github.com/Open-Mixer/omx-plugins) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/omx-plugins?sort=semver&label=)](https://github.com/Open-Mixer/omx-plugins/releases/latest) | our own effects as CLAP and LV2 plugins | `omx-plugins`, `omx-plugins-clap`, `omx-plugins-lv2` | `omx-plugins` | - |
| [omx-dsp](https://github.com/Open-Mixer/omx-dsp) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/omx-dsp?sort=semver&label=)](https://github.com/Open-Mixer/omx-dsp/releases/latest) | the DSP kernels the plugins and the console share, a C library | `omx-dsp-devel` | `libomxdsp-dev` | - |
| [omx-contract](https://github.com/Open-Mixer/omx-contract) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/omx-contract?sort=semver&label=)](https://github.com/Open-Mixer/omx-contract/releases/latest) | the declarations every piece agrees on: parameters, units, limits, codes | `omx-contract-devel` | `libomx-contract-dev` | `@openmixer/omx-contract` |
| [plugin-qualify](https://github.com/Open-Mixer/plugin-qualify) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/plugin-qualify?sort=semver&label=)](https://github.com/Open-Mixer/plugin-qualify/releases/latest) | checks a plugin for real-time safety and cost before a stage runs it | `plugin-qualify` | `plugin-qualify` | - |
| [plugin-db](https://github.com/Open-Mixer/plugin-db) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/plugin-db?sort=semver&label=)](https://github.com/Open-Mixer/plugin-db/releases/latest) | the plugin database: a plugin's pin (the hashes of its files) and what is known about it in layers, one reader every host shares | `plugin-db-devel`, `plugin-db-contract` | `plugin-db-dev`, `plugin-db-contract` | - |
| [libreac](https://github.com/FreeREAC/libreac) and [reac-pw](https://github.com/FreeREAC/reac-pw) | [![release](https://img.shields.io/github/v/release/FreeREAC/libreac?label=)](https://github.com/FreeREAC/libreac/releases/latest) [![release](https://img.shields.io/github/v/release/FreeREAC/reac-pw?label=)](https://github.com/FreeREAC/reac-pw/releases/latest) | the REAC protocol and its PipeWire bridge, for Roland stageboxes | `libreac`, `reac-pw` | `libreac-dev`, `reac-pw` | - |
| [reac-stageboxes](https://github.com/FreeREAC/reac-stageboxes) | [![release](https://img.shields.io/github/v/release/FreeREAC/reac-stageboxes?label=)](https://github.com/FreeREAC/reac-stageboxes/releases/latest) | a desktop app to set phantom power, pad and gain on a Roland REAC stagebox's inputs, through reac-pw | `reac-stageboxes` | `reac-stageboxes` | - |
| [libdiginet](https://github.com/Open-Mixer/libdiginet) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/libdiginet?sort=semver&label=)](https://github.com/Open-Mixer/libdiginet/releases/latest) | the Digidesign Control&#124;24 and ProControl surface protocol over Ethernet, a C library with a probe tool | `libdiginet`, `diginet-tools` | `libdiginet-dev`, `diginet-tools` | - |
| [libsurface](https://github.com/Open-Mixer/libsurface) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/libsurface?sort=semver&label=)](https://github.com/Open-Mixer/libsurface/releases/latest) | the device behaviour every motorised control surface shares (motor faders that never fight the hand, touch, banking, repaint, meters), a C library with a Control&#124;24 module over libdiginet and a Mackie module over libmackie | `libsurface`, `libsurface-devel`, `libsurface-diginet`, `libsurface-diginet-devel`, `libsurface-mackie`, `libsurface-mackie-devel`, `surface-c24` | `libsurface0`, `libsurface-dev`, `libsurface-diginet0`, `libsurface-diginet-dev`, `libsurface-mackie0`, `libsurface-mackie-dev`, `surface-c24` | - |
| [libmackie](https://github.com/Open-Mixer/libmackie) | [![release](https://img.shields.io/github/v/tag/Open-Mixer/libmackie?sort=semver&label=)](https://github.com/Open-Mixer/libmackie/releases/latest) | Mackie Control and HUI byte for byte: the MCU codec for an X-Touch or any MCU surface, a C library with no I/O | `libmackie`, `libmackie-devel` | `libmackie0`, `libmackie-dev` | - |
| [mod-host](https://github.com/Open-Mixer/mod-host) and the protocol library | [![release](https://img.shields.io/github/v/tag/Open-Mixer/mod-host?sort=semver&label=)](https://github.com/Open-Mixer/mod-host/releases/latest) | the plugin host most of the above can drive. [A branch of our fork](https://github.com/Open-Mixer/mod-host/tree/freemixer) carries what we offer upstream; each change is an open [pull request upstream](https://github.com/mod-audio/mod-host/pulls) and the packages carry it until upstream releases | `mod-host`, `mod-host-protocol` | `libmod-host-protocol-dev` | - |

## REAC

[FreeREAC](https://github.com/FreeREAC) is the free implementation of the Roland REAC audio network that openmixer
uses for stageboxes. Besides libreac, reac-pw and reac-stageboxes above:

- [reac-protocol](https://github.com/FreeREAC/reac-protocol): the protocol reference: wire format, how to capture it, what each block means.
- [reac-tools](https://github.com/FreeREAC/reac-tools): traffic analysis and diagnostics: loss and jitter analyser, simulator, pcap parser, Wireshark dissector.
- [reac-analysis](https://github.com/FreeREAC/reac-analysis): signal analysis of captured audio: clock wobble, spectrum, per-channel decode health.
- [reac-captures](https://github.com/FreeREAC/reac-captures): the capture corpus the protocol is checked against (CC0).
- [reac-transport](https://github.com/FreeREAC/reac-transport) and [reac-repacer](https://github.com/FreeREAC/reac-repacer): REAC over OpenWrt routers and Wi-Fi: a VLAN and tunnel transport, and a relay that evens out a bursty link.
- [reac-docs](https://github.com/FreeREAC/reac-docs): the REAC-over-Wi-Fi findings and the two-router recipe.

## On a Zynthian

The OpenMixer forks of [zynthian-ui](https://github.com/Open-Mixer/zynthian-ui) and
[zynthian-sys](https://github.com/Open-Mixer/zynthian-sys) (branch `vangelis`) add an engine that runs a Zynthian
chain's LV2 and CLAP plugins through plugin-hostd, with the plugin menus ordered from the measurements
[plugin-qualify](https://github.com/Open-Mixer/plugin-qualify) records. Those records, one set per machine class (a
ZynthianOS Vangelis image on a Raspberry Pi 5, Fedora 44 on x86-64), are plugin-db's qualification layer, in
[plugin-db-qualification](https://github.com/Open-Mixer/plugin-db-qualification).

Repository, package and pkg-config names of every piece:
https://www.openmixer.org/docs/plugins-names/

## Install

Installing `openmixer-release` adds the repository and its key; `dnf update` and `apt upgrade` keep them current.

Fedora: `sudo dnf install https://www.openmixer.org/rpm/openmixer-release.noarch.rpm`

Debian and Raspberry Pi OS (bookworm, trixie): `curl -fsSLO https://www.openmixer.org/deb/openmixer-release.deb && sudo apt install ./openmixer-release.deb && sudo apt update`

## Checked

[Theorem's OSS Verify](https://github.com/theorem-labs/oss-verify) lists these projects of ours in its `projects/`:
[libdiginet](https://github.com/Open-Mixer/libdiginet), [mod-host](https://github.com/Open-Mixer/mod-host),
[omx-clap-core](https://github.com/Open-Mixer/omx-clap-core), [omx-dsp](https://github.com/Open-Mixer/omx-dsp), [plugin-hostd](https://github.com/Open-Mixer/plugin-hostd),
[libreac](https://github.com/FreeREAC/libreac), [reac-pw](https://github.com/FreeREAC/reac-pw) and [reac-repacer](https://github.com/FreeREAC/reac-repacer).
Each ships fuzz targets written to its contract. Enrollments open: [plugin-hostd-protocol](https://github.com/Open-Mixer/plugin-hostd-protocol) ([#159](https://github.com/theorem-labs/oss-verify/pull/159)), [plugin-db](https://github.com/Open-Mixer/plugin-db) ([#163](https://github.com/theorem-labs/oss-verify/pull/163)), [libmackie](https://github.com/Open-Mixer/libmackie) ([#164](https://github.com/theorem-labs/oss-verify/pull/164)) and [libsurface](https://github.com/Open-Mixer/libsurface) ([#165](https://github.com/theorem-labs/oss-verify/pull/165)).

## Also here

- [openmixer-www](https://github.com/Open-Mixer/openmixer-www): the website and documentation, <https://www.openmixer.org>.
- [open-mixer.github.io](https://github.com/Open-Mixer/open-mixer.github.io): the package repositories the install above uses.
- [plugin-db-qualification](https://github.com/Open-Mixer/plugin-db-qualification): plugin-db's qualification layer, plugin-qualify's records per machine class, packaged as `plugin-db-qualification-<class>-<set>`.
- [.github](https://github.com/Open-Mixer/.github): this page and the release workflow every package shares.
