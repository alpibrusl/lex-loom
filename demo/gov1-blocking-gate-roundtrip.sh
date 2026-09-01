#!/usr/bin/env bash
# gov1-blocking-gate-roundtrip.sh — live proof of blocking human gates (#221),
# against the real orchestrator + the real CLI resolve path, fully offline:
#
#   1. park      — a `human legal blocking` gate parks itself AND its dependent
#                  subtree; the independent track completes in the same pass.
#   2. hold      — a second pass (fresh process) with the gate still pending
#                  parks again: no duplicate attention item, no auto-approve.
#   3. approve   — the board approves via the REAL attention_resolve_cmd CLI
#                  (same identity-gated path as lex-loom#165); the next pass
#                  seals the gate from the human-attested artifact and the
#                  downstream node finally runs.
#   4. reject    — in a second sprint, the board rejects with a reason; the
#                  next pass cancels the subtree, the reason lands on the
#                  trail, and nothing downstream ever runs.
#
# Run from the repo root:  bash demo/gov1-blocking-gate-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loom-gov1-demo.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/company.db"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

one_pass() { # $1 = sprint id
  DB_PATH="$DB" SPRINT_ID="$1" \
    lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gov1_gate.lex pass_cmd 2>&1
}

pending_id() { # $1 = sprint id
  python3 -c "import sqlite3,sys; r=sqlite3.connect(sys.argv[1]).execute(\"SELECT id FROM attention_queue WHERE sprint_id=? AND verdict='pending'\", (sys.argv[2],)).fetchone(); print(r[0] if r else '')" "$DB" "$1"
}

say "pass 1: blocking gate parks; dependent held; independent completes"
P1="$(one_pass demo-approve)"
echo "$P1" | sed 's/^/   | /'
echo "$P1" | grep -q "legal_review|held|PARKED awaiting oracle 'legal'" && ok "gate parked awaiting the board" || bad "gate did not park"
echo "$P1" | grep -q "publish|held|PARKED downstream"                   && ok "dependent subtree held"        || bad "dependent subtree not held"
echo "$P1" | grep -q "independent_docs|attested"                        && ok "independent track completed"   || bad "independent track blocked"
echo "$P1" | grep -q "PHASE|success"                                    && ok "parked is not failure"         || bad "phase failed"

say "pass 2 (fresh process, gate still pending): parks again, no duplicates"
P2="$(one_pass demo-approve)"
echo "$P2" | grep -q "legal_review|held|PARKED awaiting" && ok "still parked — no auto-approve path" || bad "gate did not stay parked"
N_ITEMS="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM attention_queue WHERE sprint_id='demo-approve'\").fetchone()[0])" "$DB")"
[ "$N_ITEMS" = "1" ] && ok "exactly one attention item (no duplicate push)" || bad "expected 1 attention item, got $N_ITEMS"

say "board approves via the real CLI resolve path"
AID="$(pending_id demo-approve)"
DB_PATH="$DB" ATTENTION_ID="$AID" VERDICT=approved REASON="ship it" RESOLVER_ID=board-jane \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd 2>&1 | sed 's/^/   | /'

say "pass 3: approval resumes the subtree"
P3="$(one_pass demo-approve)"
echo "$P3" | sed 's/^/   | /'
echo "$P3" | grep -q "legal_review|attested" && ok "gate sealed from the board's approval" || bad "gate not sealed"
echo "$P3" | grep -q "publish|attested"      && ok "downstream resumed and completed"      || bad "downstream did not run"
echo "$P3" | grep -q "PHASE|success"         && ok "phase completed after approval"        || bad "phase failed after approval"

say "reject flow: board rejection cancels the subtree with a ledgered reason"
R1="$(one_pass demo-reject)"
RID="$(pending_id demo-reject)"
DB_PATH="$DB" ATTENTION_ID="$RID" VERDICT=rejected REASON="not legally publishable" RESOLVER_ID=board-jane \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd 2>&1 | sed 's/^/   | /'
R2="$(one_pass demo-reject)"
echo "$R2" | sed 's/^/   | /'
echo "$R2" | grep -q "legal_review|held|cancelled by board-jane: not legally publishable" && ok "rejection cancels with the board's reason" || bad "no cancellation reason"
echo "$R2" | grep -q "PHASE|failed" && ok "rejection fails the phase (subtree cancelled)" || bad "phase did not fail"
echo "$R2" | grep -q "publish|attested" && bad "downstream ran after rejection" || ok "nothing downstream of the rejected gate ran"
CANCELLED="$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT count(*) FROM traces WHERE event_kind='node_cancelled' AND agent_id='demo-reject'\").fetchone()[0])" "$DB")"
[ "${CANCELLED:-0}" -ge 1 ] && ok "cancellation is on the trail (node_cancelled)" || bad "no node_cancelled trail event"

printf '\n== result: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
