#!/usr/bin/env bash
# lw1-lex-web-path-roundtrip.sh -- the `lex-web-api` golden path, end to end
# and offline (no LLM): a manifest naming the path scaffolds the skeleton
# through bootstrap --no-run; the skeleton installs its deps, passes a strict
# check and its own lex-web testing-surface suite; booted on a port it
# answers /health, redirects a form POST that carries ?next, answers JSON
# without it, refuses a missing field with 400 and a 70 KB body with 413 --
# the shape check_abuse_controls.py will later drive against a real build.
#
# Run from the repo root:  bash demo/lw1-lex-web-path-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export MODEL="${MODEL:-qwen3.8:27b-mlx}"
E="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-lw1.XXXXXX")"; trap 'rm -rf "$WS"; [ -n "${SP:-}" ] && kill "$SP" 2>/dev/null || true' EXIT
pass=0; fail=0
free_port() { # first port in the range nothing else holds -- never kill a holder we did not start
  local p
  for p in "$@"; do lsof -ti :"$p" >/dev/null 2>&1 || { echo "$p"; return 0; }; done
  echo ""
}
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

say "1. a manifest on the lex-web-api path scaffolds the skeleton"
cat > "$WS/company.toml" <<TOML
[identity]
id = "lwco"
name = "Lex Web Co"
mission = "Prove the lex-web-api golden path."

[stack]
path  = "lex-web-api"
model = "$MODEL"

[policy]
max_iterations = 1
TOML
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)" || true
D="$WS/lwco"
[ -f "$D/main.lex" ] && [ -f "$D/tests/test_app.lex" ] && [ -f "$D/lex.toml" ] && [ -f "$D/Dockerfile" ] && ok "main.lex, tests, lex.toml and Dockerfile laid down" || bad "skeleton not scaffolded: $(echo "$BOOT" | tail -3)"
grep -q 'lex-web' "$D/lex.toml" && ok "lex.toml depends on lex-web" || bad "lex.toml lacks lex-web"
grep -q 'LEX_VERSION=0.11.13' "$D/Dockerfile" && ok "Dockerfile pins lex 0.11.13" || bad "Dockerfile pin wrong"

say "2. the skeleton compiles strictly and passes its own suite"
( cd "$D" && lex pkg install >/dev/null 2>&1 ) && ok "deps installed" || bad "lex pkg install failed"
( cd "$D" && lex check --strict main.lex >/dev/null 2>&1 && lex check --strict tests/test_app.lex >/dev/null 2>&1 ) && ok "strict check clean (examples evaluated)" || bad "strict check failed: $(cd "$D" && lex check --strict main.lex 2>&1 | head -2)"
OUT="$(cd "$D" && lex test --allow-effects "$E" tests 2>&1)" || true
echo "$OUT" | grep -q '1 passed, 0 failed' && ok "skeleton suite passes on lex-web's testing surface" || bad "suite failed: $OUT"

say "3. booted, it behaves like a public form endpoint should"
PORT="$(free_port 8098 8102 8103 8104)"
[ -z "$PORT" ] && { bad "no free port for the boot check"; } || {
  ( cd "$D" && PORT=$PORT lex run --allow-effects "$E" main.lex main > "$WS/server.log" 2>&1 ) & SP=$!
  for i in $(seq 1 40); do curl -s -m 1 "localhost:$PORT/health" >/dev/null 2>&1 && break; sleep 0.5; done
  [ "$(curl -s -m 3 localhost:$PORT/health)" = '{"ok":true}' ] && ok "/health answers {\"ok\":true}" || bad "/health: $(curl -s -m 3 localhost:$PORT/health)"
  R="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -m 3 -d 'name=Ada&email=ada%40example.eu' "localhost:$PORT/submit?next=/thanks")"
  [[ "$R" == "302 http://localhost:$PORT/thanks" ]] && ok "form POST with ?next redirects to it" || bad "redirect: $R"
  R="$(curl -s -m 3 -d 'name=Ada&email=ada%40example.eu' localhost:$PORT/submit)"
  [[ "$R" == *'"email":"ada@example.eu"'* ]] && ok "form POST without next answers JSON" || bad "json: $R"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 3 -d 'name=Ada' localhost:$PORT/submit)" = "400" ] && ok "missing email is a 400" || bad "missing email not refused"
  C="$(python3 -c 'print("email=a%40b.eu&pad="+"x"*70000)' | curl -s -o /dev/null -w '%{http_code}' -m 5 --data-binary @- -H 'content-type: application/x-www-form-urlencoded' localhost:$PORT/submit)"
  [ "$C" = "413" ] && ok "a 70 KB body is a 413 (body_limit middleware)" || bad "oversize: $C"
  kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null || true; SP=""
}

say "4. the launch node's own command boots it -- with the effect row loom tells the agent to use"
ROW="$(grep -o 'For Lex server: cmd=.*lex run --allow-effects [a-z,_]*' src/roles.lex | grep -o 'allow-effects [a-z,_]*' | cut -d' ' -f2)"
[ -n "$ROW" ] && ok "the launch prompt names an effect row" || bad "no Lex effect row found in the launch prompt"
PORT2="$(free_port 8088 8105 8106 8107)"
if [ -z "$PORT2" ]; then
  bad "no free port for the launch-row check"
else
  ( cd "$D" && PORT=$PORT2 lex run --allow-effects "$ROW" main.lex main > "$WS/launch-row.log" 2>&1 ) & SP=$!
  for i in $(seq 1 40); do curl -s -m 1 "localhost:$PORT2/health" >/dev/null 2>&1 && break; sleep 0.5; done
  # A Lex program needs the UNION of its imports' effects, and lex-web reaches
  # crypto/random inside its own request-id middleware: a short row lets the
  # process start and then fails every request, which reads as a dead endpoint
  # from a server that is plainly running. Found live on 2026-09-12, when the
  # prompt's row was env,io,time,net,sql,fs_read,fs_write,proc,concurrent.
  [ "$(curl -s -m 3 localhost:$PORT2/health)" = '{"ok":true}' ] && ok "the prompt's own row serves a real request" || bad "the launch prompt's row cannot serve this path: $(head -1 "$WS/launch-row.log")"
  [ "$(grep -c effect_not_allowed "$WS/launch-row.log")" = "0" ] && ok "no effect was refused under that row" || bad "$(grep -c effect_not_allowed "$WS/launch-row.log") effects refused under the launch prompt's row"
  kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null || true; SP=""
fi

printf '\n== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
