#!/usr/bin/env bash
# gov2-budget-envelope-roundtrip.sh — live proof of budget authority (#222),
# fully offline (proc-executor agents, no LLM, no network):
#
#   1. board-only changes — setting an envelope without RESOLVER_ID is
#      refused by the CLI; with it, the change is trailed with the actor.
#   2. hard cap stops the track, the sibling completes — track A's total
#      envelope is exhausted: its run refuses to start an iteration
#      (stopped_by=budget) and ESCALATES to the board's attention queue;
#      sibling track B (own envelope, plenty of headroom) runs its
#      iteration in the same database.
#   3. mid-sprint role refusal — with role:docs exhausted, a real
#      run_phase refuses the docs node at dispatch while the demo node in
#      the same phase completes. No overdraft: spent never exceeds by a
#      charge the check didn't see, and never goes negative.
#   4. the board report shows per-envelope utilization with
#      WARNING/EXHAUSTED flags.
#
# Run from the repo root:  bash demo/gov2-budget-envelope-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-gov2-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
DB="$WS/company.db"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gov2_seed.lex "$LEXCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "0. seed: two sibling tracks (companies) in one database"
LEXCMD=seed_cmd
OUT="$(seed env COMPANY_ID=track-a)"; echo "$OUT" | grep -q "saved" || { bad "seed a failed"; exit 1; }
OUT="$(seed env COMPANY_ID=track-b)"; echo "$OUT" | grep -q "saved" || { bad "seed b failed"; exit 1; }
ok "track-a and track-b saved"

say "1. envelope changes are board-only and attributed"
OUT="$(DB_PATH="$DB" COMPANY_ID=track-a SCOPE=total CAP_CENTS=5 lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex budget_set_cmd 2>&1)"
echo "$OUT" | grep -q "RESOLVER_ID is required" && ok "no RESOLVER_ID -> refused" || bad "unattributed change not refused: $OUT"
OUT="$(DB_PATH="$DB" COMPANY_ID=track-a SCOPE=total CAP_CENTS=5 RESOLVER_ID=board-jane lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex budget_set_cmd 2>&1)"
echo "$OUT" | grep -q "set to 5c by board-jane" && ok "board sets track-a total = 5c" || bad "board set failed: $OUT"
OUT="$(DB_PATH="$DB" COMPANY_ID=track-b SCOPE=total CAP_CENTS=100000 RESOLVER_ID=board-jane lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex budget_set_cmd 2>&1)"
echo "$OUT" | grep -q "set to 100000c" && ok "board sets track-b total = 100000c" || bad "board set b failed: $OUT"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='budget_envelope_set' AND data_json LIKE '%board-jane%'")"
[ "$N" = "2" ] && ok "both changes trailed with the actor" || bad "envelope_set trail wrong: $N"

say "2. track-a drains its envelope; its run stops and escalates, track-b completes"
LEXCMD=charge_cmd
OUT="$(seed env COMPANY_ID=track-a ROLE=docs CENTS=5)"
LEXCMD=run_cmd
A="$(seed env COMPANY_ID=track-a)"
echo "$A" | grep -q "stopped_by=budget" && ok "track-a refused to start an iteration (no overdraft)" || bad "track-a not budget-stopped: $A"
echo "$A" | grep -q "iterations=0" && ok "track-a ran nothing" || bad "track-a ran despite exhaustion"
N="$(sqlq "SELECT COUNT(*) FROM attention_queue WHERE sprint_id='track-a/budget' AND oracle='board' AND verdict='pending'")"
[ "$N" = "1" ] && ok "exhaustion escalated to the board's attention queue" || bad "no board escalation: $N"
B="$(seed env COMPANY_ID=track-b)"
echo "$B" | grep -q "stopped_by=budget" && bad "sibling track-b was budget-stopped too" || ok "sibling track-b was not budget-blocked"
N="$(sqlq "SELECT COUNT(*) FROM company_iterations WHERE company_id='track-b'")"
[ "$N" -ge 1 ] && ok "track-b genuinely ran its iteration (recorded in the DB)" || bad "track-b iteration missing"

say "3. mid-sprint: an exhausted role envelope refuses only that role"
OUT="$(DB_PATH="$DB" COMPANY_ID=track-b SCOPE=role:docs CAP_CENTS=1 RESOLVER_ID=board-jane lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex budget_set_cmd 2>&1)"
LEXCMD=charge_cmd
OUT="$(seed env COMPANY_ID=track-b ROLE=docs CENTS=1)"
LEXCMD=dispatch_cmd
D="$(seed env COMPANY_ID=track-b)"
echo "$D" | grep -q "^write|refused|BUDGET" && ok "docs node refused at dispatch" || bad "docs node not refused: $D"
echo "$D" | grep -q "^summarize|attested|" && ok "demo node in the same phase completed" || bad "unrelated node blocked: $D"
SPENT="$(sqlq "SELECT spent_cents FROM budget_envelopes WHERE id='track-b|role:docs'")"
[ "$SPENT" = "1" ] && ok "refused node charged nothing (spent stays exactly 1c, never negative)" || bad "spent drifted: $SPENT"

say "4. the board report shows utilization"
LEXCMD=report_cmd
R="$(seed env COMPANY_ID=track-b)"
echo "$R" | grep -q "role:docs: 1c of 1c (100%) EXHAUSTED" && ok "role envelope shows EXHAUSTED" || bad "utilization wrong: $R"
echo "$R" | grep -q "total: .*c of 100000c" && ok "total envelope shows utilization" || bad "total line missing"
BR="$(DB_PATH="$DB" COMPANY_ID=track-b lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex board_report_cmd 2>&1)"
echo "$BR" | grep -q "Budget envelopes" && ok "board_report carries the budget section" || bad "board_report lacks budget section"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
