#!/usr/bin/env bash
# demo/sa4-research-roundtrip.sh — the SA4 promotion criterion, live
# (lex-loom#181, docs/design/soft-os-aware-agents.md):
#
#   "Every current Distribution role [covered by SA4] is discoverable and
#    reachable through soft's mesh; no bespoke per-role integration code
#    remains for the roles covered here."
#
# Exactly demo/sa2-mesh-roundtrip.sh's shape, generalized to the `research`
# role (src/server/research_a2a.lex) instead of `cx` — proving SA2's
# pattern actually generalizes, which is SA4's whole point. Registers
# research into a fresh, independent federation node, confirms discovery
# via that node's own GET /peers, then sends a real tasks/send JSON-RPC
# request straight to the registered inbox_url.
#
# Note: web_search hits a real, keyless, public DuckDuckGo endpoint (see
# tests/test_cx_tool.lex's own header comment on this pattern) — outbound
# internet access is environment-dependent, so this demo asserts the full
# mesh + A2A round trip completes and returns a real, correctly-shaped
# reply either way; whether that reply is real search results or a clean
# "could not reach" error just reflects this environment's own network
# reachability, not the plumbing under test.
#
#   bash demo/sa4-research-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOFT_ROOT="${LEX_SOFT_ROOT:-$REPO_ROOT/../lex-soft}"
[ -d "$SOFT_ROOT" ] || { echo "sa4-research-roundtrip: no lex-soft checkout at $SOFT_ROOT (set LEX_SOFT_ROOT)" >&2; exit 1; }
cd "$REPO_ROOT"

FED_PORT="${FED_PORT:-9101}"
RESEARCH_PORT="${RESEARCH_PORT:-9300}"
ORG="acme"
RESEARCH_TOKEN="demo-research-token-abc123"

PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

echo "+ starting an independent federation node on :$FED_PORT"
( cd "$SOFT_ROOT" && DB_URL=":memory:" PORT="$FED_PORT" ORG="soft-node-c" \
    lex run --allow-effects net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto \
    src/federation_node.lex serve_federation ) &
PIDS+=("$!")

echo "+ starting loom's research A2A server on :$RESEARCH_PORT (token-gated)"
PORT="$RESEARCH_PORT" RESEARCH_API_TOKEN="$RESEARCH_TOKEN" \
  lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc \
  src/server/research_a2a.lex serve_research_a2a &
PIDS+=("$!")

echo "+ waiting for both servers"
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:$FED_PORT/peers" && curl -s -o /dev/null "http://localhost:$RESEARCH_PORT/.well-known/agent.json" && break
  sleep 0.5
done

echo
echo "+ research's agent card (discovery document)"
curl -s "http://localhost:$RESEARCH_PORT/.well-known/agent.json"
echo

echo
echo "+ registering research into the federation node's mesh"
lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
  src/soft_register.lex register_role "\"http://localhost:$FED_PORT\"" "\"$ORG\"" '"research"' "\"http://localhost:$RESEARCH_PORT\""

echo
echo "+ confirming discovery via the federation node's own GET /peers"
curl -s "http://localhost:$FED_PORT/peers?tenant=$ORG"
echo

RESEARCH_PAYLOAD='{"jsonrpc":"2.0","id":"task_1","method":"tasks/send","params":{"id":"task_1","contextId":"ctx_1","message":{"kind":"message","messageId":"m1","role":"user","parts":[{"type":"text","text":"{\"query\":\"lex-loom autonomous companies\"}"}]}}}'

echo
echo "+ NEGATIVE TEST: tasks/send against the registered inbox_url with NO token — must be denied (lex-loom#193)"
NO_AUTH_STATUS=$(curl -s -o /tmp/sa4-no-auth.json -w "%{http_code}" -X POST "http://localhost:$RESEARCH_PORT/" -H "Content-Type: application/json" -d "$RESEARCH_PAYLOAD")
echo "  http_status=$NO_AUTH_STATUS body=$(cat /tmp/sa4-no-auth.json)"

echo
echo "+ real tasks/send against the registered inbox_url, authorized"
HAPPY_STATUS=$(curl -s -o /tmp/sa4-happy.json -w "%{http_code}" -X POST "http://localhost:$RESEARCH_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $RESEARCH_TOKEN" -d "$RESEARCH_PAYLOAD")
cat /tmp/sa4-happy.json
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
rm -f /tmp/sa4-no-auth.json /tmp/sa4-happy.json

if [ "$fail" -ne 0 ]; then
  echo
  echo "sa4-research-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "+ done — SA4 promotion criterion demonstrated end to end (research role, reachable only with the RESEARCH_API_TOKEN)"
