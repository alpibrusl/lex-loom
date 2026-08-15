#!/usr/bin/env bash
# org5-role-registry-roundtrip.sh — live proof of the data-driven roster
# (#220), fully offline (no LLM, no network):
#
#   1. packs — a company.toml [roles].packs = ["finance"] flattens through
#      bootstrap --no-run into ROLE_PACKS exactly; launching with it staffs
#      core + finance (castable_kinds shows finance roles, not research);
#      an UNKNOWN pack fails the launch loudly and saves nothing.
#   2. grant bound — on a company whose declared ceiling is Demo
#      (read-only, no exec), a runtime role proposal asking for the
#      Implementation grant is refused STRUCTURALLY at write time — an
#      agent-authored role can never carry a grant its company doesn't
#      already hold — and the refusal is on the trail.
#   3. bounded creation — a within-ceiling proposal parks before the board;
#      before approval the role is NOT castable (cast falls back generic);
#      after board approval (same resolve CLI as every gate) the role casts
#      through the REAL cast path as loom-dyn-<kind>, and the role_defs
#      ledger names proposer and approver.
#
# Run from the repo root:  bash demo/org5-role-registry-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-org5-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/org5co"
DB="$WS/org5co/company.db"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" COMPANY_ID=org5co "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org5_seed.lex "$LEXCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "1a. company.toml [roles].packs flattens through bootstrap --no-run"
cat > "$WS/company.toml" <<'TOML'
[identity]
id = "packdemo"
name = "Pack Demo Co"
mission = "Demonstrate the data-driven roster."

[stack]
path = "python-flask"

[roles]
packs = ["finance"]
TOML
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)"
echo "$BOOT" | grep -q "ROLE_PACKS='finance'" && ok "[roles].packs -> ROLE_PACKS flattening exact" || bad "ROLE_PACKS not flattened: $(echo "$BOOT" | tail -2)"

say "1b. launching with the finance pack staffs core + finance"
OUT="$(DB_PATH="$DB" COMPANY_ID=org5co MAX_ITERATIONS=0 EVOLVE=0 ROLE_PACKS=finance \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT" | grep -q "role packs staffed: core + finance" && ok "packs staffed at launch" || bad "packs not staffed: $OUT"
LEXCMD=castable_cmd
KS="$(seed env)"
echo "$KS" | grep -q "finance" && ok "finance roles castable" || bad "finance not castable: $KS"
echo "$KS" | grep -q "monetization_handoff" && ok "whole finance pack staffed" || bad "monetization_handoff missing"
echo "$KS" | grep -q "research" && bad "undeclared research pack leaked in" || ok "undeclared packs not staffed"

say "1c. an unknown pack fails the launch loudly"
OUT="$(DB_PATH="$WS/org5co/other.db" COMPANY_ID=badco MAX_ITERATIONS=0 EVOLVE=0 ROLE_PACKS=warpdrive \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT" | grep -q "FATAL: refusing to start — invalid \[roles\].packs declaration: unknown role pack 'warpdrive'" \
  && ok "unknown pack refused, launch aborted" || bad "unknown pack not refused: $OUT"

say "2. grant bound: a proposal above the company ceiling is refused structurally"
CEILDB="$WS/org5co/ceiling.db"
LEXCMD=save_cmd
OUT="$(DB_PATH="$CEILDB" COMPANY_ID=lockedco POLICY_ISOLATION=ceiling:Demo lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org5_seed.lex save_cmd 2>&1)"
echo "$OUT" | grep -q "saved" || { bad "ceiling company save failed"; exit 1; }
OUT="$(DB_PATH="$CEILDB" COMPANY_ID=lockedco KIND=growth_hacker PRESET=Implementation BY=ceo lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org5_seed.lex propose_cmd 2>&1)"
echo "$OUT" | grep -q "exceeds the company ceiling 'Demo'" && ok "over-grant proposal refused at write time" || bad "over-grant not refused: $OUT"
N="$(python3 -c "import sqlite3; print(sqlite3.connect('$CEILDB').execute(\"SELECT COUNT(*) FROM traces WHERE event_kind='role_refused'\").fetchone()[0])")"
[ "$N" = "1" ] && ok "structural refusal is on the trail" || bad "role_refused trail missing"
N="$(python3 -c "import sqlite3; print(sqlite3.connect('$CEILDB').execute('SELECT COUNT(*) FROM role_defs').fetchone()[0])")"
[ "$N" = "0" ] && ok "refusal wrote no role definition" || bad "refused proposal leaked a row"

say "3. bounded creation: propose -> board approves -> castable, ledgered"
LEXCMD=save_cmd
OUT="$(seed env)"
LEXCMD=propose_cmd
OUT="$(seed env KIND=growth_hacker TOOLS=research PRESET=Demo BY=ceo)"
echo "$OUT" | grep -q "proposal queued for the board" && ok "within-ceiling proposal queued" || bad "proposal failed: $OUT"
ATT="$(sqlq "SELECT id FROM attention_queue WHERE sprint_id='org5co/roles' AND verdict='pending'")"
[ -n "$ATT" ] && ok "proposal parks before the board (oracle=board)" || bad "no pending board item"
LEXCMD=cast_cmd
PRE="$(seed env ROLE=growth_hacker)"
echo "$PRE" | grep -q "^loom-dyn-growth_hacker|" && bad "role castable BEFORE approval" || ok "not castable before approval (generic fallback: $(echo "$PRE" | head -1))"
DB_PATH="$DB" ATTENTION_ID="$ATT" VERDICT=approved REASON="useful role, safe grant" RESOLVER_ID=board-jane \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd >/dev/null 2>&1
LEXCMD=apply_cmd
OUT="$(seed env)"
echo "$OUT" | grep -q "board APPROVED role 'growth_hacker' (board-jane)" && ok "approval applied on the heartbeat pass" || bad "approval not applied: $OUT"
LEXCMD=cast_cmd
POST="$(seed env ROLE=growth_hacker)"
echo "$POST" | grep -q "^loom-dyn-growth_hacker|growth_hacker$" && ok "approved role casts through the REAL cast path" || bad "cast wrong: $POST"
LEXCMD=defs_cmd
LEDGER="$(seed env)"
echo "$LEDGER" | grep -q "^growth_hacker|active|Demo|ceo|board-jane$" && ok "ledger: proposer=ceo, approver=board-jane, grant=Demo" || bad "ledger wrong: $LEDGER"
LEXCMD=castable_cmd
KS="$(seed env)"
echo "$KS" | grep -q "growth_hacker" && ok "castable_kinds includes the new role" || bad "new role missing from castable_kinds"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
