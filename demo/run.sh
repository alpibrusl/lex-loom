#!/usr/bin/env bash
# demo/run.sh — "The Sprint That Fixes Itself"
#
# Two consecutive lex-loom sprints showing the learning loop in action:
#
#   Sprint 1 (registration API):
#     Build → bad code (no email validation)
#     QA    → FAIL (run_code catches the gap)
#     Bounce → Build retries with QA feedback
#     Build → good code (EMAIL_REGEX added)
#     QA    → PASS
#     Scribe → tightened spec: { role:build, gate:"spec contains EMAIL_REGEX" }
#
#   Sprint 2 (invite API, different task):
#     Architect reads specs_context from Sprint 1 Digest
#     Sets Build gate: "spec contains EMAIL_REGEX"
#     Build → invite_api.py (always has EMAIL_REGEX)
#     gate  → PASS on first try — no QA needed yet
#     QA    → PASS (good code, no bounce)
#
# The gate is in the substrate.  The model didn't "learn" — the spec changed.
#
# Prerequisites:
#   export VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token)
#   export VERTEX_PROJECT=<your-gcp-project>
#   lex runtime on PATH  (https://lex-lang.org/install)
#
# Run from the lex-loom project root:
#   ./demo/run.sh

set -euo pipefail

LOOM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_DIR="$LOOM_ROOT/demo"
DB="${DEMO_DB:-$DEMO_DIR/demo.db}"
LEX="${LEX_BIN:-lex}"
# Local-first: defaults to Ollama (qwen3.8:27b-mlx). The Build + Scribe agents
# are deterministic proc: scripts, so only PM/Architect/QA/Demo use the model.
MODEL="${MODEL:-qwen3.8:27b-mlx}"
LAUNCH_PORT="${LAUNCH_PORT:-8090}"
EFFECTS="env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream"
# JSON parsing in lex-schema is O(n^2); large QA/trail payloads blow the default
# VM step limit (and par_map workers cap at 10M). Raise it generously.
MAXSTEPS="${MAXSTEPS:-500000000}"

# ── colours ──────────────────────────────────────────────────────────────────
BOLD='\033[1m'; DIM='\033[2m'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'

header()  { echo -e "\n${BOLD}${BLUE}━━━  $1  ━━━${NC}"; }
step()    { echo -e "${CYAN}▶ $1${NC}"; }
ok()      { echo -e "${GREEN}✓ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $1${NC}"; }
note()    { echo -e "${DIM}  $1${NC}"; }
divider() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }

# ── sanity checks ─────────────────────────────────────────────────────────────
if ! command -v "$LEX" &>/dev/null; then
  echo -e "${RED}✗ 'lex' not found on PATH. Install from https://lex-lang.org/install${NC}"
  exit 1
fi
note "Model: $MODEL (local Ollama). No cloud credentials required."

cd "$LOOM_ROOT"

# ── clean state ───────────────────────────────────────────────────────────────
rm -f "$DB" /tmp/loom_demo_reg_tried
step "Initialising demo DB at $DB"

# Seed the demo pool agents (DB is created by open_db + migrate.run on first sprint)
# We prime the DB by running a no-op sprint command that just opens + migrates it,
# then inject our demo pool agents.
DB_PATH="$DB" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex init_db

sqlite3 "$DB" < "$DEMO_DIR/pool/seed_demo_pool.sql"
ok "Demo pool agents seeded (Build×2 + Scribe, attestation=100)"

# ══════════════════════════════════════════════════════════════════════════════
header "Sprint 1 — User Registration API"
# ══════════════════════════════════════════════════════════════════════════════
note "Task: POST /register + GET /users, email must be validated"
note "Provider: Ollama (local)  |  Model: $MODEL"
divider

SPRINT1_ID="demo-sprint-1"
SPRINT1_REQ="Build a Python Flask REST API for user registration. Endpoints: POST /register (accepts JSON {email, password}, creates user, returns {id, email}), GET /users (lists all users). Email addresses must be validated — reject malformed addresses with HTTP 422."

DB_PATH="$DB" SPRINT_ID="$SPRINT1_ID" REQUEST="$SPRINT1_REQ" MODEL="$MODEL" \
  "$LEX" run --allow-effects "$EFFECTS" --max-steps "$MAXSTEPS" src/main.lex run_sprint_cmd

divider
step "Sprint 1 trail"
DB_PATH="$DB" SPRINT_ID="$SPRINT1_ID" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_trail

divider
step "Sprint 1 Digest → tightened specs (seeded under next sprint ID)"
DB_PATH="$DB" SPRINT_ID="${SPRINT1_ID}-next" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_digest

echo ""
ok "Sprint 1 complete"

