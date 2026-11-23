#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""A fixture router for tests/langpacks-fill.sh: POST /v1/chat/completions answers each entry of omx-contract translate's
request with '[<lang>] <source sentence>' (placeholders kept), only for the Bearer key it was started with; every other
path, /router/settings and /model_group/info included, is a 404 (an endpoint with no router settings is no router, so
translate finds no paid fallback). Usage: router.py <port file> <key>; it logs one line per call to stderr."""
import http.server
import json
import sys

PORTFILE, KEY = sys.argv[1], sys.argv[2]


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, doc):
        body = json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(404, {"error": "no such path"})

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        req = json.loads(self.rfile.read(n))
        if self.path != "/v1/chat/completions":
            return self.reply(404, {"error": "no such path"})
        if self.headers.get("authorization") != "Bearer " + KEY:
            print("router: refused a call without the key", file=sys.stderr, flush=True)
            return self.reply(401, {"error": "bad key"})
        user = req["messages"][-1]["content"]
        want = json.loads(user.split("\n", 1)[1])
        out = {k: "[%s] %s" % (want["lang"], v["text"]) for k, v in want["entries"].items()}
        print("router: %s %s" % (want["lang"], ",".join(sorted(out))), file=sys.stderr, flush=True)
        self.reply(200, {"model": "draft-prose", "choices": [{"message": {"content": json.dumps(out)}}]})


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(PORTFILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
