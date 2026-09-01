#!/usr/bin/env bash
# gp2-web-pwa-roundtrip.sh — live proof of the web-pwa golden path (#92),
# fully offline (no LLM, no network, no npm install, no framework):
#
#   1. skeleton — paths/web-pwa runs its own test suite green on node:*
#      builtins alone, exactly as a freshly bootstrapped company would.
#   2. installable shell — the app boots on an arbitrary PORT and serves
#      the three pieces a browser needs to offer "install": the shell
#      (index.html linking the manifest), the manifest (valid JSON,
#      standalone display, icons, served as application/manifest+json),
#      and the service worker (cache-first shell, referenced by the
#      client script). Plus the standard /health and /loom/* surface.
#   3. one-tool project write — ts_check accepts the WHOLE project
#      (TS server syntax-checked, manifest parse-checked, css stored)
#      and still refuses bad code and bad JSON — proven by the real
#      gate tests (tests/test_ts_path.lex).
#
# Run from the repo root:  bash demo/gp2-web-pwa-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"

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

echo "== GP2: web-pwa golden path roundtrip (node $(node --version)) =="

echo
echo "-- 1. skeleton test suite (node:* builtins only)"
out=$( (cd paths/web-pwa && node --experimental-strip-types --test tests/*.test.ts) 2>&1 ) && rc=0 || rc=1
echo "$out" | grep -E "^# (tests|pass|fail)" | sed 's/^/   | /'
check "skeleton suite runs" "$rc"
echo "$out" | grep -q "^# fail 0" && check "0 failing skeleton tests" 0 || check "0 failing skeleton tests" 1

echo
echo "-- 2. installable shell: boot + curl the PWA pieces"
PORT=8184
SRV_LOG=$(mktemp "${TMPDIR:-/tmp}/gp2-server.XXXXXX.log")
(cd paths/web-pwa && PORT=$PORT node --experimental-strip-types app.ts >"$SRV_LOG" 2>&1 & echo $! > "${SRV_LOG}.pid")
trap 'kill "$(cat "${SRV_LOG}.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.25
done

health=$(curl -sf "http://127.0.0.1:$PORT/health" || echo MISS)
echo "   | /health → $health"
[ "$health" = '{"ok":true}' ] && check "/health answers on PORT=$PORT" 0 || check "/health answers on PORT=$PORT" 1

shell=$(curl -sf "http://127.0.0.1:$PORT/" || echo MISS)
echo "$shell" | grep -q 'rel="manifest"' && check "shell links the manifest" 0 || check "shell links the manifest" 1

mtype=$(curl -sf -o /dev/null -w "%{content_type}" "http://127.0.0.1:$PORT/manifest.webmanifest" || echo MISS)
echo "   | manifest content-type → $mtype"
[ "$mtype" = "application/manifest+json" ] && check "manifest served with manifest+json type" 0 || check "manifest served with manifest+json type" 1
curl -sf "http://127.0.0.1:$PORT/manifest.webmanifest" | grep -q '"display": "standalone"' && check "manifest declares standalone display" 0 || check "manifest declares standalone display" 1

sw=$(curl -sf "http://127.0.0.1:$PORT/sw.js" || echo MISS)
echo "$sw" | grep -q "caches.open" && check "service worker caches the shell" 0 || check "service worker caches the shell" 1

publish=$(curl -sf -X POST "http://127.0.0.1:$PORT/loom/content" -H 'content-type: application/json' -d '{"title":"GP2","body":"Installable from a URL."}' || echo MISS)
echo "$publish" | grep -q '"ok":true' && check "content publishes" 0 || check "content publishes" 1

echo
echo "-- 3. one-tool project write: ts_check dispatch + compiles gate (real gate tests)"
out=$(${LEX:-lex} run --max-steps 0 --allow-effects "$EFFECTS" tests/test_ts_path.lex run_all 2>&1) && rc=0 || rc=1
echo "$out" | sed 's/^/   | /'
fails=$(echo "$out" | tail -1)
[ "$rc" = "0" ] && [ "$fails" = "0" ] && check "gate + dispatch tests (0 failing checks)" 0 || check "gate + dispatch tests (0 failing checks)" 1

echo
echo "== GP2 roundtrip: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
