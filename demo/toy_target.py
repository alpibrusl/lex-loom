#!/usr/bin/env python3
"""Toy HTTP target for demo/run_operate_loop.sh (#118).

Reads a one-word mode from MODE_FILE on every request: "up" (respond
immediately) or "slow" (sleep before responding) — so the orchestrating
shell script can toggle latency without restarting this process. "down" is
NOT a mode here: the orchestrator simulates that by killing this process
outright, since curl needs a real refused/timed-out connection, not just a
slow HTTP response, to register liveness as "down".
"""
import http.server
import socketserver
import sys
import time

MODE_FILE = sys.argv[1] if len(sys.argv) > 1 else "mode.txt"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8999
SLOW_SECONDS = 1.5


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        mode = "up"
        try:
            with open(MODE_FILE) as f:
                mode = f.read().strip() or "up"
        except FileNotFoundError:
            pass
        if mode == "slow":
            time.sleep(SLOW_SECONDS)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        # Deliberately silences the base class's per-request access log.
        pass


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


if __name__ == "__main__":
    with ReusableTCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
