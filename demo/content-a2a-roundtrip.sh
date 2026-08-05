#!/usr/bin/env bash
# demo/content-a2a-roundtrip.sh — the lex-loom#187 promotion criterion, live
# (docs/design/soft-os-aware-agents.md):
#
#   "content_creator registers into soft's mesh and is reachable over A2A
#    the same way cx/research are, AND a mesh peer without the
#    authorization this issue adds cannot trigger publish_content
#    end-to-end (a real negative test, not just an assertion)."
#
# Mirrors demo/sa2-mesh-roundtrip.sh's shape exactly (independent
# federation node + a fake product server + loom's own A2A server), with
# one addition: content_a2a.lex's server requires CONTENT_PUBLISH_TOKEN
# and gates every POST / behind Authorization: Bearer <token>. This proves
# BOTH directions —
#   1. the happy path: registered + discoverable + a correctly-authorized
#      tasks/send reaches the real publish_content_core and actually POSTs
#      to the fake product server (its hit counter goes to 1)
#   2. the negative test: no token, and a WRONG token, both get a real
#      401 from the A2A server itself, and the fake product server's hit
#      counter stays at 0 for both — the write never happened.
#
# Assumes a sibling `../lex-soft` checkout. Needs the `lex` CLI on PATH.
#
#   bash demo/content-a2a-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOFT_ROOT="${LEX_SOFT_ROOT:-$REPO_ROOT/../lex-soft}"
[ -d "$SOFT_ROOT" ] || { echo "content-a2a-roundtrip: no lex-soft checkout at $SOFT_ROOT (set LEX_SOFT_ROOT)" >&2; exit 1; }

FED_PORT="${FED_PORT:-9101}"
CONTENT_PORT="${CONTENT_PORT:-9301}"
PRODUCT_PORT="${PRODUCT_PORT:-8082}"
ORG="acme"
REAL_TOKEN="demo-secret-token-abc123"
WRONG_TOKEN="not-the-right-token"

PIDS=()
HITS_FILE=$(mktemp)
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
  rm -f "$HITS_FILE"
}
trap cleanup EXIT
echo 0 > "$HITS_FILE"

echo "+ starting an independent federation node on :$FED_PORT"
( cd "$SOFT_ROOT" && DB_URL=":memory:" PORT="$FED_PORT" ORG="soft-node-c" \
    lex run --allow-effects net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto \
    src/federation_node.lex serve_federation ) &
PIDS+=("$!")

echo "+ starting a fake product /loom/content server on :$PRODUCT_PORT (counts real hits)"
python3 - "$PRODUCT_PORT" "$HITS_FILE" <<'PY' &
import http.server, json, sys
port = int(sys.argv[1])
hits_file = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/loom/content":
            n = int(open(hits_file).read().strip() or "0") + 1
            open(hits_file, "w").write(str(n))
            body = json.dumps({"ok": True, "post_count": n}).encode()
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

echo "+ starting loom's content_creator A2A server on :$CONTENT_PORT (token-gated)"
( cd "$REPO_ROOT" && PORT="$CONTENT_PORT" CONTENT_PUBLISH_TOKEN="$REAL_TOKEN" \
    lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc \
    src/server/content_a2a.lex serve_content_a2a ) &
PIDS+=("$!")

echo "+ waiting for all three servers"
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:$FED_PORT/peers" && curl -s -o /dev/null "http://localhost:$CONTENT_PORT/.well-known/agent.json" && break
  sleep 0.5
done

echo
echo "+ content_creator's agent card (discovery document, unauthenticated — that's fine, it's public metadata)"
curl -s "http://localhost:$CONTENT_PORT/.well-known/agent.json"
echo

echo
echo "+ registering content_creator into the federation node's mesh"
( cd "$REPO_ROOT" && lex run \
    --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
    src/soft_register.lex register_role "\"http://localhost:$FED_PORT\"" "\"$ORG\"" '"content_creator"' "\"http://localhost:$CONTENT_PORT\"" )

echo
echo "+ confirming discovery via the federation node's own GET /peers"
curl -s "http://localhost:$FED_PORT/peers?tenant=$ORG"
echo

PAYLOAD="{\"jsonrpc\":\"2.0\",\"id\":\"task_1\",\"method\":\"tasks/send\",\"params\":{\"id\":\"task_1\",\"contextId\":\"ctx_1\",\"message\":{\"kind\":\"message\",\"messageId\":\"m1\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"{\\\"url\\\":\\\"http://127.0.0.1:$PRODUCT_PORT\\\",\\\"title\\\":\\\"Demo post\\\",\\\"body\\\":\\\"hello from the mesh\\\"}\"}]}}}"

echo
echo "+ NEGATIVE TEST 1: tasks/send with NO Authorization header"
NO_AUTH_STATUS=$(curl -s -o /tmp/content-a2a-no-auth.json -w "%{http_code}" -X POST "http://localhost:$CONTENT_PORT/" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "  http_status=$NO_AUTH_STATUS body=$(cat /tmp/content-a2a-no-auth.json)"

echo
echo "+ NEGATIVE TEST 2: tasks/send with the WRONG token"
WRONG_AUTH_STATUS=$(curl -s -o /tmp/content-a2a-wrong-auth.json -w "%{http_code}" -X POST "http://localhost:$CONTENT_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $WRONG_TOKEN" -d "$PAYLOAD")
echo "  http_status=$WRONG_AUTH_STATUS body=$(cat /tmp/content-a2a-wrong-auth.json)"

echo
echo "+ checking the fake product server: should have ZERO hits so far (both attempts above were denied before dispatch)"
HITS_AFTER_NEGATIVE=$(cat "$HITS_FILE")
echo "  product server hit count: $HITS_AFTER_NEGATIVE"

echo
echo "+ POSITIVE TEST: tasks/send with the CORRECT token"
OK_STATUS=$(curl -s -o /tmp/content-a2a-ok.json -w "%{http_code}" -X POST "http://localhost:$CONTENT_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $REAL_TOKEN" -d "$PAYLOAD")
echo "  http_status=$OK_STATUS body=$(cat /tmp/content-a2a-ok.json)"

echo
echo "+ checking the fake product server: should now have exactly ONE hit"
HITS_AFTER_POSITIVE=$(cat "$HITS_FILE")
echo "  product server hit count: $HITS_AFTER_POSITIVE"

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
check "$NO_AUTH_STATUS" "401" "no-Authorization-header request is denied with 401"
check "$WRONG_AUTH_STATUS" "401" "wrong-token request is denied with 401"
check "$HITS_AFTER_NEGATIVE" "0" "the product server was never reached by either denied attempt"
check "$OK_STATUS" "200" "correctly-authorized request succeeds with 200"
check "$HITS_AFTER_POSITIVE" "1" "the product server was reached exactly once, by the authorized attempt"

rm -f /tmp/content-a2a-no-auth.json /tmp/content-a2a-wrong-auth.json /tmp/content-a2a-ok.json

if [ "$fail" -ne 0 ]; then
  echo
  echo "content-a2a-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "content-a2a-roundtrip: OK — registered + discoverable + reachable like cx/research, and a mesh peer without the token cannot trigger publish_content"
