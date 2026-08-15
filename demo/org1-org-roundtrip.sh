#!/usr/bin/env bash
# org1-org-roundtrip.sh — live proof of reporting lines (#216), fully offline:
#
#   1. manifest round-trip — a company.toml [org] table flattens through
#      bootstrap-company.sh --no-run into the ORG_EDGES env exactly.
#   2. DB + board_report round-trip — a valid org saves through the real
#      run_company_cmd path (max_iterations=0 so nothing executes) and the
#      board report renders the chart.
#   3. refuse, don't downgrade — a cyclic org aborts the launch loudly and
#      saves NOTHING.
#   4. escalation chain — a parked company whose blocking gate is past its
#      declared 1h timeout escalates through the reporting lines
#      (legal -> eng_manager -> founder) on the next scheduler tick.
#   5. flat companies unchanged — no [org] renders "(flat — no org declared)".
#
# Run from the repo root:  bash demo/org1-org-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-org1-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

say "1. company.toml [org] flattens through bootstrap --no-run"
cat > "$WS/company.toml" <<'TOML'
[identity]
id = "orgdemo"
name = "Org Demo Co"
mission = "Demonstrate reporting lines."

[stack]
path = "python-flask"

[org]
build = "eng_manager"
qa = "eng_manager"
eng_manager = "founder"
TOML
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)"
echo "$BOOT" | grep -q "ORG_EDGES='build:eng_manager,qa:eng_manager,eng_manager:founder'" \
  && ok "[org] table -> ORG_EDGES flattening exact" || bad "ORG_EDGES not flattened (got: $(echo "$BOOT" | grep 'to run' | head -1))"

say "2. valid org saves via run_company_cmd and renders in board_report"
mkdir -p "$WS/orgco"
DB="$WS/orgco/company.db"
OUT_OK="$(DB_PATH="$DB" COMPANY_ID=orgco MAX_ITERATIONS=0 EVOLVE=0 \
  ORG_EDGES="build:eng_manager,qa:eng_manager,eng_manager:founder" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT_OK" | grep -q "org chart loaded (3 reporting line(s))" && ok "org loaded at launch" || bad "org not loaded"
REPORT="$(DB_PATH="$DB" COMPANY_ID=orgco lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex board_report_cmd 2>&1)"
echo "$REPORT" | grep -q "eng_manager <- build, qa" && ok "board_report renders the chart" || bad "chart missing from board_report"
echo "$REPORT" | grep -q "founder <- eng_manager"   && ok "chart shows the root line"      || bad "root line missing"

say "3. a cyclic org is refused loudly and saves nothing"
mkdir -p "$WS/cycco"
CYC_DB="$WS/cycco/company.db"
OUT_CYC="$(DB_PATH="$CYC_DB" COMPANY_ID=cycco MAX_ITERATIONS=0 EVOLVE=0 \
  ORG_EDGES="build:qa,qa:pm,pm:build" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT_CYC" | grep -q "FATAL: refusing to start" && ok "cyclic org refused at launch" || bad "cycle not refused"
ROWS="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM relationships WHERE role LIKE 'org:%'\").fetchone()[0])" "$CYC_DB" 2>/dev/null || echo 0)"
[ "${ROWS:-0}" = "0" ] && ok "nothing was saved (refuse, don't downgrade)" || bad "org rows saved despite refusal"

say "4. overdue blocking gate escalates through the reporting lines"
mkdir -p "$WS/parkco"
PDB="$WS/parkco/company.db"
DB_PATH="$PDB" COMPANY_ID=parkco ORG_EDGES="legal:eng_manager,eng_manager:founder" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org1_seed.lex seed_parked_cmd
python3 -c "
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute(\"UPDATE attention_queue SET created_at = datetime('now', '-3 hours')\")
c.commit()" "$PDB"
TICK="$(LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 MAX_RUNS_PER_TICK=0 bash bin/loom-scheduler.sh 2>&1)"
echo "$TICK" | grep -q "skip parkco (parked)" && ok "parked company held by the scheduler" || bad "parked company not held"
echo "$TICK" | grep -q "escalation path: legal -> eng_manager -> founder" && ok "escalation walks the reporting lines" || bad "chain not walked"
ESC="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM traces WHERE event_kind='gate_escalated'\").fetchone()[0])" "$PDB")"
[ "${ESC:-0}" = "1" ] && ok "gate_escalated on the trail" || bad "no gate_escalated event"
TICK2="$(LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 MAX_RUNS_PER_TICK=0 bash bin/loom-scheduler.sh 2>&1)"
ESC2="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM traces WHERE event_kind='gate_escalated'\").fetchone()[0])" "$PDB")"
[ "${ESC2:-0}" = "1" ] && ok "escalation fires once, not every tick" || bad "escalation duplicated ($ESC2)"

say "5. a flat company (no [org]) is unchanged"
mkdir -p "$WS/flatco"
FDB="$WS/flatco/company.db"
OUT_FLAT="$(DB_PATH="$FDB" COMPANY_ID=flatco MAX_ITERATIONS=0 EVOLVE=0 ORG_EDGES="" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
FREPORT="$(DB_PATH="$FDB" COMPANY_ID=flatco lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex board_report_cmd 2>&1)"
echo "$FREPORT" | grep -q "(flat — no org declared)" && ok "flat company renders flat" || bad "flat company changed"

printf '\n== result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
