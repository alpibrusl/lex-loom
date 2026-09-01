#!/usr/bin/env bash
# real-cost-roundtrip.sh — live proof of real cost accounting (#94), fully
# offline (proc executors, no LLM, no network):
#
#   1. QUEUE-MODE BUDGET WALL — the gap this closes: queue-mode nodes used
#      to bypass the GOV2 envelope gate entirely. A REAL worker.lex process
#      now REFUSES a node whose role envelope is exhausted: failed
#      node_result with the BUDGET reason, board escalation queued, and the
#      job completes without retry (re-running an exhausted envelope only
#      re-refuses).
#   2. QUEUE-MODE CHARGING — a worker-executed node with headroom completes
#      and CHARGES its envelope (artifact-estimate fallback here — proc
#      executors report no usage), exactly like the inline path.
#   3. REAL PRICED LEDGER — three llm_usage readings recorded exactly as
#      runner.step writes them (haiku + sonnet + a free local model) price
#      to 8¢ per model rates — and record_iteration_cost books EXACTLY that,
#      not the character estimate; the board report says which basis it used.
#
# Run from the repo root:  bash demo/real-cost-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-cost-demo.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  pkill -f "run_worker" 2>/dev/null || true
  rm -rf "$WS"
}
trap cleanup EXIT

pass=0
fail=0
say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "   OK: $*"; pass=$((pass+1)); }
bad()  { echo "   FAIL: $*"; fail=$((fail+1)); }
q() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2" 2>/dev/null || echo ""; }
seed() { DB_PATH="$1" COMPANY_ID="$2" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/cost_seed.lex "$3" 2>&1; }

run_worker_until() { # db, grep-pattern in node_results
  local db="$1"
  ( DB_PATH="$db" WORKER_ID=cost-w POLL_MS=100 RECLAIM_LEASE_SECONDS=60 \
      exec lex run --max-steps 0 --allow-effects "$EFFECTS" src/worker.lex run_worker \
      > "$WS/worker.log" 2>&1 ) &
  local wpid="$!"
  PIDS+=("$wpid")
  for i in $(seq 1 60); do
    N="$(q "$db" "SELECT count(*) FROM node_results")"
    [ "${N:-0}" -ge 1 ] && break
    sleep 0.5
  done
  kill "$wpid" 2>/dev/null || true
}

say "1. queue-mode budget wall: exhausted envelope refuses at the worker"
GDB="$WS/gate.db"
seed "$GDB" costco seed_cmd | tail -1
seed "$GDB" costco exhaust_cmd | tail -1
seed "$GDB" costco enqueue_cmd | tail -1
run_worker_until "$GDB"
ACCEPTED="$(q "$GDB" "SELECT accepted FROM node_results WHERE sprint_id='costco/iter-1' AND node_id='write_docs'")"
REASON="$(q "$GDB" "SELECT reason FROM node_results WHERE sprint_id='costco/iter-1' AND node_id='write_docs'")"
[ "$ACCEPTED" = "0" ] && ok "node result recorded as refused (accepted=0)" || bad "expected refusal, got accepted='$ACCEPTED'"
echo "$REASON" | grep -q "BUDGET: spend envelope exhausted" && ok "refusal carries the BUDGET reason" || bad "wrong reason: $REASON"
JOB="$(q "$GDB" "SELECT status FROM lex_jobs ORDER BY id DESC LIMIT 1")"
[ "$JOB" = "done" ] && ok "job completed without retry (a refusal is an answer, not a transient failure)" || bad "job status '$JOB'"
ATT="$(q "$GDB" "SELECT count(*) FROM attention_queue WHERE sprint_id='costco/budget' AND verdict='pending'")"
[ "${ATT:-0}" -ge 1 ] && ok "exhaustion escalated to the board queue" || bad "no board escalation"
SPENT="$(q "$GDB" "SELECT spent_cents FROM budget_envelopes WHERE company_id='costco' AND scope='role:docs'")"
[ "$SPENT" = "100" ] && ok "refused node charged nothing (spent stays at the cap)" || bad "spent moved to '$SPENT'"

say "2. queue-mode charging: a node with headroom executes and is charged"
CDB="$WS/charge.db"
seed "$CDB" chargeco seed_cmd | tail -1
seed "$CDB" chargeco enqueue_cmd | tail -1
run_worker_until "$CDB"
ACCEPTED2="$(q "$CDB" "SELECT accepted FROM node_results WHERE sprint_id='chargeco/iter-1' AND node_id='write_docs'")"
[ "$ACCEPTED2" = "1" ] && ok "node executed and attested through the worker" || bad "node not attested: '$ACCEPTED2'"
SPENT2="$(q "$CDB" "SELECT spent_cents FROM budget_envelopes WHERE company_id='chargeco' AND scope='role:docs'")"
[ "${SPENT2:-0}" -ge 1 ] && ok "envelope charged by the worker path (spent=${SPENT2}c, artifact fallback — proc reports no usage)" || bad "envelope not charged: '$SPENT2'"
TRAIL="$(q "$CDB" "SELECT count(*) FROM traces WHERE event_kind='worker_node_executed'")"
[ "${TRAIL:-0}" -ge 1 ] && ok "execution trail-attributed to the worker" || bad "no worker_node_executed trail"
# #248: the allow-side stamp — the trail alone must say what the node was
# ALLOWED to do at dispatch (resolved preset + envelope state at that moment).
AUTH="$(q "$CDB" "SELECT data_json FROM traces WHERE event_kind='node_authority' ORDER BY rowid DESC LIMIT 1")"
echo "$AUTH" | grep -q '"preset":' && ok "node_authority stamped at dispatch: $AUTH" || bad "no node_authority trail event"
echo "$AUTH" | grep -q '"dispatcher":"cost-w"' && ok "authority names the dispatching worker" || bad "authority missing dispatcher: $AUTH"

say "3. the ledger books REAL priced usage, not the estimate"
LDB="$WS/ledger.db"
seed "$LDB" ledgerco seed_cmd >/dev/null
seed "$LDB" ledgerco usage_cmd | tail -1
OUT="$(seed "$LDB" ledgerco ledger_cmd | grep total_cost_cents)"
echo "$OUT" | grep -q "total_cost_cents=8" && ok "iteration booked at exactly 8¢ (haiku 2 + sonnet 6 + local 0)" || bad "ledger wrong: $OUT"
R="$(seed "$LDB" ledgerco report_cmd)"
echo "$R" | grep -q "real provider usage where reported, priced per model" && ok "board report states the real-usage basis" || bad "report basis line missing"
echo "$R" | grep -q "Spend so far: \$0.08" && ok "board report shows the priced spend (\$0.08)" || bad "report spend wrong: $(echo "$R" | grep 'Spend so far')"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
