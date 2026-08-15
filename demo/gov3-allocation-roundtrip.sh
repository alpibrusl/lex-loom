#!/usr/bin/env bash
# gov3-allocation-roundtrip.sh — live proof of the allocation loop (#223),
# fully offline (proc-executor agents, no LLM, no network), through the REAL
# heartbeat pass and the REAL board resolve CLI:
#
#   1. revenue -> proposal — with a board-set envelope and a verified
#      revenue reading in place, one heartbeat consults the finance agent,
#      which proposes new caps WITH a falsifiable prediction ("verified
#      revenue >= 500c by iteration 2"). The proposal parks before the
#      board; envelopes DO NOT change (no code path without a decision).
#   2. board approves — via the same attention_resolve_cmd as every gate;
#      the next heartbeat applies the caps AS the approving board member
#      (GOV2's budget_envelope_set trail names them).
#   3. the loop grades itself — the company reaches the predicted
#      iteration with a verified reading above target: the next heartbeat
#      grades the applied allocation HIT, and the hit rate feeds the next
#      proposal's evidence.
#   4. rejection stands — the follow-up proposal is rejected; envelopes
#      stay exactly where the board left them, disposition ledgered.
#
# Loom never moves real money: allocations govern INTERNAL spend envelopes
# (LLM/tool cost) only.
#
# Run from the repo root:  bash demo/gov3-allocation-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-gov3-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
DB="$WS/company.db"
CID="gov3co"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" COMPANY_ID="$CID" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gov3_seed.lex "$LEXCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "0. seed: company + finance agent; board sets the founding envelope; revenue verified"
LEXCMD=seed_cmd
OUT="$(seed env)"; echo "$OUT" | grep -q "saved" || { bad "seed failed: $OUT"; exit 1; }
DB_PATH="$DB" COMPANY_ID="$CID" SCOPE=total CAP_CENTS=1000 RESOLVER_ID=board-jane \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex budget_set_cmd >/dev/null 2>&1
LEXCMD=revenue_cmd
OUT="$(seed env IDX=1 CENTS=100)"
ok "envelope total=1000c (board) + verified revenue 100c recorded"

say "1. heartbeat: finance proposes new caps with a falsifiable prediction"
LEXCMD=heartbeat_cmd
H1="$(seed env)"
echo "$H1" | grep -q "PROPOSAL queued for the board" && ok "proposal queued before the board" || bad "no proposal: $H1"
echo "$H1" | grep -q "predicts >=500c verified revenue by iteration 2" && ok "proposal carries the falsifiable prediction" || bad "prediction missing"
CAP="$(sqlq "SELECT cap_cents FROM budget_envelopes WHERE id='$CID|total'")"
[ "$CAP" = "1000" ] && ok "envelopes UNCHANGED — advisory until the board decides" || bad "envelope changed without a decision: $CAP"
EV="$(sqlq "SELECT content FROM artifacts WHERE sprint_id='$CID/allocation' AND content LIKE '%evidence%' LIMIT 1")"
echo "$EV" | grep -q "no graded allocations yet" && ok "evidence carries the (empty) track record" || bad "evidence missing track record"

say "2. the board approves; the next heartbeat applies AS the approver"
ATT="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='$CID/allocation' AND verdict='pending'")"
DB_PATH="$DB" ATTENTION_ID="$ATT" VERDICT=approved REASON="evidence supports it" RESOLVER_ID=board-jane \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd >/dev/null 2>&1
LEXCMD=heartbeat_cmd
H2="$(seed env)"
echo "$H2" | grep -q "envelope total -> 2000c (approved by board-jane)" && ok "total cap applied as board-jane" || bad "apply failed: $H2"
echo "$H2" | grep -q "envelope role:docs -> 500c (approved by board-jane)" && ok "role:docs cap applied as board-jane" || bad "role cap missing"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='budget_envelope_set' AND data_json LIKE '%board-jane%'")"
[ "$N" -ge 2 ] && ok "every cap change attributed on the GOV2 trail" || bad "attribution missing"

say "3. the loop grades itself: prediction met -> HIT, fed into the next evidence"
LEXCMD=iter_cmd
OUT="$(seed env IDX=2)"
LEXCMD=revenue_cmd
OUT="$(seed env IDX=2 CENTS=600)"
LEXCMD=heartbeat_cmd
H3="$(seed env)"
echo "$H3" | grep -q "graded hit (predicted >=500c, actual 600c)" && ok "applied allocation graded HIT against verified revenue" || bad "grading missing: $H3"
echo "$H3" | grep -q "PROPOSAL queued" && ok "next-period proposal follows the grade" || bad "no follow-up proposal"
LEXCMD=hitrate_cmd
HR="$(seed env)"
echo "$HR" | grep -q "1 of 1 graded allocation prediction(s) hit" && ok "hit rate is part of the evidence channel" || bad "hit rate wrong: $HR"
EV2="$(sqlq "SELECT content FROM artifacts WHERE sprint_id='$CID/allocation' AND content LIKE '%evidence%' ORDER BY created_at DESC LIMIT 1")"
echo "$EV2" | grep -q "1 of 1 graded" && ok "the board sees the track record on the new proposal" || bad "track record not in new evidence"

say "4. rejection changes nothing"
ATT2="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='$CID/allocation' AND verdict='pending'")"
DB_PATH="$DB" ATTENTION_ID="$ATT2" VERDICT=rejected REASON="hold at current caps" RESOLVER_ID=board-jane \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd >/dev/null 2>&1
LEXCMD=heartbeat_cmd
H4="$(seed env)"
echo "$H4" | grep -q "board REJECTED allocation" && ok "rejection ledgered" || bad "rejection not processed: $H4"
CAP="$(sqlq "SELECT cap_cents FROM budget_envelopes WHERE id='$CID|total'")"
[ "$CAP" = "2000" ] && ok "envelopes stand exactly where the board left them" || bad "envelope drifted: $CAP"
LEXCMD=allocs_cmd
LEDGER="$(seed env)"
echo "$LEDGER" | grep -q "^applied|500|2|hit" && ok "ledger: applied + graded hit" || bad "ledger wrong: $LEDGER"
echo "$LEDGER" | grep -q "^rejected|500|2|" && ok "ledger: rejected disposition kept" || bad "rejected row missing"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
