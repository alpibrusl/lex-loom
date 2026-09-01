#!/usr/bin/env bash
# demo/agui-replay-roundtrip.sh — AG-UI replay, live.
#
# This is a "replay burst" feature, not genuine mid-generation streaming
# — see src/agui_store.lex's header comment for the real blocker (it's
# upstream, in lex-llm's eager per-round drain, not fixable from
# lex-loom alone). What IS proven live here: a node's finished LLM turn,
# persisted via the exact real src/agui_store.lex::persist_agui_events
# function runner.lex's LLM branch calls, replayed as a real SSE stream
# by the exact real production src/web/server.lex::serve_loom entry
# point (not a reimplementation) — RUN_STARTED, TEXT_MESSAGE_START/
# CONTENT/END, RUN_FINISHED, each its own SSE data: frame — plus the
# clean "no events yet" response for a sprint nothing has been recorded
# for.
#
#   bash demo/agui-replay-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/agui-replay-demo.db"
WEB_PORT="${WEB_PORT:-8890}"
SPRINT_ID="agui-demo/iter-1"
RUN_ID="run-demo-1"
TEXT="here is the artifact this node produced"
API_TOKEN="demo-agui-token-abc123"

rm -f "$DB_PATH"
PIDS=()
cleanup() {
  [ "${#PIDS[@]}" -eq 0 ] || kill "${PIDS[@]}" 2>/dev/null || true
  rm -f "$DB_PATH"
}
trap cleanup EXIT

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"

echo "+ seeding a real AG-UI replay row via agui_store.persist_agui_events (the exact function runner.lex's LLM branch calls)"
DB_PATH="$DB_PATH" SPRINT_ID="$SPRINT_ID" RUN_ID="$RUN_ID" AGENT_ID="loom-build" TEXT="$TEXT" \
  lex run --allow-effects "$EFFECTS" \
  demo/agui_seed.lex seed_cmd

echo
echo "+ starting the real production web server (src/web/server.lex serve_loom) on :$WEB_PORT"
( PORT="$WEB_PORT" DB_PATH="$DB_PATH" LOOM_API_TOKEN="$API_TOKEN" \
    lex run --allow-effects "$EFFECTS" \
    src/web/server.lex serve_loom ) &
PIDS+=("$!")

echo "+ waiting for the server"
for i in $(seq 1 30); do
  curl -s -o /dev/null "http://localhost:$WEB_PORT/"  && break
  sleep 0.5
done

echo
echo "+ GET /api/sprint-agui/<sprint_id>?token=... — should replay the recorded turn as real SSE frames"
echo "  (query-param token, not a header: EventSource -- the standard way a browser consumes SSE -- can't set headers, lex-loom#190)"
REPLAY_HEADERS=$(mktemp)
REPLAY=$(curl -s -D "$REPLAY_HEADERS" "http://localhost:$WEB_PORT/api/sprint-agui/$SPRINT_ID?token=$API_TOKEN")
REPLAY_CONTENT_TYPE=$(grep -i "^content-type:" "$REPLAY_HEADERS" | tr -d '\r' | cut -d' ' -f2)
rm -f "$REPLAY_HEADERS"
echo "$REPLAY"
echo "  content_type=$REPLAY_CONTENT_TYPE"

echo
echo "+ GET /api/sprint-agui/<unknown>?token=... — should cleanly report no events, not error out"
UNKNOWN=$(curl -s "http://localhost:$WEB_PORT/api/sprint-agui/no-such-sprint?token=$API_TOKEN")
echo "$UNKNOWN"

echo
echo "+ checking everything against expectations"
fail=0
check() {
  if echo "$1" | grep -qE "$2"; then
    echo "  ok: $3"
  else
    echo "  FAILED: expected to find '$2' — $3" >&2
    fail=1
  fi
}
check "$REPLAY" "RUN_STARTED"                       "replay includes RUN_STARTED"
check "$REPLAY" "TEXT_MESSAGE_START"                "replay includes TEXT_MESSAGE_START"
check "$REPLAY" "TEXT_MESSAGE_CONTENT"               "replay includes TEXT_MESSAGE_CONTENT"
check "$REPLAY" "$TEXT"                              "replay carries the real text content"
check "$REPLAY" "TEXT_MESSAGE_END"                   "replay includes TEXT_MESSAGE_END"
check "$REPLAY" "RUN_FINISHED"                       "replay includes RUN_FINISHED"
check "$REPLAY_CONTENT_TYPE" "text/event-stream"     "replay is served as a real SSE stream"
check "$UNKNOWN" "no agui events recorded yet"        "an unrecorded sprint gets a clean, non-error response"

if [ "$fail" -ne 0 ]; then
  echo
  echo "agui-replay-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "agui-replay-roundtrip: OK — a real finished node turn replays as a real AG-UI SSE stream through the real production web server"
