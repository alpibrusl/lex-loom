#!/usr/bin/env bash
# hosted-verify-roundtrip.sh — the hosted verifier, live and fully offline
# (#68): a pilot POSTs a run record they were handed to a verification
# service and gets recomputed verdicts back — one verifier, two
# transports (the service relays to the same verify_record_cmd a pilot
# runs locally).
#
#   1. THE OPERATOR runs a real sprint (actual orchestrator, offline
#      proc agents) — same driver as demo/pilot-verify-roundtrip.sh.
#   2. THE SERVICE starts token-gated, with LEX_STORE_ROOT pointed at an
#      empty dedicated store so every upload is judged SELF-CONTAINED
#      (it refuses to start without either).
#   3. THE PILOT posts the record: verdicts come back recomputed —
#      integrity verified, authority ok, operations ok, and the grounded
#      layer visibly SKIPPED (re-running grounded gates would execute
#      build commands from the upload; hosts opt in only inside a
#      sandbox).
#   4. A TAMPERED record posted to the same endpoint comes back
#      verified:false with the integrity mismatch counted.
#   5. No token → 401. A shell-hostile sprint_id → 400, refused.
#
# Run from the repo root:  bash demo/hosted-verify-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-hosted-verify.XXXXXX")"
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WS"
}
trap cleanup EXIT
SPRINT="pilotco/iter-1"
PORT="${VERIFY_PORT:-9400}"
TOKEN="demo-verify-token-xyz"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

payload() { # db-file -> writes $WS/payload.b64 (raw base64 body)
  base64 -w0 "$1" > "$WS/payload.b64"
}

say "1. the operator runs a REAL sprint (offline)"
OUT="$(DB_PATH="$WS/company.db" SPRINT_ID="$SPRINT" \
  lex run --max-steps 0 --allow-effects "$EFFECTS" demo/pilot_seed.lex run_cmd 2>&1)"
echo "$OUT" | grep -q "PHASE|success" && ok "sprint completed" || { bad "sprint failed: $OUT"; exit 1; }

say "2. the hosted verifier starts (token-gated, dedicated empty store)"
mkdir -p "$WS/store"
( VERIFY_API_TOKEN="$TOKEN" LEX_STORE_ROOT="$WS/store" PORT="$PORT" \
    exec lex run --max-steps 0 --allow-effects "$EFFECTS" \
    src/server/verify_api.lex serve_verify_api > "$WS/server.log" 2>&1 ) &
PIDS+=("$!")
for i in $(seq 1 30); do curl -s -o /dev/null "http://localhost:$PORT/healthz" && break; sleep 0.5; done
curl -s "http://localhost:$PORT/healthz" | grep -q '"ok":true' && ok "service is up" || { bad "service did not start: $(cat "$WS/server.log")"; exit 1; }

say "3. the pilot POSTs the record they were handed"
payload "$WS/company.db"
CLEAN="$(curl -s -X POST "http://localhost:$PORT/verify?sprint_id=$SPRINT" \
  -H "Authorization: Bearer $TOKEN" --data-binary @"$WS/payload.b64")"
echo "$CLEAN" | grep -q '"verified":true'   && ok "verdicts recomputed: verified" || bad "not verified: $CLEAN"
echo "$CLEAN" | grep -q '"verdict":"verified"' && ok "integrity re-derived from the upload alone" || bad "integrity wrong: $CLEAN"
echo "$CLEAN" | grep -q '"skipped":true'    && ok "grounded layer visibly skipped (no code exec from uploads by default)" || bad "grounded not skipped: $CLEAN"
echo "$CLEAN" | grep -q '"verdict":"authority-ok"' && ok "authority recomputed" || bad "authority wrong"

say "4. a tampered record cannot pass the same endpoint"
cp "$WS/company.db" "$WS/tampered.db"
python3 - "$WS/tampered.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE artifacts SET content = content || ' [quietly improved]' "
          "WHERE hash = (SELECT hash FROM artifacts LIMIT 1)")
c.commit()
PY
payload "$WS/tampered.db"
TAMPERED="$(curl -s -X POST "http://localhost:$PORT/verify?sprint_id=$SPRINT" \
  -H "Authorization: Bearer $TOKEN" --data-binary @"$WS/payload.b64")"
echo "$TAMPERED" | grep -q '"verified":false' && ok "tampered record: verified:false" || bad "tamper not caught: $TAMPERED"
echo "$TAMPERED" | grep -q '"mismatched":1'   && ok "the edited artifact counted as a mismatch" || bad "mismatch not counted"

say "5. gates: no token is 401; a shell-hostile sprint_id is refused"
NO_AUTH="$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORT/verify?sprint_id=$SPRINT" \
  --data-binary @"$WS/payload.b64")"
[ "$NO_AUTH" = "401" ] && ok "unauthenticated POST denied with 401" || bad "expected 401, got $NO_AUTH"
# a RAW single quote in the query (curl passes it through unencoded) is
# the byte that could break out of the relay's single-quoted shell word —
# it must be refused before any shell sees it. (An URL-ENCODED quote is
# harmless: nothing in the pipeline ever decodes it back.)
HOSTILE="$(curl -s -X POST "http://localhost:$PORT/verify?sprint_id=x';rm" \
  -H "Authorization: Bearer $TOKEN" -d "AAAA")"
echo "$HOSTILE" | grep -q "refused characters" && ok "hostile sprint_id refused before any shell sees it" || bad "hostile id not refused: $HOSTILE"

echo
if [ "$fail" -eq 0 ]; then
  echo "== RESULT: $pass passed, 0 failed"
else
  echo "== RESULT: $pass passed, $fail FAILED" >&2
  exit 1
fi
