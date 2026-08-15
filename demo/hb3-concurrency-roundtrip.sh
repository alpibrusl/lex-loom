#!/usr/bin/env bash
# hb3-concurrency-roundtrip.sh — live proof of HB3 true concurrency (#215),
# fully offline (proc executors, no LLM, no network):
#
#   1. TWO WORKERS, ONE SPRINT — two real worker.lex processes drain one
#      company's job queue concurrently; the sprint completes with every
#      node executed EXACTLY once (verified from the worker_node_executed
#      trail, not from logs), and both workers demonstrably participated.
#      This is the lifted lex-loom#197 limit: run-company.sh no longer
#      refuses WORKER_COUNT > 1.
#   2. THE RUN CAP IS REAL — a 3-company workspace ticked with
#      MAX_RUNS_PER_TICK=2 runs exactly two and parks the third with
#      run_cap_reached.
#   3. 3 COMPANIES, ONE TICK — a fresh 3-company workspace ticked with
#      MAX_RUNS_PER_TICK=3 makes progress on ALL THREE inside one tick
#      (concurrent list.par_map runs; each company records its iteration).
#   4. AUDIT INTACT — parallel runs interleave, but every scheduler
#      decision and every worker execution still attributes to its own
#      company / sprint / worker on the trail.
#
# (The money side — no lost updates on the cost ledger, exact envelope
# totals, and Exhausted tripping correctly under parallel charges — is
# proven in tests/test_concurrency.lex.)
#
# Run from the repo root:  bash demo/hb3-concurrency-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-hb3-demo.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  pkill -f "run_worker" 2>/dev/null || true
  rm -rf "$WS"
}
trap cleanup EXIT
mkdir -p "$WS/qco"

pass=0
fail=0
say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "   OK: $*"; pass=$((pass+1)); }
bad()  { echo "   FAIL: $*"; fail=$((fail+1)); }
q() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2" 2>/dev/null || echo ""; }
qall() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))" "$1" "$2" 2>/dev/null || echo ""; }

QDB="$WS/qco/company.db"
SPRINT="hb3co/iter-1"
NODES=6

say "1. two workers drain one sprint's queue — no node runs twice"
DB_PATH="$QDB" lex run --allow-effects "$EFFECTS" demo/hb3_seed.lex seed_cmd
for w in w1 w2; do
  ( DB_PATH="$QDB" WORKER_ID="$w" POLL_MS=100 RECLAIM_LEASE_SECONDS=60 \
      exec lex run --max-steps 0 --allow-effects "$EFFECTS" src/worker.lex run_worker \
      > "$WS/worker-$w.log" 2>&1 ) &
  PIDS+=("$!")
done
sleep 1
DB_PATH="$QDB" SPRINT_ID="$SPRINT" NODES="$NODES" \
  OUT="$(DB_PATH="$QDB" SPRINT_ID="$SPRINT" NODES="$NODES" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/hb3_seed.lex queue_sprint_cmd 2>&1)"
echo "$OUT" | grep -q "queue sprint done: $NODES/$NODES nodes attested" \
  && ok "sprint completed: $NODES/$NODES nodes attested through the queue" || bad "sprint incomplete: $OUT"

EXECS="$(q "$QDB" "SELECT count(*) FROM traces WHERE event_kind='worker_node_executed' AND agent_id='$SPRINT'")"
[ "$EXECS" = "$NODES" ] && ok "trail holds exactly $NODES worker_node_executed events (one per node)" || bad "expected $NODES executions on the trail, got '$EXECS'"
DUPS="$(q "$QDB" "SELECT count(*) FROM (SELECT json_extract(data_json,'\$.node') AS n, count(*) AS c FROM traces WHERE event_kind='worker_node_executed' AND agent_id='$SPRINT' GROUP BY n HAVING c > 1)")"
[ "$DUPS" = "0" ] && ok "no node executed twice (trail-verified)" || bad "$DUPS node(s) executed more than once"
WORKERS_SEEN="$(q "$QDB" "SELECT count(DISTINCT json_extract(data_json,'\$.worker')) FROM traces WHERE event_kind='worker_node_executed' AND agent_id='$SPRINT'")"
[ "$WORKERS_SEEN" = "2" ] && ok "both workers executed nodes (distinct workers on the trail: $WORKERS_SEEN)" || bad "expected 2 distinct workers, got '$WORKERS_SEEN'"
echo "   + per-worker split:"
qall "$QDB" "SELECT '     ' || json_extract(data_json,'\$.worker') || ': ' || count(*) || ' node(s)' FROM traces WHERE event_kind='worker_node_executed' AND agent_id='$SPRINT' GROUP BY json_extract(data_json,'\$.worker')"
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
PIDS=()

