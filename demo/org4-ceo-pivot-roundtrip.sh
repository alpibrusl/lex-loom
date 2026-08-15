#!/usr/bin/env bash
# org4-ceo-pivot-roundtrip.sh — live proof of the CEO (#219), fully offline
# (proc-executor agents, no LLM, no network), through the REAL scheduler
# heartbeat and the REAL board CLI:
#
#   1. distress — a company with 2 consecutive failed iterations and a flat
#      settlement-recorded revenue signal. On the next heartbeat tick the
#      CEO is consulted and emits a PIVOT PROPOSAL with its evidence
#      attached, queued before the board (oracle "board"). Nothing changes.
#   2. hysteresis — a second tick emits NO duplicate proposal, and a
#      healthy sibling company never consults the CEO at all.
#   3. board approval — the human resolves the proposal through the same
#      attention_resolve_cmd every other board decision uses (RESOLVER_ID
#      recorded).
#   4. the pivot lands — the next tick applies it: companies.goal is
#      revised, the mission ledger gains a row naming proposal + approver
#      (founding mission stays row 1), and the scheduler's RUN of the
#      company shows the Strategist executing the NEW goal.
#
# Run from the repo root:  bash demo/org4-ceo-pivot-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-org4-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/org4co" "$WS/org4well"
DB="$WS/org4co/company.db"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }
one_tick() {
  LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline MAX_RUNS_PER_TICK="$1" \
    bash bin/loom-scheduler.sh 2>&1
}

say "0. seed: org4co (distressed) + org4well (healthy control)"
DB_PATH="$DB" COMPANY_ID=org4co lex run --allow-effects "$EFFECTS" demo/org4_seed.lex seed_distressed_cmd
DB_PATH="$WS/org4well/company.db" COMPANY_ID=org4well lex run --allow-effects "$EFFECTS" demo/org4_seed.lex seed_healthy_cmd

say "1. tick 1: the CEO is consulted and proposes a pivot — advisory only"
T1="$(one_tick 0)"
echo "$T1" | grep -q "\[ceo\] org4co: grounded signals warrant consulting the CEO" && ok "mechanical gate opened on grounded distress" || bad "gate did not open: $T1"
echo "$T1" | grep -q "\[ceo\] org4co: PROPOSAL (pivot) queued for the board" && ok "pivot proposal queued before the board" || bad "no proposal queued"
echo "$T1" | grep -q "\[ceo\] org4well" && bad "healthy company consulted the CEO (churn)" || ok "healthy company never consulted the CEO"
N="$(sqlq "SELECT COUNT(*) FROM attention_queue WHERE sprint_id='org4co/ceo' AND oracle='board' AND verdict='pending'")"
[ "$N" = "1" ] && ok "exactly one pending board item" || bad "pending item count wrong: $N"
HASH="$(sqlq "SELECT artifact_hash FROM attention_queue WHERE sprint_id='org4co/ceo'")"
EV="$(sqlq "SELECT content FROM artifacts WHERE hash='$HASH'")" || EV=""
echo "$EV" | grep -q "consecutive failed iterations: 2" && ok "evidence attached to the proposal" || bad "evidence missing from proposal artifact"
GOAL="$(DB_PATH="$DB" COMPANY_ID=org4co lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org4_seed.lex goal_cmd 2>&1)"
echo "$GOAL" | grep -q "goal: founding mission: build a widget factory" && ok "goal unchanged — proposal is advisory until approved" || bad "goal changed without approval: $GOAL"

say "2. tick 2: hysteresis — no duplicate proposal while one is pending"
T2="$(one_tick 0)"
echo "$T2" | grep -q "PROPOSAL" && bad "duplicate proposal emitted" || ok "no proposal churn on the second tick"
N="$(sqlq "SELECT COUNT(*) FROM attention_queue WHERE sprint_id='org4co/ceo'")"
[ "$N" = "1" ] && ok "still exactly one board item" || bad "board item count grew: $N"

say "3. the board approves the pivot (the same resolve CLI as every gate)"
ATT="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='org4co/ceo' AND verdict='pending'")"
DB_PATH="$DB" ATTENTION_ID="$ATT" VERDICT=approved REASON="pivot makes sense given the evidence" RESOLVER_ID=board-jane \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd >/dev/null 2>&1
V="$(sqlq "SELECT verdict || '|' || resolved_by FROM attention_queue WHERE id='$ATT'")"
[ "$V" = "approved|board-jane" ] && ok "board approval recorded with the approver's id" || bad "resolve failed: $V"

say "4. tick 3: the pivot lands and the Strategist runs under the NEW goal"
T3="$(one_tick 1)"
echo "$T3" | grep -q "board APPROVED pivot (board-jane) — mission revised" && ok "approved pivot applied on the heartbeat" || bad "pivot not applied: $T3"
echo "$T3" | grep -q "RUN org4co" && ok "scheduler ran the company this tick" || bad "company did not run"
echo "$T3" | grep -q "goal=pivot to a paid analytics API" && ok "the iteration executes the NEW goal" || bad "iteration still on the old goal"
GOAL="$(DB_PATH="$DB" COMPANY_ID=org4co lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org4_seed.lex goal_cmd 2>&1)"
echo "$GOAL" | grep -q "goal: pivot to a paid analytics API" && ok "companies.goal durably revised" || bad "goal not revised: $GOAL"

say "5. the mission ledger tells the whole story"
LEDGER="$(DB_PATH="$DB" COMPANY_ID=org4co lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org4_seed.lex ledger_cmd 2>&1)"
echo "$LEDGER" | grep -q "^1|founding|founder|founding mission: build a widget factory" && ok "row 1: the founding mission, by the founder" || bad "founding row wrong: $LEDGER"
echo "$LEDGER" | grep -q "^2|ceo_proposal $ATT|board-jane|pivot to a paid analytics API" && ok "row 2: the revision, naming proposal + approver" || bad "revision row wrong: $LEDGER"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='mission_revised'")"
[ "$N" = "1" ] && ok "mission_revised on the trail" || bad "mission_revised trail missing"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
