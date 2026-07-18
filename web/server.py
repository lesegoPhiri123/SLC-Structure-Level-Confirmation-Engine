#!/usr/bin/env python3
"""Local web server for the SLC Engine visualizer.

Serves the static web/ directory plus GET /api/state, which streams
whatever JSON the MT5 EA (or the bundled sample fixture) has written.
Stdlib only -- no install step required.
"""
import http.server
import json
import os
import socketserver
from pathlib import Path

WEB_DIR = Path(__file__).resolve().parent
DEFAULT_STATE = WEB_DIR.parent / "data" / "sample_state.json"
STATE_FILE = Path(os.environ.get("SLC_STATE_FILE", DEFAULT_STATE)).expanduser()
PORT = int(os.environ.get("SLC_PORT", "8081"))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_GET(self):
        if self.path == "/api/state":
            self.handle_state()
            return
        super().do_GET()

    def handle_state(self):
        try:
            raw = STATE_FILE.read_text()
            json.loads(raw)
        except FileNotFoundError:
            self.send_error(404, f"State file not found: {STATE_FILE}")
            return
        except json.JSONDecodeError:
            # EA may be mid-write; ask the client to retry shortly.
            self.send_error(503, "State file is not valid JSON yet, retry shortly")
            return

        body = raw.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print(f"SLC web UI:      http://127.0.0.1:{PORT}")
        print(f"Reading state from: {STATE_FILE}")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
