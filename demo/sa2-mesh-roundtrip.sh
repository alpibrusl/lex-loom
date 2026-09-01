#!/usr/bin/env bash
# demo/sa2-mesh-roundtrip.sh — the SA2 promotion criterion, live
# (lex-loom#179, docs/design/soft-os-aware-agents.md):
#
#   "A second, independent soft node discovers and successfully
#    A2A-messages the registered role end to end."
#
# Stands up, in this order:
#   1. A fresh, independent lex-soft federation node (../lex-soft's new
#      src/federation_node.lex — nothing this repo operates day to day,
#      standing in for a mesh node run by someone else).
#   2. A tiny fake product server so CX has something real to fetch from
#      (mirrors what paths/python-flask's /loom/support route would return).
#   3. loom's own CX role, mounted as a real A2A server
#      (src/server/cx_a2a.lex).
# Then, against that live setup:
#   4. Registers CX into the federation node's mesh (src/soft_register.lex).
#   5. Confirms discovery via the federation node's own `GET /peers`.
#   6. Sends a real `tasks/send` JSON-RPC request straight to the
#      registered inbox_url and prints the real reply — both the happy
#      path (the in-scope product server) and the refusal path (an
#      out-of-scope url, lex-loom#194).
#
# Assumes a sibling `../lex-soft` checkout with this branch's
# src/federation_node.lex. Needs the `lex` CLI on PATH.
#
#   bash demo/sa2-mesh-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOFT_ROOT="${LEX_SOFT_ROOT:-$REPO_ROOT/../lex-soft}"
[ -d "$SOFT_ROOT" ] || { echo "sa2-mesh-roundtrip: no lex-soft checkout at $SOFT_ROOT (set LEX_SOFT_ROOT)" >&2; exit 1; }

FED_PORT="${FED_PORT:-9100}"
CX_PORT="${CX_PORT:-9200}"
SUPPORT_PORT="${SUPPORT_PORT:-8081}"
ORG="acme"
CX_TOKEN="demo-cx-token-abc123"

PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

echo "+ starting an independent federation node on :$FED_PORT"
( cd "$SOFT_ROOT" && DB_URL=":memory:" PORT="$FED_PORT" ORG="soft-node-b" \
    lex run --allow-effects net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto,approval,stream \
    src/federation_node.lex serve_federation ) &
PIDS+=("$!")

echo "+ starting a fake product /loom/support server on :$SUPPORT_PORT"
python3 - "$SUPPORT_PORT" <<'PY' &
import http.server, json, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/loom/support":
            body = json.dumps({"items": [{"id": "t-1", "text": "my order never arrived", "status": "open"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
PIDS+=("$!")

echo "+ starting loom's CX A2A server on :$CX_PORT (token-gated, URL-scoped to the product server — lex-loom#194)"
( cd "$REPO_ROOT" && PORT="$CX_PORT" CX_API_TOKEN="$CX_TOKEN" CX_ALLOWED_URL="http://127.0.0.1:$SUPPORT_PORT" \
    lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc,vcs,approval,stream \
    src/server/cx_a2a.lex serve_cx_a2a ) &
PIDS+=("$!")

echo "+ waiting for both servers"
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:$FED_PORT/peers" && curl -s -o /dev/null "http://localhost:$CX_PORT/.well-known/agent.json" && break
  sleep 0.5
done

echo
echo "+ CX's agent card (discovery document)"
curl -s "http://localhost:$CX_PORT/.well-known/agent.json"
echo

echo
echo "+ registering CX into the federation node's mesh"
( cd "$REPO_ROOT" && lex run \
    --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream \
    src/soft_register.lex register_role "\"http://localhost:$FED_PORT\"" "\"$ORG\"" '"cx"' "\"http://localhost:$CX_PORT\"" )

echo
echo "+ confirming discovery via the federation node's own GET /peers"
curl -s "http://localhost:$FED_PORT/peers?tenant=$ORG"
echo

HAPPY_PAYLOAD="{\"jsonrpc\":\"2.0\",\"id\":\"task_1\",\"method\":\"tasks/send\",\"params\":{\"id\":\"task_1\",\"contextId\":\"ctx_1\",\"message\":{\"kind\":\"message\",\"messageId\":\"m1\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"{\\\"url\\\":\\\"http://127.0.0.1:$SUPPORT_PORT\\\"}\"}]}}}"

echo
echo "+ NEGATIVE TEST: tasks/send against the registered inbox_url with NO token — must be denied (lex-loom#193)"
NO_AUTH_STATUS=$(curl -s -o /tmp/sa2-no-auth.json -w "%{http_code}" -X POST "http://localhost:$CX_PORT/" -H "Content-Type: application/json" -d "$HAPPY_PAYLOAD")
echo "  http_status=$NO_AUTH_STATUS body=$(cat /tmp/sa2-no-auth.json)"

echo
echo "+ real tasks/send against the registered inbox_url, authorized (happy path)"
HAPPY_STATUS=$(curl -s -o /tmp/sa2-happy.json -w "%{http_code}" -X POST "http://localhost:$CX_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $CX_TOKEN" -d "$HAPPY_PAYLOAD")
cat /tmp/sa2-happy.json
echo

echo
echo "+ real tasks/send against the registered inbox_url, authorized, but asking for an OUT-OF-SCOPE url — must be refused (lex-loom#194)"
curl -s -X POST "http://localhost:$CX_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $CX_TOKEN" -d '{"jsonrpc":"2.0","id":"task_2","method":"tasks/send","params":{"id":"task_2","contextId":"ctx_2","message":{"kind":"message","messageId":"m2","role":"user","parts":[{"type":"text","text":"{\"url\":\"http://127.0.0.1:1\"}"}]}}}'
echo

echo
echo "+ checking everything against expectations"
fail=0
check() {
  if [ "$1" = "$2" ]; then
    echo "  ok: $3"
  else
    echo "  FAILED: expected $3 to be '$2', got '$1'" >&2
    fail=1
  fi
}
check "$NO_AUTH_STATUS" "401" "an unauthenticated tasks/send is denied with 401"
check "$HAPPY_STATUS" "200" "an authorized tasks/send succeeds"
rm -f /tmp/sa2-no-auth.json /tmp/sa2-happy.json

if [ "$fail" -ne 0 ]; then
  echo
  echo "sa2-mesh-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "+ done — SA2 promotion criterion demonstrated end to end (registered, discoverable, reachable only with the CX_API_TOKEN)"
