#!/usr/bin/env bash
# bi1-rn-expo-web-roundtrip.sh — live proof of the bootstrap-install golden
# path (#256). UNLIKE the other roundtrip demos this one NEEDS THE NETWORK
# (npm registry): the whole point of the weight class is that the ONE
# install happens at bootstrap. It therefore runs in its own CI job, not
# demo-smoke.
#
#   1. bootstrap-install — bootstrapping a company on [stack].path =
#      "rn-expo-web" runs the skeleton's .loom-install (npm ci) once in the
#      scaffolded workspace and writes the .loom-installed marker;
#      re-bootstrapping the same company SKIPS the install (marker), so a
#      live company is never silently re-installed.
#   2. the build is real — `npm run build` (expo export --platform web) in
#      the workspace produces dist/ with the RN web bundle.
#   3. launch story — the builtins server boots on an arbitrary PORT and
#      serves the RN shell, the JS bundle, /health, and the /loom/*
#      surface (publish + blog parity), same as every other path.
#
# Run from the repo root:  bash demo/bi1-rn-expo-web-roundtrip.sh
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

echo "== BI1: rn-expo-web bootstrap-install roundtrip (node $(node --version)) =="

WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-bi1-demo.XXXXXX")"
trap 'kill "$(cat "$WS/srv.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$WS"' EXIT

cat > "$WS/company.toml" <<TOML
[identity]
id = "rnwebco"
name = "RN Web Co"
mission = "Prove the bootstrap-install golden path end to end."

[stack]
path = "rn-expo-web"

[policy]
max_iterations = 1
TOML

echo
echo "-- 1. bootstrap runs the one-time install"
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)" && rc=0 || rc=1
echo "$BOOT" | grep -E "one-time|skeleton" | sed 's/^/   | /'
check "bootstrap succeeds" "$rc"
DIR="$WS/rnwebco"
[ -f "$DIR/.loom-installed" ] && check ".loom-installed marker written" 0 || check ".loom-installed marker written" 1
[ -d "$DIR/node_modules/expo" ] && check "dependencies actually installed (node_modules/expo)" 0 || check "dependencies actually installed (node_modules/expo)" 1

echo
echo "-- 2. re-bootstrap skips the install (marker)"
BOOT2="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)" && rc=0 || rc=1
echo "$BOOT2" | grep -q "skipping one-time install" && check "re-bootstrap skips install" 0 || check "re-bootstrap skips install" 1

echo
echo "-- 3. the workspace build is real (expo export --platform web)"
(cd "$DIR" && EXPO_NO_TELEMETRY=1 npm run build > "$WS/build.log" 2>&1) && rc=0 || rc=1
check "npm run build produces the web export" "$rc"
[ -f "$DIR/dist/index.html" ] && check "dist/index.html exists" 0 || check "dist/index.html exists" 1

echo
echo "-- 4. launch story: boot + curl shell, bundle, /loom surface"
PORT=8186
(cd "$DIR" && PORT=$PORT node --experimental-strip-types server.ts >"$WS/srv.log" 2>&1 & echo $! > "$WS/srv.pid")
for i in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.25
done
health=$(curl -sf "http://127.0.0.1:$PORT/health" || echo MISS)
echo "   | /health → $health"
[ "$health" = '{"ok":true}' ] && check "/health answers on PORT=$PORT" 0 || check "/health answers on PORT=$PORT" 1
curl -sf "http://127.0.0.1:$PORT/" | grep -q "<title>rn-expo-web</title>" && check "RN shell serves" 0 || check "RN shell serves" 1
BUNDLE=$(ls "$DIR/dist/_expo/static/js/web" | head -1)
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/_expo/static/js/web/$BUNDLE")
[ "$code" = "200" ] && check "RN JS bundle serves (200)" 0 || check "RN JS bundle serves (200)" 1
publish=$(curl -sf -X POST "http://127.0.0.1:$PORT/loom/content" -H 'content-type: application/json' -d '{"title":"BI1","body":"Installed once, at bootstrap."}' || echo MISS)
echo "$publish" | grep -q '"ok":true' && check "content publishes" 0 || check "content publishes" 1

echo
echo "== BI1 roundtrip: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