say "2. the run cap is real: 3 companies, MAX_RUNS_PER_TICK=2"
mkdir -p "$WS/capws/delta" "$WS/capws/echo" "$WS/capws/foxtrot"
for c in delta echo foxtrot; do
  DB_PATH="$WS/capws/$c/company.db" COMPANY_ID="$c" \
    lex run --allow-effects "$EFFECTS" demo/hb3_seed.lex seed_company_cmd
done
T1="$(LOOM_WORKSPACE="$WS/capws" MAX_TICKS=1 TICK_MS=100 EVENT_POLL_MS=0 MAX_RUNS_PER_TICK=2 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline bash bin/loom-scheduler.sh 2>&1)"
RUNS1="$(echo "$T1" | grep -c "^\[scheduler\] RUN " || true)"
[ "$RUNS1" = "2" ] && ok "exactly 2 of 3 companies ran under the cap" || bad "expected 2 RUNs, got $RUNS1"
echo "$T1" | grep -q "skip foxtrot (run_cap_reached)" && ok "third company parked with run_cap_reached" || bad "no run_cap_reached skip: $(echo "$T1" | grep skip)"
echo "$T1" | grep -q "2 run(s) started" && ok "tick reports 2 runs started" || bad "tick run count wrong"

say "3. all 3 companies progress within ONE tick (MAX_RUNS_PER_TICK=3, concurrent)"
mkdir -p "$WS/port/alpha" "$WS/port/bravo" "$WS/port/charlie"
for c in alpha bravo charlie; do
  DB_PATH="$WS/port/$c/company.db" COMPANY_ID="$c" \
    lex run --allow-effects "$EFFECTS" demo/hb3_seed.lex seed_company_cmd
done
T2="$(LOOM_WORKSPACE="$WS/port" MAX_TICKS=1 TICK_MS=100 EVENT_POLL_MS=0 MAX_RUNS_PER_TICK=3 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline bash bin/loom-scheduler.sh 2>&1)"
for c in alpha bravo charlie; do
  echo "$T2" | grep -q "RUN $c (due)" && ok "$c RUN in the same tick" || bad "$c did not run"
done
echo "$T2" | grep -q "3 run(s) started" && ok "one tick started all 3 runs (concurrently)" || bad "tick run count wrong"
for c in alpha bravo charlie; do
  ITERS="$(q "$WS/port/$c/company.db" "SELECT count(*) FROM company_iterations WHERE company_id='$c'")"
  [ "${ITERS:-0}" -ge 1 ] && ok "$c genuinely progressed (iteration recorded in its own DB)" || bad "$c has no iteration recorded"
done

say "4. audit intact: every decision and execution attributes to its owner"
for c in alpha bravo charlie; do
  DEC="$(q "$WS/port/$c/company.db" "SELECT count(*) FROM traces WHERE agent_id='$c' AND event_kind='scheduler_decision'")"
  [ "${DEC:-0}" -ge 1 ] && ok "$c: $DEC scheduler decision(s) on its own trail" || bad "$c: missing scheduler_decision trail"
done
CROSS="$(q "$WS/port/alpha/company.db" "SELECT count(*) FROM traces WHERE agent_id IN ('bravo','charlie')")"
[ "$CROSS" = "0" ] && ok "no cross-company trail bleed (alpha's DB holds only alpha's events)" || bad "found $CROSS foreign trail rows in alpha's DB"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