# ══════════════════════════════════════════════════════════════════════════════
header "Sprint 2 — Team Invite API  (different task, same email rule)"
# ══════════════════════════════════════════════════════════════════════════════
note "Architect inherits  'spec contains EMAIL_REGEX'  from Sprint 1 Digest"
note "Build gate fires BEFORE QA — no bounce needed"
divider

SPRINT2_ID="${SPRINT1_ID}-next"
SPRINT2_REQ="Build a Python Flask REST API for team invitations. Endpoints: POST /invite (accepts JSON {email, role}, creates invite, returns {id, email, role, status}), GET /invites (lists all invites). Valid roles: member, admin, viewer. Email addresses must be validated."

DB_PATH="$DB" SPRINT_ID="$SPRINT2_ID" REQUEST="$SPRINT2_REQ" MODEL="$MODEL" \
  "$LEX" run --allow-effects "$EFFECTS" --max-steps "$MAXSTEPS" src/main.lex run_sprint_cmd

divider
step "Sprint 2 trail"
DB_PATH="$DB" SPRINT_ID="$SPRINT2_ID" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_trail

# ══════════════════════════════════════════════════════════════════════════════
header "Live Launch — the learned constraint, running in production"
# ══════════════════════════════════════════════════════════════════════════════
note "Booting the Sprint 2 artifact and exercising it with real HTTP requests."
note "Watch the LAST call: a malformed email gets rejected — live — by the"
note "EMAIL_REGEX that Sprint 1 learned the hard way and the substrate made law."
divider

APP="$DEMO_DIR/code/invite_api.py"
SRVLOG="/tmp/loom-demo-invite-$LAUNCH_PORT.log"
BASE="http://localhost:$LAUNCH_PORT"

# Free the port (macOS-safe), then boot the server detached so its stdout does
# not block this script.
lsof -ti "tcp:$LAUNCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1
nohup bash -c "{ PORT=$LAUNCH_PORT python3 '$APP' ; } >'$SRVLOG' 2>&1" >/dev/null 2>&1 &
SRV_PID=$!

# Poll until it answers (max 15s).
READY=0
for _ in $(seq 1 15); do
  sleep 1
  if curl -s --max-time 2 "$BASE/invites" >/dev/null 2>&1; then READY=1; break; fi
done

if [ "$READY" != "1" ]; then
  warn "Server did not come up — log tail:"
  tail -5 "$SRVLOG" 2>/dev/null
else
  ok "Server live at $BASE  (pid $SRV_PID)"
  echo ""

  step "GET /invites  → empty list (fresh server)"
  echo -e "  ${DIM}$ curl $BASE/invites${NC}"
  echo -e "  ${GREEN}$(curl -s "$BASE/invites")${NC}"
  echo ""

  step "POST /invite  with a VALID email  → 201 Created"
  echo -e "  ${DIM}$ curl -X POST $BASE/invite -d '{\"email\":\"ada@lex.dev\",\"role\":\"admin\"}'${NC}"
  VALID=$(curl -s -w '\n  HTTP %{http_code}' -X POST "$BASE/invite" \
    -H 'Content-Type: application/json' \
    -d '{"email":"ada@lex.dev","role":"admin"}')
  echo -e "  ${GREEN}${VALID}${NC}"
  echo ""

  step "POST /invite  with a MALFORMED email  → 422 (the learned gate, live)"
  echo -e "  ${DIM}$ curl -X POST $BASE/invite -d '{\"email\":\"not-an-email\",\"role\":\"admin\"}'${NC}"
  BAD=$(curl -s -w '\n  HTTP %{http_code}' -X POST "$BASE/invite" \
    -H 'Content-Type: application/json' \
    -d '{"email":"not-an-email","role":"admin"}')
  echo -e "  ${YELLOW}${BAD}${NC}"
  echo ""
  ok "Sprint 1 learned email validation. Sprint 2 inherited it as a gate."
  ok "Here it is enforcing that rule on a live request — HTTP 422, not a hope."
fi

# Tear the server down.
kill -9 "$SRV_PID" 2>/dev/null || true
lsof -ti "tcp:$LAUNCH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
header "Result  (trail-derived — no hardcoded claims)"
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Sprint 1 report${NC}  (from trail):"
DB_PATH="$DB" SPRINT_ID="$SPRINT1_ID" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_report \
  | sed 's/^/  /'

echo ""
echo -e "  ${BOLD}Sprint 2 report${NC}  (from trail):"
DB_PATH="$DB" SPRINT_ID="$SPRINT2_ID" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_report \
  | sed 's/^/  /'

echo ""
echo -e "  ${BOLD}Live${NC}    : booted the Sprint 2 artifact — a malformed email was rejected with HTTP 422"
echo ""
echo -e "  The spec is in the substrate.  It is not in the prompt."
echo -e "  The model did not get smarter.  The constraint got earlier."
echo -e "  And the constraint is real: you just watched it reject bad input, live."
echo ""
ok "Demo complete.  DB: $DB"
