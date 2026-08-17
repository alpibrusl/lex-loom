#!/usr/bin/env bash
# gp1-ts-path-roundtrip.sh — live proof of the Node/TS golden path (#92),
# fully offline (no LLM, no network, no npm install):
#
#   1. skeleton — paths/node-ts-api runs its own test suite green on
#      node:* builtins alone (node:test + node:assert, type stripping,
#      no package ever installed), exactly as a freshly bootstrapped
#      company would.
#   2. launch story — the skeleton boots on an arbitrary PORT, answers
#      /health, accepts a published post on /loom/content, and /blog
#      serves it to a real request (boot + curl, the same story the
#      loom `launch` node needs).
#   3. grounded gate — the ts_build `spec compiles` gate is real: it
#      passes actual TypeScript, refuses a syntax error with
#      COMPILE_FAIL, and refuses an empty work dir (prose-not-code) —
#      never a silent allow (tests/test_ts_path.lex, run for real).
#
# Run from the repo root:  bash demo/gp1-ts-path-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs"

pass=0
fail=0
check() {
  local name="$1" ok="$2"
  if [ "$ok" = "0" ]; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    fail=$((fail + 1))
  fi
}

echo "== GP1: Node/TS golden path roundtrip (node $(node --version)) =="

echo
echo "-- 1. skeleton test suite (node:* builtins only)"
out=$( (cd paths/node-ts-api && node --experimental-strip-types --test tests/*.test.ts) 2>&1 ) && rc=0 || rc=1
echo "$out" | grep -E "^# (tests|pass|fail)" | sed 's/^/   | /'
check "skeleton suite runs" "$rc"
echo "$out" | grep -q "^# fail 0" && check "0 failing skeleton tests" 0 || check "0 failing skeleton tests" 1

echo
echo "-- 2. launch story: boot + curl on an arbitrary port"
PORT=8183
(cd paths/node-ts-api && PORT=$PORT node --experimental-strip-types app.ts &)
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.25
done
health=$(curl -sf "http://127.0.0.1:$PORT/health" || echo MISS)
echo "   | /health → $health"
[ "$health" = '{"ok":true}' ] && check "/health answers on PORT=$PORT" 0 || check "/health answers on PORT=$PORT" 1

publish=$(curl -sf -X POST "http://127.0.0.1:$PORT/loom/content" -H 'content-type: application/json' -d '{"title":"GP1","body":"The stack is selectable now."}' || echo MISS)
echo "   | POST /loom/content → $publish"
echo "$publish" | grep -q '"ok":true' && check "content publishes" 0 || check "content publishes" 1

blog=$(curl -sf "http://127.0.0.1:$PORT/blog" || echo MISS)
echo "   | /blog → ${blog:0:60}..."
echo "$blog" | grep -q "GP1" && check "/blog serves the published post" 0 || check "/blog serves the published post" 1
kill %1 2>/dev/null || true

echo
echo "-- 3. grounded ts_build gate (pass real TS / refuse syntax error / refuse prose)"
out=$(${LEX:-lex} run --max-steps 0 --allow-effects "$EFFECTS" tests/test_ts_path.lex run_all 2>&1) && rc=0 || rc=1
echo "$out" | sed 's/^/   | /'
fails=$(echo "$out" | tail -1)
[ "$rc" = "0" ] && [ "$fails" = "0" ] && check "grounded gate behaves (0 failing checks)" 0 || check "grounded gate behaves (0 failing checks)" 1

echo
echo "== GP1 roundtrip: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
