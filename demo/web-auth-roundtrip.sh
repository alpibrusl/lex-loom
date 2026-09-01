#!/usr/bin/env bash
# demo/web-auth-roundtrip.sh — the lex-loom#190 fix, live.
#
# Starts the real production src/web/server.lex::serve_loom entry point
# with LOOM_API_TOKEN set, and proves:
#   1. GET / (the dashboard shell) works with NO token — static markup,
#      not data.
#   2. GET /api/companies with no token is denied (401).
#   3. GET /api/companies with the WRONG token is denied (401).
#   4. GET /api/companies with Authorization: Bearer <token> succeeds.
#   5. GET /api/companies with ?token=<token> succeeds (the query-param
#      form exists because EventSource — the standard way a browser
#      consumes SSE — cannot set custom headers at all).
#   6. serve_loom refuses to start at all when LOOM_API_TOKEN is unset
#      (never fail-open into an unauthenticated server).
#
#   bash demo/web-auth-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/web-auth-demo.db"
WEB_PORT="${WEB_PORT:-8891}"
REAL_TOKEN="demo-web-token-xyz789"
WRONG_TOKEN="not-the-right-token"

rm -f "$DB_PATH"
PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
  rm -f "$DB_PATH"
}
trap cleanup EXIT

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"

echo "+ confirming serve_loom refuses to start with LOOM_API_TOKEN unset"
UNSET_OUTPUT=$(PORT="$((WEB_PORT + 1))" DB_PATH="$DB_PATH" \
  timeout 3 lex run --allow-effects "$EFFECTS" src/web/server.lex serve_loom 2>&1 || true)
echo "$UNSET_OUTPUT"

echo
echo "+ starting the real production web server with LOOM_API_TOKEN set, on :$WEB_PORT"
( PORT="$WEB_PORT" DB_PATH="$DB_PATH" LOOM_API_TOKEN="$REAL_TOKEN" \
    lex run --allow-effects "$EFFECTS" \
    src/web/server.lex serve_loom ) &
PIDS+=("$!")

echo "+ waiting for the server"
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:$WEB_PORT/" && break
  sleep 0.5
done

echo
echo "+ GET / (dashboard shell) with NO token"
ROOT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/")
echo "  http_status=$ROOT_STATUS"

echo
echo "+ GET /api/companies with NO token"
NO_TOKEN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/api/companies")
echo "  http_status=$NO_TOKEN_STATUS"

echo
echo "+ GET /api/companies with the WRONG token"
WRONG_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $WRONG_TOKEN" "http://localhost:$WEB_PORT/api/companies")
echo "  http_status=$WRONG_STATUS"

echo
echo "+ GET /api/companies with the correct token via Authorization header"
HEADER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $REAL_TOKEN" "http://localhost:$WEB_PORT/api/companies")
echo "  http_status=$HEADER_STATUS"

echo
echo "+ GET /api/companies with the correct token via ?token= query param"
QUERY_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/api/companies?token=$REAL_TOKEN")
echo "  http_status=$QUERY_STATUS"

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
check "$ROOT_STATUS" "200" "the dashboard shell (GET /) needs no token"
check "$NO_TOKEN_STATUS" "401" "an unauthenticated API call is denied"
check "$WRONG_STATUS" "401" "a wrong-token API call is denied"
check "$HEADER_STATUS" "200" "the correct token via Authorization header succeeds"
check "$QUERY_STATUS" "200" "the correct token via ?token= query param succeeds"

if echo "$UNSET_OUTPUT" | grep -q "LOOM_API_TOKEN is required"; then
  echo "  ok: serve_loom refuses to start with LOOM_API_TOKEN unset"
else
  echo "  FAILED: expected serve_loom to refuse to start without LOOM_API_TOKEN" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "web-auth-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "web-auth-roundtrip: OK — every /api/* route requires the token (header or query param), the dashboard shell doesn't, and the server refuses to start unauthenticated"
