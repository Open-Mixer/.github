<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com> -->

# jackd2 with the jack2 metadata fix

Debian's jackd2 (1.9.22 in trixie) stores JACK metadata in a Berkeley DB environment
in `/dev/shm/jack_db-<uid>`. Every client process allocates mutexes there, 9 of them with libdb 5.3. A
client that dies without `jack_client_close` (a crash, SIGKILL) never returns them. Once the fixed mutex
region is full, every client fails with `BDB2034 unable to allocate memory for mutex`. On a Zynthian this
took six unclean deaths, and on amd64 157. Restarting jackd does not clear it, because the next server
joins the environment it finds. Upstream issue:
[jackaudio/jack2#988](https://github.com/jackaudio/jack2/issues/988). Our analysis is in
[Open-Mixer/zynthian-sys#24](https://github.com/Open-Mixer/zynthian-sys/issues/24).

The fix is three jack2 commits, offered upstream. Here they are one quilt patch,
`patches/jack2-metadata-reclaim-dead-clients.patch`, with a DEP-3 header. It changes three things:

- The environment tracks the processes that use it.
- The server calls `DB_ENV->failchk` at every client removal.
- At start, the server recreates the environment only when no process can use it.

## What is built

The source is Debian's packaging repository, untouched, at the commit of the `jackd2-trixie` line of
`.github/pins.txt`. No bookworm package is built, by the owner ruling of 2026-11-16 that no release is built for
bookworm; the patch applies to bookworm's 1.9.21 as well, and a `jackd2-bookworm` pin is all a bookworm build would
need. `make-source.sh` lays it out, appends the patch to `debian/patches/series` and adds a
`<Debian version>+omx1` changelog entry. That version sorts above the Debian build it replaces, and also
above a trixie stable update of the same upload (`+deb13u1` sorts below `+omx1`). A stable update of
jackd2 therefore moves the pin here, or this build would hide it. The deb-deps action builds it with Debian's own `debian/`. Lintian fails on an error
only, because the warnings in Debian's packaging are Debian's to fix. The packages are `jackd2`,
`libjack-jackd2-0`, `libjack-jackd2-dev` and `jackd2-firewire`. A tag `jackd2-*` publishes them through
`.github/workflows/jackd2-deb.yml`. No RPM is built: the Fedora hosts we ship run PipeWire's JACK
(`pipewire-jack-audio-connection-kit`), not jack2's jackd.

## Proof

`tests/jackd2-metadata.sh` runs as root in a `debian:trixie` container. It uses `check.sh` and
`probe.c`, which kill a probe client with SIGKILL 200 times and then SIGKILL and restart jackd:

1. Debian's own jackd2 must LEAK. This is the positive control.
2. Ours, built from the pin and installed over it, must be FIXED: the in-use mutex count stays the same
   after every death, and a client opens after the restart.
3. Our version must sort above Debian's.
4. The same source built with `JACKD2_WITHOUT_PATCH=1` must LEAK again.

## When this goes away

When upstream jack2 and Debian's jackd2 carry the fix, one commit removes all of these together:

- this directory;
- the `jackd2-trixie` line of `.github/pins.txt`;
- the workflow and the test;
- the apt pin in zynthian-sys (`/etc/apt/preferences.d/openmixer-jackd2`).

Until then, a new Debian upload of jackd2 moves the pin, and the patch must still apply to it.
