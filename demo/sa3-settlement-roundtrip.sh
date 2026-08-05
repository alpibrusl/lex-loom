#!/usr/bin/env bash
# demo/sa3-settlement-roundtrip.sh — the SA3 promotion criterion, live
# (lex-loom#180, docs/design/soft-os-aware-agents.md):
#
#   "A settlement event soft produced is the one board_report cites, and
#    it survives an independent re-verification (soft's own evidence
#    re-derivation)."
#
# Stands up a tiny fake revenue endpoint, seeds a company with
# [soft].settlement on, runs the real check_and_record_revenue path against
# it (REVENUE_URL -> fetch -> record + verify through soft's settlement/
# verdict machinery -> store), shows the settlement citation in a real
# board_report, then independently re-verifies the recorded trail_id from a
# freshly opened handle — and, to prove re-verification is a real check and
# not just an echo, tampers with the underlying event afterward and shows
# the SAME re-derivation now correctly fails.
#
#   bash demo/sa3-settlement-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/sa3-settlement-demo.db"
COMPANY_ID="sa3-demo"
REVENUE_PORT="${REVENUE_PORT:-8090}"

rm -f "$DB_PATH"

PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
  rm -f "$DB_PATH"
}
trap cleanup EXIT

echo "+ starting a fake revenue endpoint on :$REVENUE_PORT"
python3 - "$REVENUE_PORT" <<'PY' &
import http.server, json, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"revenue_cents": 340000}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
PIDS+=("$!")
for i in $(seq 1 20); do
  curl -s -o /dev/null "http://127.0.0.1:$REVENUE_PORT" && break
  sleep 0.3
done

echo
echo "+ seeding a company with [soft].settlement on"
DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex seed_company_cmd

echo
echo "+ checking revenue — real check_and_record_revenue, routed through soft_settlement"
DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" REVENUE_URL="http://127.0.0.1:$REVENUE_PORT" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex check_revenue_cmd

echo
echo "+ board_report — the settlement event should be cited (trail_id + verified)"
REPORT=$(DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex report_cmd)
echo "$REPORT"

TRAIL_ID=$(echo "$REPORT" | grep -oE 'trail_id=[a-f0-9]+' | head -1 | cut -d= -f2)
if [ -z "$TRAIL_ID" ]; then
  echo "sa3-settlement-roundtrip: no trail_id found in board_report — FAILED" >&2
  exit 1
fi
echo
echo "+ extracted trail_id=$TRAIL_ID"

echo
echo "+ independent re-verification (fresh handle, honest trail) — should verify"
DB_PATH="$DB_PATH" TRAIL_ID="$TRAIL_ID" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex reverify_cmd

echo
echo "+ tampering with the recorded event, then re-verifying again — should now FAIL"
DB_PATH="$DB_PATH" TRAIL_ID="$TRAIL_ID" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex tamper_cmd
DB_PATH="$DB_PATH" TRAIL_ID="$TRAIL_ID" \
  lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  demo/sa3_settlement.lex reverify_cmd

echo
echo "+ done — SA3 promotion criterion demonstrated end to end"
