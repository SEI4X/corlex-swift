#!/usr/bin/env python3
"""A stand-in for the Corlex stack, to try the example app without Docker.

    python3 stub-ingest.py [port] [log-file]

Answers POST /v1/batch like ingest (202) and GET /v1/config/document like edge-config (a small
document with an ETag, 304 when If-None-Match matches), accepts POST .../symbols, and appends
one JSON line per request to the log file: the events of a batch are printed in full. Keys are
checked for the header only and never logged.
"""
import gzip
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
LOG = sys.argv[2] if len(sys.argv) > 2 else "stub-ingest.log"

DOCUMENT = {
    "version": 3,
    "etag": '"v3-stub000000ab"',
    "params": [
        {"k": "welcome_banner", "t": "string", "v": "Hello from Remote Config", "r": 10000},
        {"k": "show_new_checkout", "t": "bool", "v": True, "r": 10000},
    ],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def record(self, entry):
        with open(LOG, "a") as out:
            out.write(json.dumps(entry) + "\n")

    def body(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        return gzip.decompress(raw) if self.headers.get("Content-Encoding") == "gzip" else raw

    def reply(self, status, payload=b"{}", headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        data = self.body()
        if self.path.startswith("/v1/batch"):
            events = json.loads(data)["events"]
            self.record({"path": "/v1/batch", "key_header": bool(self.headers.get("X-Corlex-Key")), "events": events})
            self.reply(202, json.dumps({"accepted": len(events), "rejected": []}).encode())
        else:
            self.record({"path": self.path.split("?")[0], "query": self.path.partition("?")[2],
                         "auth": bool(self.headers.get("Authorization")), "bytes": len(data)})
            self.reply(201, b'{"stored": true, "key": "stub"}')

    def do_GET(self):
        if not self.path.startswith("/v1/config/document"):
            return self.reply(404)
        self.record({"path": "/v1/config/document", "if_none_match": self.headers.get("If-None-Match")})
        if self.headers.get("If-None-Match") == DOCUMENT["etag"]:
            return self.reply(304, b"", {"ETag": DOCUMENT["etag"]})
        self.reply(200, json.dumps(DOCUMENT).encode(), {"ETag": DOCUMENT["etag"]})


if __name__ == "__main__":
    print(f"stub ingest on http://127.0.0.1:{PORT}, log: {LOG}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
