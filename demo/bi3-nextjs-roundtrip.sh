#!/usr/bin/env bash
# bi3-nextjs-roundtrip.sh — live proof of the SECOND bootstrap-install golden
# path (#256 weight class): Next.js with standalone output. Like bi1 this
# NEEDS THE NETWORK (npm registry) and runs in the demo-bootstrap-install CI
# job, not demo-smoke.
#
#   1. bootstrap-install — [stack].path = "nextjs" runs the skeleton's
#      .loom-install once; re-bootstrap skips (marker).
#   2. the build is real — `npm run build` (next build, standalone output)
#      and the skeleton's own test suite passes against the built server.
#   3. launch story — .next/standalone/server.js boots with PLAIN node on an
#      arbitrary PORT (no node_modules at runtime) and serves the SSR
#      landing page, /health, and the /loom/* surface.
#   4. the sprint↔workspace bridge gates this path with ZERO new gate code:
#      the marker-keyed `spec compiles` gate runs the real `next build`
#      against a sprint's nested app/page.tsx — broken JSX fails with real
#      compiler output, a valid page passes.
#
# Run from the repo root:  bash demo/bi3-nextjs-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

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

echo "== BI3: nextjs bootstrap-install roundtrip (node $(node --version)) =="

WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-bi3-demo.XXXXXX")"
trap 'kill "$(cat "$WS/srv.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$WS"' EXIT

cat > "$WS/company.toml" <<TOML
[identity]
id = "nextco"
name = "Next Co"
mission = "Prove the Next.js bootstrap-install path end to end."

[stack]
path = "nextjs"

[policy]
max_iterations = 1
TOML

echo
echo "-- 1. bootstrap runs the one-time install; re-bootstrap skips"
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)" && rc=0 || rc=1
echo "$BOOT" | grep -E "one-time|skeleton" | sed 's/^/   | /'
check "bootstrap succeeds" "$rc"
DIR="$WS/nextco"
[ -f "$DIR/.loom-installed" ] && [ -d "$DIR/node_modules/next" ] && check "installed (marker + node_modules/next)" 0 || check "installed (marker + node_modules/next)" 1
BOOT2="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)" || true
echo "$BOOT2" | grep -q "skipping one-time install" && check "re-bootstrap skips install" 0 || check "re-bootstrap skips install" 1

echo
echo "-- 2. the workspace build is real (next build, standalone) + skeleton tests"
(cd "$DIR" && npm run build > "$WS/build.log" 2>&1) && rc=0 || rc=1
check "npm run build produces the standalone server" "$rc"
[ -f "$DIR/.next/standalone/server.js" ] && check "standalone server.js exists" 0 || check "standalone server.js exists" 1
(cd "$DIR" && npm test > "$WS/test.log" 2>&1) && rc=0 || rc=1
check "skeleton test suite passes against the built server" "$rc"

echo
echo "-- 3. launch story: plain node, PORT env, SSR + /loom surface"
PORT=8187
(cd "$DIR" && PORT=$PORT HOSTNAME=127.0.0.1 exec node .next/standalone/server.js >"$WS/srv.log" 2>&1) &
echo $! > "$WS/srv.pid"
for i in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.25
done
health=$(curl -sf "http://127.0.0.1:$PORT/health" || echo MISS)
echo "   | /health → $health"
[ "$health" = '{"ok":true}' ] && check "/health answers on PORT=$PORT" 0 || check "/health answers on PORT=$PORT" 1
curl -sf "http://127.0.0.1:$PORT/" | grep -q "<h1>nextjs</h1>" && check "SSR landing page serves" 0 || check "SSR landing page serves" 1
publish=$(curl -sf -X POST "http://127.0.0.1:$PORT/loom/content" -H 'content-type: application/json' -d '{"title":"BI3","body":"Next.js, installed once at bootstrap."}' || echo MISS)
echo "$publish" | grep -q '"ok":true' && check "content publishes" 0 || check "content publishes" 1
curl -sf "http://127.0.0.1:$PORT/blog" | grep -q "BI3" && check "blog serves the published post" 0 || check "blog serves the published post" 1

echo
echo "-- 4. sprint bridge gates this path with ZERO new gate code"
EFFECTS=approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream
TSWORK="/tmp/loom-ts-work-nextco_iter-1"
rm -rf "$TSWORK" && mkdir -p "$TSWORK/app"
cat > "$TSWORK/app/page.tsx" <<'TSX'
export default function Home() { return <main; }
TSX
OUT=$(LOOM_WORKSPACE="$WS" ${LEX:-lex} run --allow-effects "$EFFECTS" src/agent/runner.lex verify_compiles_at '""' '"ts_build"' '"nextco/iter-1"' 2>&1 || true)
echo "$OUT" | grep -q '"\$variant":"Err"' && echo "$OUT" | grep -qi "workspace app build" && check "broken nested page.tsx fails the bridged gate" 0 || { echo "$OUT" | tail -5 | sed 's/^/   | /'; check "broken nested page.tsx fails the bridged gate" 1; }
cat > "$TSWORK/app/page.tsx" <<'TSX'
export default function Home() {
  return <main>BI3: this sprint edit was gated by a real next build.</main>;
}
TSX
OUT=$(LOOM_WORKSPACE="$WS" ${LEX:-lex} run --allow-effects "$EFFECTS" src/agent/runner.lex verify_compiles_at '""' '"ts_build"' '"nextco/iter-1"' 2>&1 || true)
echo "$OUT" | grep -q '"\$variant":"Ok"' && check "valid nested page.tsx passes the bridged gate" 0 || { echo "$OUT" | tail -5 | sed 's/^/   | /'; check "valid nested page.tsx passes the bridged gate" 1; }
rm -rf "$TSWORK"

echo
echo "== BI3 roundtrip: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
