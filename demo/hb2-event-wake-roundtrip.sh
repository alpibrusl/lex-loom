#!/usr/bin/env bash
# hb2-event-wake-roundtrip.sh — live proof of HB2 event-driven wakes (#214),
# with NO LLM provider and no external network (the only sockets are the
# demo's own localhost servers):
#
#   1. dormancy       — three Maintenance companies with event-kind wake_when
#                       are classified dormant; nothing runs.
#   2. board-note wake — the REAL scheduler runs with TICK_MS=60s but
#                       EVENT_POLL_MS=300ms; a board note posted through the
#                       real CLI wakes the dormant company within seconds,
#                       bypassing the periodic tick.
#   3. CX opt-in      — an inbound support item flows through the REAL cx_a2a
#                       A2A server into the opted-in company's event ledger;
#                       a company that did NOT declare support_item gets the
#                       same event via the web server's generic webhook and
#                       STAYS dormant. Unknown kinds are refused (400).
#   4. replay         — the events table replays as the wake history:
#                       consumed events name the run that absorbed them;
#                       the never-woken company's event stays PENDING forever.
#
# Run from the repo root:  bash demo/hb2-event-wake-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-hb2-demo.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  pkill -f "http.server $SUPPORT_PORT" 2>/dev/null || true
  pkill -f serve_cx_a2a 2>/dev/null || true
  rm -rf "$WS"
}
trap cleanup EXIT
mkdir -p "$WS/wakeco" "$WS/cxin" "$WS/cxout"

CX_PORT=8461
SUPPORT_PORT=8462
WEB_PORT=8463
API_TOKEN="hb2-demo-token"
CX_TOKEN="hb2-cx-token"

pass=0
fail=0
say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "   OK: $*"; pass=$((pass+1)); }
bad()  { echo "   FAIL: $*"; fail=$((fail+1)); }
q() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2" 2>/dev/null || echo ""; }

say "seed: three dormant companies (different wake_when opt-ins)"
DB_PATH="$WS/wakeco/company.db" COMPANY_ID=wakeco WAKE_WHEN="board_note or support_item" \
  lex run --allow-effects "$EFFECTS" demo/hb2_seed.lex seed_dormant_cmd
DB_PATH="$WS/cxin/company.db" COMPANY_ID=cxin WAKE_WHEN="support_item" \
  lex run --allow-effects "$EFFECTS" demo/hb2_seed.lex seed_dormant_cmd
DB_PATH="$WS/cxout/company.db" COMPANY_ID=cxout WAKE_WHEN="verdict-failed" \
  lex run --allow-effects "$EFFECTS" demo/hb2_seed.lex seed_dormant_cmd

say "1. one tick: all three are dormant, nothing runs"
T1="$(LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 EVENT_POLL_MS=0 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline bash bin/loom-scheduler.sh 2>&1)"
echo "$T1" | grep -q "skip wakeco (dormant)" && ok "wakeco dormant" || bad "wakeco not dormant"
echo "$T1" | grep -q "skip cxin (dormant)"   && ok "cxin dormant"   || bad "cxin not dormant"
echo "$T1" | grep -q "skip cxout (dormant)"  && ok "cxout dormant"  || bad "cxout not dormant"
echo "$T1" | grep -q "0 run(s) started"      && ok "no runs started" || bad "a run started"

say "2. board-note wake within seconds (TICK_MS=60s, EVENT_POLL_MS=300ms)"
SCHED_LOG="$WS/sched.log"
( LOOM_WORKSPACE="$WS" MAX_TICKS=2 TICK_MS=60000 EVENT_POLL_MS=300 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline \
    bash bin/loom-scheduler.sh >"$SCHED_LOG" 2>&1 ) &
PIDS+=("$!")
for i in $(seq 1 120); do grep -q "tick 1 done" "$SCHED_LOG" 2>/dev/null && break; sleep 0.5; done
grep -q "tick 1 done" "$SCHED_LOG" && ok "scheduler up; tick 1 saw everyone dormant" || bad "scheduler never finished tick 1"

echo "   + posting a board note through the real CLI (main.lex board_note_cmd)"
NOTE_AT=$(date +%s)
DB_PATH="$WS/wakeco/company.db" COMPANY_ID=wakeco NOTE="board: investigate churn now" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex board_note_cmd >/dev/null

for i in $(seq 1 120); do grep -q "RUN wakeco (event_wake)" "$SCHED_LOG" 2>/dev/null && break; sleep 0.5; done
WOKE_AT=$(date +%s)
ELAPSED=$((WOKE_AT - NOTE_AT))
grep -q "EVENT WAKE" "$SCHED_LOG" && ok "event poll cut the 60s tick sleep short" || bad "no early wake in the log"
grep -q "RUN wakeco (event_wake)" "$SCHED_LOG" && ok "wakeco woken by the board-note event (reason: event_wake)" || bad "wakeco not woken"
[ "$ELAPSED" -le 20 ] && ok "wake happened ${ELAPSED}s after the note — seconds, not the 60s tick" || bad "wake took ${ELAPSED}s"
# The consumption line is printed once the woken run absorbs its events —
# moments AFTER the "RUN wakeco" line the loop above waited for. Poll for
# it (found flaky on CI runners); section 4 independently proves the
# consumption in the DB and on the trail.
for i in $(seq 1 60); do grep -q "event(s) consumed by this run" "$SCHED_LOG" 2>/dev/null && break; sleep 0.5; done
grep -q "event(s) consumed by this run" "$SCHED_LOG" && ok "the run consumed the pending event(s)" || bad "no consumption logged"
for i in $(seq 1 120); do grep -q "MAX_TICKS reached" "$SCHED_LOG" 2>/dev/null && break; sleep 0.5; done

