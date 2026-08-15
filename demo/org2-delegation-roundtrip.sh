#!/usr/bin/env bash
# org2-delegation-roundtrip.sh — live proof of agent→agent delegation (#217),
# fully offline (proc-executor agents, no LLM, no network):
#
#   1. closed vocabulary — a kind outside known_kinds() is refused at the
#      write gate and never becomes an assignment.
#   2. structural gate — delegating to a role that does NOT report to you is
#      refused against the DB org chart; the refusal lands on the trail.
#   3. authorized offer — manager -> direct report writes an `offered`
#      assignment row plus an assignment_offered trail event.
#   4. the delegate tool cannot self-authorize — it appends request lines to
#      a file ([net,io,proc]: no sql); flush_delegations replays them through
#      the same gate: 2 requests in, only the org-authorized one survives.
#   5. materialization — drain_assignments runs each accepted assignment as an
#      ordinary sprint node: the docs assignment (proc:cat) completes and its
#      artifact lands on the row; the qa assignment (proc:true → empty output)
#      fails its gate and is RETURNED with the escalation chain from ORG1's
#      reporting lines.
#   6. authority on the trail — the drained node was cast under the
#      delegator's authority per the org chart (node_cast authority field).
#
# Run from the repo root:  bash demo/org2-delegation-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-org2-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
DB="$WS/company.db"
CID="org2co"
SPRINT="$CID/assign-demo"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" COMPANY_ID="$CID" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org2_seed.lex "$LEXCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "0. seed: org chart + proc-executor pool (docs=cat succeeds, qa=true fails)"
LEXCMD=seed_cmd
OUT="$(seed env)"
echo "$OUT" | grep -q "org saved" && ok "org chart + pool seeded" || { bad "seed failed: $OUT"; exit 1; }

say "1. closed vocabulary: unknown task kind refused"
LEXCMD=offer_cmd
OUT="$(seed env FROM_ROLE=eng_manager TO_ROLE=docs KIND=run_arbitrary_shell GOAL=anything)"
echo "$OUT" | grep -q "refused: delegation refused: unknown task kind" && ok "free-form kind refused at the gate" || bad "unknown kind not refused: $OUT"

say "2. structural gate: no org edge, no delegation"
OUT="$(seed env FROM_ROLE=docs TO_ROLE=eng_manager KIND=write_docs GOAL='delegate upward')"
echo "$OUT" | grep -q "refused: delegation refused: 'docs' has no may_assign authority" && ok "upward delegation refused" || bad "upward delegation not refused: $OUT"
[ "$(sqlq "SELECT COUNT(*) FROM assignments")" = "0" ] && ok "refusals wrote no assignment rows" || bad "refusal leaked a row"
[ "$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='delegation_refused'")" = "2" ] && ok "both refusals are on the trail" || bad "refusal trail missing"

say "3. authorized offers: manager -> direct reports"
OUT="$(seed env FROM_ROLE=eng_manager TO_ROLE=docs KIND=write_docs GOAL='document the delegation flow')"
echo "$OUT" | grep -q "offer ok:" && ok "eng_manager -> docs accepted" || bad "authorized offer failed: $OUT"
OUT="$(seed env FROM_ROLE=eng_manager TO_ROLE=qa KIND=write_tests GOAL='cover the delegation gate')"
echo "$OUT" | grep -q "offer ok:" && ok "eng_manager -> qa accepted" || bad "authorized offer failed: $OUT"
[ "$(sqlq "SELECT COUNT(*) FROM assignments WHERE status='offered'")" = "2" ] && ok "2 offered assignment rows" || bad "wrong offered count"

say "4. the delegate tool cannot self-authorize"
LEXCMD=tool_flush_cmd
OUT="$(seed env FROM_ROLE=eng_manager)"
echo "$OUT" | grep -q "tool emitted 2 requests; 1 authorized by the org chart" && ok "2 tool requests -> 1 assignment (org gate, not tool)" || bad "tool flush gating wrong: $OUT"

say "5. drain: assignments run as ordinary sprint nodes"
LEXCMD=drain_cmd
OUT="$(seed env SPRINT_ID="$SPRINT")"
echo "$OUT" | grep -q "draining 3 delegated assignment(s)" && ok "drain picked up all 3 offered assignments" || bad "drain count wrong: $OUT"
echo "$OUT" | grep -q "write_docs -> docs) done" && ok "docs assignment completed" || bad "docs assignment did not complete: $OUT"
echo "$OUT" | grep -q "RETURNED" && ok "qa assignment returned (gate failed)" || bad "qa assignment not returned: $OUT"
echo "$OUT" | grep -q "escalation path: eng_manager -> founder" && ok "return escalates up the ORG1 reporting lines" || bad "escalation chain missing: $OUT"
LEXCMD=status_cmd
STATUS="$(seed env)"
echo "$STATUS" | grep -q "^done|write_docs|docs|" && ok "artifact landed on the done assignment row" || bad "done row missing artifact: $STATUS"
echo "$STATUS" | grep -q "^returned|write_tests|qa||" && ok "returned row carries the failure reason" || bad "returned row wrong: $STATUS"

say "6. authority is on the trail"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='node_cast' AND data_json LIKE '%\"authority\":\"eng_manager\"%'")"
[ "$N" -ge 2 ] && ok "drained nodes cast under eng_manager's authority ($N node_cast events)" || bad "authority missing from node_cast"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='assignment_done'")"
[ "$N" -ge 2 ] && ok "assignment_done on the trail" || bad "assignment_done missing"
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='assignment_returned'")"
[ "$N" = "1" ] && ok "assignment_returned on the trail" || bad "assignment_returned missing"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
