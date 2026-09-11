#!/usr/bin/env bash
# nl0-need-parks-and-resumes.sh -- a founder-provided need parks the company
# on a board decision naming the exact variable, and a yes without the value
# parks it again (#451, the smallest slice of docs/needs-ledger.md). Drives
# the same check the iteration loop performs (needs_check_cmd) against a
# scaffolded company, resolves through loom's one decide path, and re-checks.
# No model, no network, no real credential: a dummy variable proves the
# mechanism.
set -euo pipefail
cd "$(dirname "$0")/.."
export MODEL="${MODEL:-kimi-k2.7-code}"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-nl0.XXXXXX")"; trap 'rm -rf "$W"' EXIT
unset DEMO_NEED_TOKEN
E="env,io,sql,time,fs_read,fs_write,proc,crypto,random,net,concurrent,vcs,llm,approval,stream"
DB="$W/needdemo/company.db"

cat > "$W/needdemo.company.toml" <<'TOML'
[identity]
id      = "needdemo"
name    = "NeedDemo"
mission = "prove that a missing founder-provided need parks the company"

[stack]
path  = "python-fastapi"
model = "kimi-k2.7-code"

[roles]
packs = ["core"]

[policy]
max_iterations = 1

[needs]
env = ["DEMO_NEED_TOKEN@1"]
TOML

echo "== 1. the manifest's [needs] env flattens through bootstrap to NEEDS"
out=$(LOOM_WORKSPACE="$W" bash bin/bootstrap-company.sh "$W/needdemo.company.toml" --no-run 2>&1) || true
if [[ "$out" == *"NEEDS='DEMO_NEED_TOKEN@1'"* ]]; then ok "bootstrap passes NEEDS='DEMO_NEED_TOKEN@1' to run-company"; else bad "NEEDS not flattened: $out"; fi

echo "== 2. the need is missing: the company parks on a board decision naming it"
out=$(DB_PATH="$DB" COMPANY_ID=needdemo NEEDS='DEMO_NEED_TOKEN@1' ITER=1 lex run --allow-effects "$E" src/main.lex needs_check_cmd 2>&1) || true
aid=$(printf '%s\n' "$out" | grep -o 'missing (attention [0-9a-f]*' | head -1 | grep -o '[0-9a-f]*$') || true
if [[ "$out" == *"PARKED: need DEMO_NEED_TOKEN missing (attention "* ]] && [[ "$out" == *"set DEMO_NEED_TOKEN on the runner machine, then approve"* ]] && [ -n "$aid" ]; then ok "parked with the exact variable in the message (attention $aid)"; else bad "did not park by name: $out"; fi
row=$(sqlite3 "$DB" "select node_id, oracle, verdict from attention_queue where id='$aid'" 2>/dev/null || true)
if [ "$row" = "need:DEMO_NEED_TOKEN|founder|pending" ]; then ok "attention item is need:DEMO_NEED_TOKEN for the founder, pending"; else bad "attention row wrong: '$row'"; fi
note=$(sqlite3 "$DB" "select a.content from artifacts a join attention_queue q on q.artifact_hash=a.hash where q.id='$aid'" 2>/dev/null || true)
if [[ "$note" == *"# Need: DEMO_NEED_TOKEN"* ]] && [[ "$note" == *"never leave that machine"* ]]; then ok "the decision's note names the variable and says values never leave the runner"; else bad "note wrong: $note"; fi
evs=$(sqlite3 "$DB" "select group_concat(event_kind) from traces where event_kind in ('need_missing','company_parked')" 2>/dev/null || true)
if [[ "$evs" == *need_missing* ]] && [[ "$evs" == *company_parked* ]]; then ok "trail records need_missing and company_parked"; else bad "trail missing events: $evs"; fi
iters=$(sqlite3 "$DB" "select count(*) from company_iterations" 2>/dev/null || echo "?")
if [ "$iters" = "0" ]; then ok "no iteration was consumed by the park"; else bad "park consumed an iteration: $iters"; fi

echo "== 3. the founder answers yes through loom's one decide path"
before=$(sqlite3 "$DB" "select verdict from attention_queue where id='$aid'") || true
DB_PATH="$DB" ATTENTION_ID="$aid" VERDICT=approved REASON='set it on the runner' RESOLVER_ID=founder-via-demo lex run --allow-effects "$E" src/main.lex attention_resolve_cmd >/dev/null 2>&1 || true
after=$(sqlite3 "$DB" "select verdict || ' by ' || resolved_by from attention_queue where id='$aid'") || true
if [ "$before" = "pending" ] && [ "$after" = "approved by founder-via-demo" ]; then ok "attention item resolved through attention_resolve_cmd ($before -> $after)"; else bad "resolve did not change the item: '$before' -> '$after'"; fi

echo "== 4. a yes WITHOUT the value parks again, on a new item -- it does not proceed"
out=$(DB_PATH="$DB" COMPANY_ID=needdemo NEEDS='DEMO_NEED_TOKEN@1' ITER=1 lex run --allow-effects "$E" src/main.lex needs_check_cmd 2>&1) || true
aid2=$(printf '%s\n' "$out" | grep -o 'missing (attention [0-9a-f]*' | head -1 | grep -o '[0-9a-f]*$') || true
if [[ "$out" == *"PARKED: need DEMO_NEED_TOKEN"* ]] && [ -n "$aid2" ] && [ "$aid2" != "$aid" ]; then ok "parked again on a fresh item ($aid2), not the resolved one"; else bad "did not re-park after an empty yes: $out"; fi

echo "== 5. with the value set on the runner, the check passes and the company proceeds"
out=$(DEMO_NEED_TOKEN=dummy-value DB_PATH="$DB" COMPANY_ID=needdemo NEEDS='DEMO_NEED_TOKEN@1' ITER=1 lex run --allow-effects "$E" src/main.lex needs_check_cmd 2>&1) || true
if [[ "$out" == *"[needs] satisfied for iteration 1"* ]]; then ok "satisfied once the variable exists"; else bad "did not pass with the value set: $out"; fi

echo "== 6. required_by is honoured: a need for iteration 3 does not block iteration 2"
out=$(DB_PATH="$DB" COMPANY_ID=needdemo NEEDS='DEMO_NEED_TOKEN@3' ITER=2 lex run --allow-effects "$E" src/main.lex needs_check_cmd 2>&1) || true
if [[ "$out" == *"[needs] satisfied for iteration 2"* ]]; then ok "a later need does not stall an earlier iteration"; else bad "required_by ignored: $out"; fi
out=$(DB_PATH="$DB" COMPANY_ID=needdemo NEEDS='DEMO_NEED_TOKEN@3' ITER=3 lex run --allow-effects "$E" src/main.lex needs_check_cmd 2>&1) || true
if [[ "$out" == *"PARKED: need DEMO_NEED_TOKEN"* ]]; then ok "and it parks when its iteration comes"; else bad "did not park at its iteration: $out"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
