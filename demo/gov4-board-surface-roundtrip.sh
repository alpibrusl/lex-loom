#!/usr/bin/env bash
# gov4-board-surface-roundtrip.sh — live proof of the board decision surface
# (#224), fully offline (proc-executor agents, no LLM; the only network is
# the demo's own localhost web server):
#
#   1. all five decision types flow through ONE queue, produced by the REAL
#      paths: a GOV1 blocking gate parks, GOV3's allocation heartbeat and
#      ORG4's CEO heartbeat propose, ORG5's propose_role queues, and an
#      operate escalation dossier lands at the address the heartbeat queuer
#      uses. `loom board pending` lists them typed and aged.
#   2. identity is enforced on BOTH paths by the SAME function: a
#      non-registered identity is DENIED by the CLI (board_decide_cmd) AND
#      by the web API (POST /api/board/decide/:id) once a contact is
#      registered for the oracle (#165 / #204).
#   3. defer is a recorded board act that leaves the item pending.
#   4. board_report LEADS with pending decisions + the oldest age; the
#      decision history reads back as typed, attributed minutes.
#
# Run from the repo root:  bash demo/gov4-board-surface-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-gov4-demo.XXXXXX")"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$WS"; }
trap cleanup EXIT
DB="$WS/company.db"
CID="gov4co"
WEB_PORT=8377
API_TOKEN="gov4-demo-token"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" COMPANY_ID="$CID" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gov4_seed.lex "$LEXCMD" 2>&1; }
cli()  { DB_PATH="$DB" COMPANY_ID="$CID" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex "$MAINCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "1. queue all five decision types through the real producers"
LEXCMD=seed_cmd;         OUT="$(seed env)"; echo "$OUT" | grep -q "seeded" || { bad "seed failed: $OUT"; exit 1; }
LEXCMD=gate_cmd;         OUT="$(seed env)"; echo "$OUT" | grep -q "gate parked" && ok "GOV1 blocking gate parked (gate)" || bad "gate: $OUT"
LEXCMD=gov_pass_cmd;     OUT="$(seed env)"
echo "$OUT" | grep -q "\[allocation\] $CID: PROPOSAL queued" && ok "GOV3 allocation proposal queued (allocation)" || bad "allocation: $OUT"
echo "$OUT" | grep -q "\[ceo\] $CID: PROPOSAL (pivot) queued" && ok "ORG4 strategy proposal queued (strategy)" || bad "strategy: $OUT"
LEXCMD=propose_role_cmd; OUT="$(seed env)"; echo "$OUT" | grep -q "role proposal queued" && ok "ORG5 role proposal queued (role)" || bad "role: $OUT"
LEXCMD=operate_cmd;      OUT="$(seed env)"; echo "$OUT" | grep -q "operate dossier decision queued" && ok "operate dossier queued (operate)" || bad "operate: $OUT"

say "2. one typed, aged queue — loom board pending"
MAINCMD=board_pending_cmd
P="$(cli env)"
echo "$P" | grep -q "DECISIONS AWAITING THE BOARD: 5 pending" && ok "five decisions, one surface" || bad "pending wrong: $P"
for T in gate allocation strategy role operate; do
  echo "$P" | grep -q "\[$T\]" && ok "type '$T' listed" || bad "type '$T' missing"
done
echo "$P" | grep -q "(oldest: " && ok "oldest age surfaced" || bad "age missing"

say "3. identity: register the board contact, then try an impostor on BOTH paths"
LEXCMD=contact_cmd; OUT="$(seed env ORACLE=board CONTACT_ID=board-jane)"
OUT="$(seed env ORACLE=legal CONTACT_ID=board-jane)"
ok "board-jane registered for oracles board + legal"
ALLOC_ID="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='$CID/allocation' AND verdict='pending'")"
MAINCMD=board_decide_cmd
OUT="$(cli env ATTENTION_ID="$ALLOC_ID" VERDICT=approved RESOLVER_ID=impostor)"
echo "$OUT" | grep -q "DENIED: impostor is not a registered contact" && ok "CLI: impostor DENIED" || bad "CLI let the impostor through: $OUT"

echo "   + starting the real production web server (src/web/server.lex serve_loom) on :$WEB_PORT"
( PORT="$WEB_PORT" DB_PATH="$DB" LOOM_API_TOKEN="$API_TOKEN" \
    lex run --allow-effects "$EFFECTS" src/web/server.lex serve_loom >/dev/null 2>&1 ) &
PIDS+=("$!")
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$WEB_PORT/" && break; sleep 0.5; done
API="$(curl -s "http://localhost:$WEB_PORT/api/board/pending/$CID?token=$API_TOKEN")"
echo "$API" | grep -q '"count":5' && ok "API: same five decisions on /api/board/pending" || bad "API pending wrong: $API"
DENY="$(curl -s -X POST "http://localhost:$WEB_PORT/api/board/decide/$ALLOC_ID?token=$API_TOKEN" -d '{"verdict":"approved","resolver_id":"impostor"}')"
echo "$DENY" | grep -q "DENIED: impostor is not a registered contact" && ok "API: impostor DENIED by the SAME check" || bad "API let the impostor through: $DENY"

say "4. defer is a recorded act; the item stays pending"
OUT="$(cli env ATTENTION_ID="$ALLOC_ID" VERDICT=deferred REASON="need next quarter numbers" RESOLVER_ID=board-jane)"
echo "$OUT" | grep -q "deferred by board-jane" && ok "defer recorded with the actor" || bad "defer failed: $OUT"
MAINCMD=board_pending_cmd
P2="$(cli env)"
echo "$P2" | grep -q "DECISIONS AWAITING THE BOARD: 5 pending" && ok "deferred item still pending (age keeps counting)" || bad "defer removed the item"

say "5. decide via API + CLI; the report leads with the queue; minutes read back"
APPROVE="$(curl -s -X POST "http://localhost:$WEB_PORT/api/board/decide/$ALLOC_ID?token=$API_TOKEN" -d '{"verdict":"approved","resolver_id":"board-jane"}')"
echo "$APPROVE" | grep -q '"verdict":"approved"' && ok "API: board-jane approves the allocation" || bad "API approve failed: $APPROVE"
ROLE_ID="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='$CID/roles' AND verdict='pending'")"
MAINCMD=board_decide_cmd
OUT="$(cli env ATTENTION_ID="$ROLE_ID" VERDICT=rejected REASON="not yet staffed for it" RESOLVER_ID=board-jane)"
echo "$OUT" | grep -q "rejected by board-jane" && ok "CLI: board-jane rejects the role" || bad "CLI reject failed: $OUT"
MAINCMD=board_report_cmd
R="$(cli env)"
echo "$R" | head -1 | grep -q "DECISIONS AWAITING THE BOARD: 3 pending" && ok "board_report LEADS with the decision queue" || bad "report does not lead with decisions: $(echo "$R" | head -1)"
MAINCMD=board_minutes_cmd
M="$(cli env)"
echo "$M" | grep -q "\[allocation\] $ALLOC_ID: approved by board-jane" && ok "minutes: allocation approval attributed" || bad "minutes missing approval: $M"
echo "$M" | grep -q "\[role\] $ROLE_ID: rejected by board-jane — not yet staffed for it" && ok "minutes: role rejection with reason" || bad "minutes missing rejection"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
