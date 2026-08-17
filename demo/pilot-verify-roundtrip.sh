#!/usr/bin/env bash
# pilot-verify-roundtrip.sh — the Phase 3 wedge property, live and fully
# offline (#68): someone who did NOT produce a loom run verifies it
# independently, from the run record alone.
#
#   1. THE OPERATOR runs a real 2-node sprint through the actual
#      orchestrator (proc-executor agents, no LLM, no network). The run
#      writes the same record a model-driven run writes: node_accepted
#      trail events referencing content-addressed artifact hashes,
#      op_grant authority events, artifacts.
#   2. THE PILOT receives ONLY the DB file — no shared content store, no
#      trust in the operator's bookkeeping (LEX_STORE_ROOT points at an
#      empty store, simulating a different machine). The four-layer
#      verifier re-derives everything: sha256 of every accepted artifact
#      re-checked, grounded gates re-run, authority and operations
#      re-checked against the recorded grants. Signed did:lex
#      attestations are minted with verified:true.
#   3. TAMPERING IS CAUGHT: one artifact in the handed-over DB is edited
#      by one phrase. The same verification now reports the mismatch,
#      the verdict is FAILED, and the attestations are minted with
#      verified:false — reputation accrues only from verified runs.
#
# Run from the repo root:  bash demo/pilot-verify-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-pilot-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
SPRINT="pilotco/iter-1"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

verify() { # db-path -> full verifier output (pilot's empty content store)
  LEX_STORE_ROOT="$WS/pilot-store" DB_PATH="$1" SPRINT_ID="$SPRINT" \
    lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex verify_sprint_cmd 2>&1
}

say "1. the operator runs a REAL sprint (actual orchestrator, offline proc agents)"
OUT="$(DB_PATH="$WS/company.db" SPRINT_ID="$SPRINT" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" demo/pilot_seed.lex run_cmd 2>&1)"
echo "$OUT" | grep -q "PHASE|success" && ok "sprint completed" || { bad "sprint failed: $OUT"; exit 1; }
echo "$OUT" | grep -q "write_docs|attested" && ok "nodes attested by their gates" || bad "nodes not attested: $OUT"

say "2. the pilot receives ONLY the DB and verifies it independently"
cp "$WS/company.db" "$WS/received.db"
mkdir -p "$WS/pilot-store"   # empty content store = a different machine
VOUT="$(verify "$WS/received.db")"
echo "$VOUT" | grep -q '"verdict":"verified"'            && ok "integrity: every artifact re-hashes to its recorded id" || bad "integrity not verified: $VOUT"
echo "$VOUT" | grep -q '"verdict":"grounded-reproduced"' && ok "grounded gates reproduced" || bad "grounded layer failed"
echo "$VOUT" | grep -q '"verdict":"authority-ok"'        && ok "every node acted within its recorded grant" || bad "authority layer failed"
echo "$VOUT" | grep -q '"verdict":"ops-within-grant"'    && ok "every operation within the granted set" || bad "operations layer failed"
[ "$(echo "$VOUT" | grep -c '"verified":true')" = "2" ]  && ok "signed did:lex attestations minted with verified:true" || bad "attestations missing/unverified"

say "3. a tampered record cannot pass the same verification"
cp "$WS/company.db" "$WS/tampered.db"
python3 - "$WS/tampered.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE artifacts SET content = content || ' [quietly improved]' "
          "WHERE hash = (SELECT hash FROM artifacts LIMIT 1)")
c.commit()
PY
TOUT="$(verify "$WS/tampered.db")"
echo "$TOUT" | grep -q '"mismatched":1'         && ok "the edited artifact no longer hashes to its recorded id" || bad "tamper not detected: $TOUT"
echo "$TOUT" | grep -q '"verdict":"FAILED"'     && ok "integrity verdict is FAILED, recomputed not asserted" || bad "verdict not FAILED"
[ "$(echo "$TOUT" | grep -c '"verified":false')" = "2" ] && ok "attestations refuse: verified:false — no reputation from a tampered run" || bad "attestations did not refuse"

echo
if [ "$fail" -eq 0 ]; then
  echo "== RESULT: $pass passed, 0 failed"
else
  echo "== RESULT: $pass passed, $fail FAILED" >&2
  exit 1
fi
