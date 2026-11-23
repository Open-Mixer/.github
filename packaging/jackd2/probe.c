/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
 *
 * probe <name> [close]: open a JACK client, register a port, set a property on it, print READY, then wait to be
 * killed; with a second argument, close the client and print CLOSED instead. check.sh kills it with SIGKILL.
 */
#include <jack/jack.h>
#include <jack/metadata.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char** argv)
{
    jack_status_t st;
    jack_client_t* c = jack_client_open(argc > 1 ? argv[1] : "probe", JackNoStartServer, &st);
    if (!c) { fprintf(stderr, "probe: open failed 0x%x\n", st); return 1; }
    jack_port_t* p = jack_port_register(c, "in", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    jack_activate(c);
    if (jack_set_property(c, jack_port_uuid(p), JACK_METADATA_PRETTY_NAME, "probe in", NULL))
        fprintf(stderr, "probe: set_property failed\n");
    printf("READY\n"); fflush(stdout);
    if (argc > 2) { jack_client_close(c); printf("CLOSED\n"); return 0; }
    for (;;) pause();
}
