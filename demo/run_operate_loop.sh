#!/usr/bin/env bash
# demo/run_operate_loop.sh — Operate loop v1 end-to-end demo (#118).
#
# Proves CTL3-CTL5 (sensing -> diagnosis -> contract proposal ->
# verification, #128-131, wired together in #145) against a REAL toy HTTP
# server instead of fabricated test fixtures:
#
#   - a real curl connection failure (the server process is actually killed)
#     opens a real server_down incident
#   - a real measured latency spike (the server actually sleeps before
#     responding) opens a real degraded_latency incident
#   - the toy server recovers in both cases, so by the time each proposed
#     effect contract's deadline arrives, `verify_pending` should find the
#     signal it predicted actually recovered — MATERIALISED, not falsified
#
# No LLM, no API key, no Docker: sensing/diagnosis/effects are pure Lex+SQL.
#
# Run from the lex-loom project root:
#   ./demo/run_operate_loop.sh

set -euo pipefail

LOOM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_DIR="$LOOM_ROOT/demo"
DB="${DEMO_DB:-$DEMO_DIR/operate-loop-demo.db}"
LEX="${LEX_BIN:-lex}"
COMPANY_ID="${COMPANY_ID:-operate-demo-$$}"
PORT="${PORT:-8999}"
MODE_FILE="$DEMO_DIR/.toy-mode-$$.txt"
TARGET_URL="http://127.0.0.1:$PORT"

# lex run's effect check validates a file's whole transitive effect
# surface, not just the call path reachable from the invoked function —
# so every command below grants the full set `lex check --strict` reports
# for its file, matching the convention already used in bin/*.sh.
DEMO_FILE_EFFECTS=concurrent,crypto,env,fs_read,fs_write,io,net,proc,random,sql,time
MAIN_FILE_EFFECTS=env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs

TOY_PID=""

start_server() {
  echo up > "$MODE_FILE"
  python3 "$DEMO_DIR/toy_target.py" "$MODE_FILE" "$PORT" &
  TOY_PID=$!
  sleep 0.3
}

stop_server() {
  if [ -n "$TOY_PID" ] && kill -0 "$TOY_PID" 2>/dev/null; then
    kill "$TOY_PID" 2>/dev/null || true
    wait "$TOY_PID" 2>/dev/null || true
  fi
  TOY_PID=""
}

cleanup() {
  stop_server
  rm -f "$MODE_FILE"
}
trap cleanup EXIT

set_mode() {
  echo "$1" > "$MODE_FILE"
}

round() {
  local idx="$1"
  DB_PATH="$DB" COMPANY_ID="$COMPANY_ID" IDX="$idx" TARGET_URL="$TARGET_URL" \
    "$LEX" run --allow-effects "$DEMO_FILE_EFFECTS" "$DEMO_DIR/operate_loop.lex" run_round_cmd
}

echo "[demo] company=$COMPANY_ID  db=$DB  target=$TARGET_URL"
rm -f "$DB"

DB_PATH="$DB" COMPANY_ID="$COMPANY_ID" \
  "$LEX" run --allow-effects "$DEMO_FILE_EFFECTS" "$DEMO_DIR/operate_loop.lex" seed_company_cmd

echo
echo "=== phase 1: baseline (server up) ==="
start_server
for i in 1 2 3 4; do round "$i"; done

echo
echo "=== phase 2: outage (killing the toy server -> real connection failure) ==="
stop_server
round 5
round 6

echo
echo "=== phase 3: recovery ==="
start_server
for i in 7 8 9; do round "$i"; done

echo
echo "=== phase 4: latency spike (server sleeps ${SLOW_SECONDS:-1.5}s before responding) ==="
set_mode slow
round 10
round 11

echo
echo "=== phase 5: recovery + settle (letting effect contracts reach their deadline) ==="
set_mode up
for i in 12 13 14 15 16 17 18 19 20; do round "$i"; done

stop_server

echo
echo "=== board report ==="
DB_PATH="$DB" COMPANY_ID="$COMPANY_ID" \
  "$LEX" run --allow-effects "$MAIN_FILE_EFFECTS" "$LOOM_ROOT/src/main.lex" board_report_cmd

echo
echo "=== CTL6 promotion status ==="
for class_key in restart scale rollback_release hold; do
  DB_PATH="$DB" COMPANY_ID="$COMPANY_ID" CLASS_KEY="$class_key" \
    "$LEX" run --allow-effects "$DEMO_FILE_EFFECTS" "$DEMO_DIR/operate_loop.lex" promotion_status_cmd
done

echo
echo "[demo] done. DB kept at $DB for inspection (sqlite3 \"$DB\" '...')."
