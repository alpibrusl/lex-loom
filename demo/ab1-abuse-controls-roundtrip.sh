#!/usr/bin/env bash
# ab1-abuse-controls-roundtrip.sh -- the abuse gate (#449) proven both ways:
# a compliant endpoint passes all four checks; an endpoint that forgot rate
# limiting fails on exactly that; an endpoint that refuses genuine submissions
# fails FIRST on that, however well it blocks bots. Stdlib servers only; no
# model, no network beyond loopback.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-ab1.XXXXXX")"; trap 'rm -rf "$W"' EXIT

# A minimal form backend: honeypot, size cap, per-process rate limit.
# MODE=norate drops the limit; MODE=paranoid refuses everything (the lead-dropping filter).
cat > "$W/app.py" <<'APP'
import os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs
MODE = os.environ.get("MODE", "ok")
HITS = []
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        if n > 1_000_000:
            self.send_response(413); self.end_headers(); return
        body = parse_qs(self.rfile.read(n).decode(errors="replace"))
        if MODE == "paranoid":
            self.send_response(400); self.end_headers(); return
        if body.get("website"):
            self.send_response(400); self.end_headers(); return
        now = time.time(); HITS[:] = [t for t in HITS if now - t < 1.0]; HITS.append(now)
        if MODE != "norate" and len(HITS) > 20:
            self.send_response(429); self.end_headers(); return
        self.send_response(302); self.send_header("Location", "/thanks"); self.end_headers()
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
APP

run_case() { # mode -> checker output
  local mode="$1"
  printf '{"start": "MODE=%s python3 app.py", "port": 8093, "endpoint": "/f/probe", "honeypot_field": "website", "burst": 40}\n' "$mode" > "$W/abuse-probe.json"
  python3 bin/check_abuse_controls.py "$W" 2>&1 || true
}

echo "== 1. a compliant endpoint passes all four checks"
out=$(run_case ok)
if [[ "$out" == *"ABUSE_CONTROLS_OK checkable:genuine-accepted checkable:honeypot-refused checkable:oversize-refused checkable:rate-limited"* ]]; then ok "genuine accepted, honeypot refused, oversize refused, burst rate-limited"; else bad "compliant endpoint did not pass: $out"; fi
if [ -z "$(lsof -ti tcp:8093 2>/dev/null || true)" ]; then ok "the gate killed the server it started"; else bad "server left running on 8093"; fi

echo "== 2. an endpoint that forgot rate limiting fails on exactly that"
out=$(run_case norate)
vline=$(printf '%s\n' "$out" | grep -E '^ABUSE_CONTROLS_VERIFIED' | head -1 || true)
if [[ "$vline" == *"genuine-accepted"* ]] && [[ "$vline" == *"honeypot-refused"* ]] && [[ "$vline" != *"rate-limited"* ]] && [[ "$out" == *"checkable:rate-limited: 40 rapid submissions drew no 429"* ]]; then ok "three met, rate-limited unmet and named"; else bad "wrong verdict for a missing rate limit: $out"; fi

echo "== 3. an endpoint that refuses genuine submissions fails on that first, however well it blocks bots"
out=$(run_case paranoid)
vline=$(printf '%s\n' "$out" | grep -E '^ABUSE_CONTROLS_VERIFIED' | head -1 || true)
if [[ "$vline" != *"genuine-accepted"* ]] && [[ "$out" == *"checkable:genuine-accepted: a plain well-formed submission got 400; a filter that drops a real lead has failed the product"* ]]; then ok "a lead-dropping filter is refused by name"; else bad "paranoid endpoint was not failed on the genuine case: $out"; fi

echo "== 4. no probe file: the gate says what the build node must declare"
rm -f "$W/abuse-probe.json"
out=$(python3 bin/check_abuse_controls.py "$W" 2>&1 || true)
if [[ "$out" == *"no abuse-probe.json in the workspace"* ]]; then ok "missing probe is a clear refusal, not a pass"; else bad "missing probe not refused: $out"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
