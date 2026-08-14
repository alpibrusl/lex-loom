#!/usr/bin/env bash
# hb1-scheduler-roundtrip.sh — live proof of the HB1 heartbeat (#213), against
# the real production scheduler with NO provider keys and no network:
#
#   1. dormant skip     — a Maintenance company with an unmet wake_when is
#                         classified dormant; the scheduler does not run it.
#   2. stopped-for-good — a company whose stop_when already holds is skipped,
#                         tick after tick; the scheduler never resurrects it.
#   3. wake within one tick — after the company's grounded ctx changes so
#                         wake_when fires, the very next tick RUNs it (the run
#                         itself then fails fast — no LLM provider here — which
#                         is itself the graceful-degradation path).
#   4. restart safety   — every tick above is a SEPARATE scheduler process
#                         (MAX_TICKS=1): all state lives in the company DBs,
#                         so kill/restart between ticks is the demo's normal
#                         operating mode, not a special case.
#
# Run from the repo root:  bash demo/hb1-scheduler-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-hb1-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/wakeco" "$WS/stopco"

pass=0
fail=0
say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "   OK: $*"; pass=$((pass+1)); }
bad()  { echo "   FAIL: $*"; fail=$((fail+1)); }

one_tick() {
  LOOM_WORKSPACE="$WS" MAX_TICKS=1 TICK_MS=100 MAX_API_CALLS=1 EVOLVE=0 EXEC_MODE=inline \
    bash bin/loom-scheduler.sh 2>&1
}

say "seed: wakeco (dormant) + stopco (stopped)"
DB_PATH="$WS/wakeco/company.db" COMPANY_ID=wakeco \
  lex run --allow-effects "$EFFECTS" demo/hb1_seed.lex seed_dormant_cmd
DB_PATH="$WS/stopco/company.db" COMPANY_ID=stopco \
  lex run --allow-effects "$EFFECTS" demo/hb1_seed.lex seed_stopped_cmd

say "tick 1: both companies must be skipped (dormant / stopped)"
T1="$(one_tick)"
echo "$T1" | sed 's/^/   | /'
echo "$T1" | grep -q "skip wakeco (dormant)" && ok "wakeco classified dormant" || bad "wakeco not classified dormant"
echo "$T1" | grep -q "skip stopco (stopped)" && ok "stopco classified stopped" || bad "stopco not classified stopped"
echo "$T1" | grep -q "0 run(s) started"      && ok "no runs started"           || bad "a run started that should not have"

say "tick 2 (fresh process): stopco must STILL be stopped — no resurrection"
T2="$(one_tick)"
echo "$T2" | grep -q "skip stopco (stopped)" && ok "stopco stays stopped across restarts" || bad "stopco was resurrected"

say "wake: flip wakeco's grounded ctx so wake_when (verdict-failed) fires"
DB_PATH="$WS/wakeco/company.db" COMPANY_ID=wakeco \
  lex run --allow-effects "$EFFECTS" demo/hb1_seed.lex wake_cmd

say "tick 3 (fresh process): wakeco must be woken THIS tick"
T3="$(one_tick)"
echo "$T3" | sed 's/^/   | /' | head -12
echo "$T3" | grep -q "RUN wakeco (woken)" && ok "wakeco woken within one tick" || bad "wakeco not woken"
q() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$1" "$2" 2>/dev/null || echo 0; }
ITERS="$(q "$WS/wakeco/company.db" "SELECT count(*) FROM company_iterations WHERE company_id='wakeco' AND idx=2")"
[ "$ITERS" = "1" ] && ok "iteration 2 genuinely started (recorded in the company DB)" || bad "no iteration 2 recorded"

say "audit: every decision above is on the trail (scheduler_decision events)"
DEC="$(q "$WS/stopco/company.db" "SELECT count(*) FROM traces WHERE event_kind='scheduler_decision'")"
[ "${DEC:-0}" -ge 3 ] && ok "stopco has $DEC trail-recorded scheduler decisions" || bad "expected >=3 scheduler_decision trail events, got '$DEC'"

printf '\n== result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
