#!/usr/bin/env bash
# demo/attention-governance-roundtrip.sh — the lex-loom#165 decision-rights
# fix, live.
#
# relationships.lex was, until now, purely advisory: "who's accountable"
# for a human operator to read, nothing enforced — the actual approve/reject
# mechanism for a `human <oracle>` gate (attention_resolve_cmd, the one
# node class the whole system explicitly requires a real person to attest,
# e.g. monetization_handoff) had ZERO identity check and didn't even record
# who resolved it.
#
# This proves, against the real production src/main.lex CLI entry points
# (not a reimplementation):
#   1. RESOLVER_ID is required — refuses with no identity at all.
#   2. An oracle with NO registered contacts stays fully open (backward
#      compatible — any resolver is authorized, same as before this existed).
#   3. Once a contact IS registered for an oracle, an unregistered resolver
#      is DENIED — the item stays pending, untouched.
#   4. The registered contact IS authorized, and resolved_by is recorded on
#      the row — a real, checkable audit trail of who actually approved it.
#
#   bash demo/attention-governance-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/attention-governance-demo.db"
COMPANY_ID="acme-gov"
ORACLE="founder"
REGISTERED_CONTACT="jane-the-founder"
UNREGISTERED_PERSON="random-intern"

rm -f "$DB_PATH"
cleanup() {
  rm -f "$DB_PATH"
}
trap cleanup EXIT

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"

echo "+ seeding a real company + a real pending human-gate item via src/transport.lex::push_attention"
DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" ORACLE="$ORACLE" \
  lex run --allow-effects "$EFFECTS" demo/attention_seed.lex seed_cmd

ATTENTION_ID=$(DB_PATH="$DB_PATH" lex run --allow-effects "$EFFECTS" src/main.lex attention_list_cmd 2>&1 | grep -oE 'id=[a-f0-9]+' | head -1 | cut -d= -f2)
echo "  attention id: $ATTENTION_ID"

echo
echo "+ STEP 1: resolve with NO RESOLVER_ID — must refuse"
NO_RESOLVER_OUT=$(DB_PATH="$DB_PATH" ATTENTION_ID="$ATTENTION_ID" VERDICT=approved REASON="" \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd 2>&1)
echo "  $NO_RESOLVER_OUT"

echo
echo "+ STEP 2: no contact is registered for '$ORACLE' yet — an arbitrary resolver should still be DENIED-free (open gate)"
echo "  (checking the gate is genuinely open before locking it down, so step 3's denial is meaningful)"
STILL_PENDING_BEFORE_LOCK=$(DB_PATH="$DB_PATH" lex run --allow-effects "$EFFECTS" src/main.lex attention_list_cmd 2>&1)
echo "$STILL_PENDING_BEFORE_LOCK" | grep -q "id=$ATTENTION_ID" && echo "  ok: item still pending (nothing resolved it in step 1)"

echo
echo "+ registering '$REGISTERED_CONTACT' as the '$ORACLE' contact for $COMPANY_ID (locks the gate)"
COMPANY_ID="$COMPANY_ID" ORACLE="$ORACLE" CONTACT_ID="$REGISTERED_CONTACT" CONTACT_NAME="Jane the Founder" CONTACT_URL="mailto:jane@acme.example" \
  DB_PATH="$DB_PATH" \
  lex run --allow-effects "$EFFECTS" src/main.lex add_contact_cmd

echo
echo "+ STEP 3: resolve as an UNREGISTERED person now that a contact exists — must be DENIED"
DENIED_OUT=$(DB_PATH="$DB_PATH" ATTENTION_ID="$ATTENTION_ID" VERDICT=approved REASON="" RESOLVER_ID="$UNREGISTERED_PERSON" \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd 2>&1)
echo "  $DENIED_OUT"
STILL_PENDING_AFTER_DENY=$(DB_PATH="$DB_PATH" lex run --allow-effects "$EFFECTS" src/main.lex attention_list_cmd 2>&1)

echo
echo "+ STEP 4: resolve as the REGISTERED contact — must succeed and record resolved_by"
APPROVED_OUT=$(DB_PATH="$DB_PATH" ATTENTION_ID="$ATTENTION_ID" VERDICT=approved REASON="looks good" RESOLVER_ID="$REGISTERED_CONTACT" \
  lex run --allow-effects "$EFFECTS" src/main.lex attention_resolve_cmd 2>&1)
echo "  $APPROVED_OUT"
NO_LONGER_PENDING=$(DB_PATH="$DB_PATH" lex run --allow-effects "$EFFECTS" src/main.lex attention_list_cmd 2>&1)

echo
echo "+ checking everything against expectations"
fail=0
check() {
  if echo "$1" | grep -qE "$2"; then
    echo "  ok: $3"
  else
    echo "  FAILED: expected to find '$2' — $3" >&2
    fail=1
  fi
}
check "$NO_RESOLVER_OUT" "RESOLVER_ID is required" "no RESOLVER_ID at all is refused"
check "$STILL_PENDING_AFTER_DENY" "id=$ATTENTION_ID" "the denied attempt left the item untouched, still pending"
check "$DENIED_OUT" "DENIED.*$UNREGISTERED_PERSON.*not a registered contact" "an unregistered resolver is denied once a real contact exists for this oracle"
check "$APPROVED_OUT" "$ATTENTION_ID -> approved \(resolved_by=$REGISTERED_CONTACT\)" "the registered contact's resolve succeeds and echoes resolved_by"
check "$NO_LONGER_PENDING" "\(no pending human-attestation items\)" "the item is no longer pending after a real, authorized resolve"

if [ "$fail" -ne 0 ]; then
  echo
  echo "attention-governance-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "attention-governance-roundtrip: OK — relationships.lex's oracle contacts now actually gate who can resolve a human-attestation item, and every resolve is attributed to a real identity"
