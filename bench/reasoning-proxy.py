#!/usr/bin/env python3
"""Tiny OpenAI-compatible proxy that merges reasoning_content → content.

Strips the (often huge) reasoning_content field from thinking-mode model
responses before they reach lex-loom, preventing jv.parse O(n²) blowups.

Usage:
  OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) \
    python3 bench/reasoning-proxy.py [port] [upstream_base_url] &
  PROXY_URL=http://localhost:9090 ...

The proxy listens on :port (default 9090) and forwards all requests to
upstream_base_url (default https://opencode.ai/zen/go/v1).
"""

import json
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
import os

TARGET = sys.argv[2] if len(sys.argv) > 2 else "https://opencode.ai/zen/go/v1"
PORT   = int(sys.argv[1]) if len(sys.argv) > 1 else 9090
KEY    = os.environ.get("OPENCODE_API_KEY", "")


class ProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        skip = {"host", "content-length", "transfer-encoding"}
        fwd_headers = {k: v for k, v in self.headers.items() if k.lower() not in skip}
        # Always use the configured API key
        if KEY:
            fwd_headers["Authorization"] = f"Bearer {KEY}"

        url = TARGET + self.path
        req = urllib.request.Request(url, data=body, headers=fwd_headers, method="POST")
        try:
            resp = urllib.request.urlopen(req, timeout=120)
            raw = resp.read()
            processed = self._strip_reasoning(raw)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(processed)))
            self.end_headers()
            self.wfile.write(processed)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            msg = str(e).encode()
            self.send_response(502)
            self.end_headers()
            self.wfile.write(msg)

    def _strip_reasoning(self, raw: bytes) -> bytes:
        try:
            obj = json.loads(raw)
            for choice in obj.get("choices", []):
                msg = choice.get("message", {})
                rc = msg.pop("reasoning_content", None)
                # Only surface reasoning as content when the response is a text
                # reply (no tool_calls). Tool-call responses always have empty
                # content by design — moving a huge reasoning trace there would
                # make jv.parse blow the 10M-step limit for nothing.
                has_tool_calls = bool(msg.get("tool_calls"))
                if rc and not has_tool_calls:
                    existing = msg.get("content") or ""
                    if not str(existing).strip():
                        msg["content"] = rc
            return json.dumps(obj, ensure_ascii=False).encode()
        except Exception:
            return raw

    def log_message(self, fmt, *args):
        print(f"[proxy] {self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    server = HTTPServer(("", PORT), ProxyHandler)
    print(f"[proxy] listening on :{PORT} → {TARGET}", flush=True)
    server.serve_forever()