say "3a. CX opt-in: a support item arrives through the REAL cx_a2a A2A server"
mkdir -p "$WS/product/loom"
printf '{"items":[{"id":"t-101","text":"my export is broken","status":"open"}]}' > "$WS/product/loom/support"
( cd "$WS/product" && exec python3 -m http.server "$SUPPORT_PORT" >/dev/null 2>&1 ) &
PIDS+=("$!")
( CX_API_TOKEN="$CX_TOKEN" PORT="$CX_PORT" CX_ALLOWED_URL="http://localhost:$SUPPORT_PORT" \
    LOOM_EVENTS_DB="$WS/cxin/company.db" LOOM_EVENTS_COMPANY=cxin \
    exec lex run --max-steps 0 --allow-effects "$EFFECTS" \
    src/server/cx_a2a.lex serve_cx_a2a >/dev/null 2>&1 ) &
PIDS+=("$!")
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$CX_PORT/.well-known/agent.json" && break; sleep 0.5; done
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$SUPPORT_PORT/loom/support" && break; sleep 0.5; done
CX_PAYLOAD='{"jsonrpc":"2.0","id":"task_1","method":"tasks/send","params":{"id":"task_1","contextId":"ctx_1","message":{"kind":"message","messageId":"m1","role":"user","parts":[{"type":"text","text":"{\"url\":\"http://localhost:'"$SUPPORT_PORT"'\"}"}]}}}'
CX_OUT="$(curl -s -X POST "http://localhost:$CX_PORT/" -H "Content-Type: application/json" -H "Authorization: Bearer $CX_TOKEN" -d "$CX_PAYLOAD")"
echo "$CX_OUT" | grep -q "t-101" && ok "cx_a2a fetched the open support item" || bad "cx_a2a fetch failed: $CX_OUT"
EV_KIND="$(q "$WS/cxin/company.db" "SELECT kind FROM company_events WHERE company_id='cxin' AND id='ev-support-cxin-t-101'")"
[ "$EV_KIND" = "support_item" ] && ok "support_item event in cxin's ledger (deduped id)" || bad "no support_item event for cxin"
EV_BODY="$(q "$WS/cxin/company.db" "SELECT body_json FROM company_events WHERE id='ev-support-cxin-t-101'")"
echo "$EV_BODY" | grep -q "broken" && bad "customer text leaked into the ledger" || ok "event stores the item id, never the customer's words"

say "3b. the NOT-opted-in company gets the same event via the generic webhook"
( PORT="$WEB_PORT" DB_PATH="$WS/cxout/company.db" LOOM_API_TOKEN="$API_TOKEN" \
    exec lex run --allow-effects "$EFFECTS" src/web/server.lex serve_loom >/dev/null 2>&1 ) &
PIDS+=("$!")
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$WEB_PORT/" && break; sleep 0.5; done
WH="$(curl -s -X POST "http://localhost:$WEB_PORT/api/events/cxout?token=$API_TOKEN" -d '{"kind":"support_item","source":"cx_a2a","ref":"t-102"}')"
echo "$WH" | grep -q '"kind":"support_item"' && ok "webhook accepted a known kind for cxout" || bad "webhook failed: $WH"
BADKIND="$(curl -s -X POST "http://localhost:$WEB_PORT/api/events/cxout?token=$API_TOKEN" -d '{"kind":"rm_rf_slash"}')"
echo "$BADKIND" | grep -q "unknown event kind" && ok "unknown kind refused, never stored" || bad "unknown kind accepted: $BADKIND"

say "3c. one tick: cxin (opted in) wakes; cxout (not opted in) stays dormant"
T3="$(LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 EVENT_POLL_MS=0 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline bash bin/loom-scheduler.sh 2>&1)"
echo "$T3" | grep -q "RUN cxin (event_wake)"  && ok "cxin woken by the inbound support item" || bad "cxin not woken"
echo "$T3" | grep -q "skip cxout (dormant)"   && ok "cxout has the event but never opted in — still dormant" || bad "cxout did not stay dormant"

say "4. replay: the events table IS the wake history"
WAKE_HIST="$(DB_PATH="$WS/wakeco/company.db" COMPANY_ID=wakeco \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex events_cmd 2>&1)"
echo "$WAKE_HIST" | grep -q "board_note (board) ev-note-wakeco-1 — consumed by scheduler:event_wake:iter-2" \
  && ok "wakeco's ledger names the exact run that absorbed the note" || bad "wakeco history wrong: $WAKE_HIST"
ITER2="$(q "$WS/wakeco/company.db" "SELECT count(*) FROM company_iterations WHERE company_id='wakeco' AND idx=2")"
[ "$ITER2" = "1" ] && ok "the wake genuinely started iteration 2" || bad "no iteration 2 recorded"
CONSUMED="$(q "$WS/cxin/company.db" "SELECT consumed_by FROM company_events WHERE id='ev-support-cxin-t-101'")"
echo "$CONSUMED" | grep -q "event_wake" && ok "cxin's support event consumed by its wake" || bad "cxin event not consumed: '$CONSUMED'"
PENDING="$(q "$WS/cxout/company.db" "SELECT count(*) FROM company_events WHERE company_id='cxout' AND consumed_at=''")"
[ "$PENDING" = "1" ] && ok "cxout's event stays PENDING forever — recorded, never woke anything" || bad "cxout pending count: $PENDING"
TRAIL="$(q "$WS/wakeco/company.db" "SELECT count(*) FROM traces WHERE agent_id='wakeco' AND event_kind='events_consumed'")"
[ "${TRAIL:-0}" -ge 1 ] && ok "consumption is trail-recorded (events_consumed)" || bad "no events_consumed trail event"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
