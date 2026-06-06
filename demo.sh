#!/usr/bin/env bash
# demo.sh — one-command lex-loom demo
#
# Usage:
#   bash demo.sh                     # Ollama (local, no API key needed)
#   ANTHROPIC_API_KEY=sk-... bash demo.sh   # Anthropic (faster, better output)
#
# What it does:
#   1. Starts lex-loom + Ollama via docker compose
#   2. Waits for the stack to be ready
#   3. Opens the dashboard in your browser
#   4. Runs a demo sprint: OCPP BootNotification pure Lex module
#   5. Streams phase + trail events to the terminal while the browser shows live progress

set -euo pipefail

LOOM_URL="http://localhost:8880"
SPRINT_ID="ocpp-boot-demo"
MODEL="${MODEL:-gemma4:latest}"
REQUEST='Write a pure Lex module `boot_notification.lex` that: (1) defines a BootNotificationRequest record with chargePointVendor, chargePointModel, chargePointSerialNumber, and firmwareVersion Str fields; (2) defines a BootNotificationResponse record with status (one of "Accepted", "Pending", "Rejected") and currentTime Str fields; (3) a pure `parse_request` function that takes a JSON string and returns Option[BootNotificationRequest] — include examples{} blocks; (4) a pure `format_response` function that takes a BootNotificationResponse and returns a JSON string — include examples{} blocks. No effects — pure module only.'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

banner() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }

# ── 1. Check deps ─────────────────────────────────────────────────────────────
banner "Checking dependencies"
for cmd in docker curl; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "$cmd not found — please install it first"
    exit 1
  fi
done
ok "docker and curl available"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODEL="claude-sonnet-4-6"
  ok "Using Anthropic (claude-sonnet-4-6)"
else
  ok "Using Ollama (gemma4:latest) — no API key needed"
  warn "First run pulls ~5 GB model; subsequent runs are fast"
fi

# ── 2. Start stack ────────────────────────────────────────────────────────────
banner "Starting lex-loom stack"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" docker compose up -d --build
else
  docker compose up -d --build
fi
ok "Stack starting (docker compose up)"

# ── 3. Wait for lex-loom to be ready ─────────────────────────────────────────
banner "Waiting for lex-loom to be ready"
ATTEMPTS=0
MAX=60
until curl -sf "$LOOM_URL/" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [ "$ATTEMPTS" -ge "$MAX" ]; then
    fail "lex-loom did not start after ${MAX} attempts"
    echo "  Check logs: docker compose logs lex-loom"
    exit 1
  fi
  printf "  waiting... (%d/%d)\r" "$ATTEMPTS" "$MAX"
  sleep 5
done
echo ""
ok "lex-loom ready at $LOOM_URL"

# ── 4. Open browser ───────────────────────────────────────────────────────────
banner "Opening dashboard"
if command -v open &>/dev/null; then
  open "$LOOM_URL"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$LOOM_URL"
else
  warn "Open your browser at: $LOOM_URL"
fi
ok "Dashboard: $LOOM_URL"

# ── 5. Launch demo sprint ─────────────────────────────────────────────────────
banner "Launching demo sprint: $SPRINT_ID"
echo -e "  ${BOLD}Request:${NC} OCPP BootNotification pure Lex module"
echo -e "  ${BOLD}Model:${NC}   $MODEL"
echo ""

PAYLOAD=$(printf '{"sprint_id":"%s","request":%s,"model":"%s","max_api_calls":200}' \
  "$SPRINT_ID" \
  "$(echo "$REQUEST" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  "$MODEL")

# Fire the sprint in background and poll in parallel
curl -sf -X POST "$LOOM_URL/api/sprints" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  > /tmp/loom-sprint-result.json &
SPRINT_PID=$!

# ── 6. Poll trail while sprint runs ──────────────────────────────────────────
echo -e "  ${YELLOW}Polling audit trail (Ctrl-C to stop watching, sprint continues in browser)${NC}"
echo ""

LAST_EVENT_COUNT=0
while kill -0 "$SPRINT_PID" 2>/dev/null; do
  TRAIL=$(curl -sf "$LOOM_URL/api/sprints/$SPRINT_ID/trail" 2>/dev/null || echo '{"events":[]}')
  COUNT=$(echo "$TRAIL" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("events",[])))' 2>/dev/null || echo "0")

  if [ "$COUNT" -gt "$LAST_EVENT_COUNT" ]; then
    # Print new events
    echo "$TRAIL" | python3 -c "
import json, sys
d = json.load(sys.stdin)
events = d.get('events', [])
start = $LAST_EVENT_COUNT
for e in events[start:]:
    kind = e.get('event_kind','')
    data = e.get('data_json','{}')
    try:
        d2 = json.loads(data)
        parts = [f\"{k}={v}\" for k,v in d2.items() if k not in ('content',)]
        data_str = '  '.join(parts[:4])
    except:
        data_str = data[:80]
    icon = '✓' if 'accepted' in kind or 'validated' in kind or 'complete' in kind else ('✗' if 'denied' in kind or 'failed' in kind else '·')
    print(f'  {icon}  {kind:<22}  {data_str}')
" 2>/dev/null || true
    LAST_EVENT_COUNT=$COUNT
  fi
  sleep 3
done

wait "$SPRINT_PID" || true

# ── 7. Result ─────────────────────────────────────────────────────────────────
echo ""
if [ -f /tmp/loom-sprint-result.json ]; then
  SUCCESS=$(python3 -c "import json; d=json.load(open('/tmp/loom-sprint-result.json')); print(d.get('success','false'))" 2>/dev/null || echo "false")
  SUMMARY=$(python3 -c "import json; d=json.load(open('/tmp/loom-sprint-result.json')); print(d.get('summary',''))" 2>/dev/null || echo "")
  if [ "$SUCCESS" = "True" ] || [ "$SUCCESS" = "true" ]; then
    ok "${BOLD}Sprint complete:${NC} $SUMMARY"
    echo ""
    echo -e "  ${BOLD}Dashboard:${NC}  $LOOM_URL"
    echo -e "  ${BOLD}Trail:${NC}      $LOOM_URL/api/sprints/$SPRINT_ID/trail"
    echo -e "  ${BOLD}Digest:${NC}     $LOOM_URL/api/sprints/$SPRINT_ID/digest"
    echo ""
    echo -e "  ${GREEN}Click any artifact hash in the graph to read the generated code.${NC}"
    echo -e "  ${GREEN}Run Sprint 2 in the browser — the Digest seeds the next sprint.${NC}"
  else
    fail "Sprint failed: $SUMMARY"
    echo "  Check: docker compose logs lex-loom"
  fi
fi

echo ""
echo -e "  Stop the stack: ${BOLD}docker compose down${NC}"
echo ""
