#!/usr/bin/env bash
# org3-manager-review-roundtrip.sh — live proof of manager roles (#218),
# fully offline (proc-executor agents, no LLM, no network).
#
# The acceptance scenario from the issue, end to end on one file DB:
# the engineering manager delegates, reviews, RETURNS one artifact for
# rework, and ACCEPTS the redo — all visible on the trail — while its
# accept/return verdicts move the worker's attestation ledger, and the
# Strategist's prompt consumes the manager's report instead of raw
# artifacts.
#
#   1. delegate — eng_manager offers a write_docs task to its report.
#   2. round 1 — the worker's first attempt is reviewed and RETURNED with
#      notes (assignment -> rework, worker bounced: attestation 5 -> 4).
#   3. round 2 — the redo (carrying the REWORK frame with the manager's
#      notes) is reviewed and ACCEPTED (assignment -> approved, worker
#      re-attested: 4 -> 5).
#   4. the full arc is on the trail: assignment_offered, assignment_rework,
#      assignment_approved, manager_report.
#   5. the Strategist's prompt contains the manager's summary — and does NOT
#      contain the artifact body.
#
# Run from the repo root:  bash demo/org3-manager-review-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-org3-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
DB="$WS/company.db"
CID="org3co"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }
seed() { DB_PATH="$DB" COMPANY_ID="$CID" "$@" lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org3_seed.lex "$LEXCMD" 2>&1; }
sqlq() { python3 -c "import sqlite3,sys; print('\n'.join(str(r[0]) for r in sqlite3.connect('$DB').execute(sys.argv[1])))" "$1"; }

say "0. seed: org chart + pool (docs worker = cat, eng_manager = demo reviewer)"
LEXCMD=seed_cmd
OUT="$(seed env)"
echo "$OUT" | grep -q "org saved" && ok "org + pool seeded" || { bad "seed failed: $OUT"; exit 1; }

say "1. the manager delegates"
LEXCMD=offer_cmd
OUT="$(seed env FROM_ROLE=eng_manager TO_ROLE=docs KIND=write_docs GOAL='document the delegation API')"
echo "$OUT" | grep -q "offer ok:" && ok "eng_manager -> docs assignment offered" || bad "offer failed: $OUT"

say "2. round 1: work is done, the manager REVIEWS and RETURNS it"
LEXCMD=cycle_cmd
OUT="$(seed env)"
echo "$OUT" | grep -q "1 review(s) conducted" && ok "review conducted" || bad "no review happened: $OUT"
echo "$OUT" | grep -q "RETURNED assignment .* for rework (round 1): first draft too thin" && ok "first attempt returned with the manager's notes" || bad "return missing: $OUT"
LEXCMD=status_cmd
STATUS="$(seed env)"
echo "$STATUS" | grep -q "^rework|write_docs|docs|1|" && ok "assignment in rework, round counted" || bad "rework state wrong: $STATUS"
LEXCMD=pool_cmd
POOL="$(seed env AGENT_ID=org3-pool-docs)"
echo "$POOL" | grep -q "^org3-pool-docs|4|1|$" && ok "return bounced the worker (attestation 5 -> 4)" || bad "worker ledger wrong after return: $POOL"

say "3. round 2: the redo carries the REWORK notes and is ACCEPTED"
LEXCMD=cycle_cmd
OUT="$(seed env)"
echo "$OUT" | grep -q "ACCEPTED assignment" && ok "manager accepted the redo" || bad "redo not accepted: $OUT"
LEXCMD=status_cmd
STATUS="$(seed env)"
echo "$STATUS" | grep -q "^approved|write_docs|docs|1|" && ok "assignment approved after exactly one rework round" || bad "approved state wrong: $STATUS"
LEXCMD=pool_cmd
POOL="$(seed env AGENT_ID=org3-pool-docs)"
echo "$POOL" | grep -q "^org3-pool-docs|5|1|$" && ok "accept re-attested the worker (4 -> 5)" || bad "worker ledger wrong after accept: $POOL"

say "4. the full arc is on the trail"
for K in assignment_offered assignment_rework assignment_approved manager_report; do
  N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='$K'")"
  [ "$N" -ge 1 ] && ok "$K on the trail" || bad "$K missing from the trail"
done
N="$(sqlq "SELECT COUNT(*) FROM traces WHERE event_kind='node_cast' AND data_json LIKE '%\"authority\":\"founder\"%'")"
[ "$N" -ge 1 ] && ok "review nodes were cast under founder's authority (the manager answers upward too)" || bad "review-node authority missing"

say "5. the Strategist consumes the manager's report, not the artifact"
LEXCMD=report_cmd
REPORT="$(seed env)"
echo "$REPORT" | grep -q "eng_manager team: 1 approved" && ok "report aggregates the subtree" || bad "report wrong: $REPORT"
LEXCMD=prompt_cmd
PROMPT="$(seed env)"
echo "$PROMPT" | grep -q "Management reports" && ok "strategist prompt carries the report section" || bad "prompt lacks the section"
echo "$PROMPT" | grep -q "write_docs -> docs: approved" && ok "prompt shows the summary line" || bad "summary line missing"
# The worker is `cat`, so its artifact body echoes the delegation frame
# verbatim ("Delegated task — ..."). The prompt must NOT contain it.
echo "$PROMPT" | grep -q "Delegated task" && bad "raw artifact body leaked into the strategist prompt" || ok "raw artifact body did NOT flow up"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
