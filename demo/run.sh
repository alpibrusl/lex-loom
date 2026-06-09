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
MODEL="${MODEL:-gemini-3.5-flash}"
EFFECTS="env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc"

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
if [[ -z "${VERTEX_ACCESS_TOKEN:-}" ]]; then
  warn "VERTEX_ACCESS_TOKEN not set — Ollama fallback will be used if available"
fi

cd "$LOOM_ROOT"

# ── clean state ───────────────────────────────────────────────────────────────
rm -f "$DB" /tmp/loom_demo_reg_tried
step "Initialising demo DB at $DB"

# Seed the demo pool agents (DB is created by open_db + migrate.run on first sprint)
# We prime the DB by running a no-op sprint command that just opens + migrates it,
# then inject our demo pool agents.
DB_PATH="$DB" SPRINT_ID="__init__" REQUEST="init" \
  "$LEX" run --allow-effects env,sql,fs_read,fs_write src/main.lex sprint_status 2>/dev/null || true

sqlite3 "$DB" < "$DEMO_DIR/pool/seed_demo_pool.sql"
ok "Demo pool agents seeded (Build×2 + Scribe, attestation=100)"

# ══════════════════════════════════════════════════════════════════════════════
header "Sprint 1 — User Registration API"
# ══════════════════════════════════════════════════════════════════════════════
note "Task: POST /register + GET /users, email must be validated"
note "Provider: Vertex AI  |  Model: $MODEL"
divider

SPRINT1_ID="demo-sprint-1"
SPRINT1_REQ="Build a Python Flask REST API for user registration. Endpoints: POST /register (accepts JSON {email, password}, creates user, returns {id, email}), GET /users (lists all users). Email addresses must be validated — reject malformed addresses with HTTP 422."

DB_PATH="$DB" SPRINT_ID="$SPRINT1_ID" REQUEST="$SPRINT1_REQ" MODEL="$MODEL" \
  VERTEX_ACCESS_TOKEN="${VERTEX_ACCESS_TOKEN:-}" VERTEX_PROJECT="${VERTEX_PROJECT:-}" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex run_sprint_cmd

divider
step "Sprint 1 trail"
DB_PATH="$DB" SPRINT_ID="$SPRINT1_ID" \
  "$LEX" run --allow-effects env,io,sql,fs_read src/main.lex sprint_trail

divider
step "Sprint 1 Digest → tightened specs (seeded under next sprint ID)"
DB_PATH="$DB" SPRINT_ID="${SPRINT1_ID}-next" \
  "$LEX" run --allow-effects env,io,sql,fs_read src/main.lex sprint_digest

echo ""
ok "Sprint 1 complete"
echo -e "  ${DIM}Key moment: QA bounced on missing email validation, Build retried, Digest"
echo -e "  encoded the lesson as gate  ${BOLD}spec contains EMAIL_REGEX${NC}${DIM}  for role=build${NC}"

# ══════════════════════════════════════════════════════════════════════════════
header "Sprint 2 — Team Invite API  (different task, same email rule)"
# ══════════════════════════════════════════════════════════════════════════════
note "Architect inherits  'spec contains EMAIL_REGEX'  from Sprint 1 Digest"
note "Build gate fires BEFORE QA — no bounce needed"
divider

SPRINT2_ID="${SPRINT1_ID}-next"
SPRINT2_REQ="Build a Python Flask REST API for team invitations. Endpoints: POST /invite (accepts JSON {email, role}, creates invite, returns {id, email, role, status}), GET /invites (lists all invites). Valid roles: member, admin, viewer. Email addresses must be validated."

DB_PATH="$DB" SPRINT_ID="$SPRINT2_ID" REQUEST="$SPRINT2_REQ" MODEL="$MODEL" \
  VERTEX_ACCESS_TOKEN="${VERTEX_ACCESS_TOKEN:-}" VERTEX_PROJECT="${VERTEX_PROJECT:-}" \
  "$LEX" run --allow-effects "$EFFECTS" src/main.lex run_sprint_cmd

divider
step "Sprint 2 trail"
DB_PATH="$DB" SPRINT_ID="$SPRINT2_ID" \
  "$LEX" run --allow-effects env,io,sql,fs_read src/main.lex sprint_trail

# ══════════════════════════════════════════════════════════════════════════════
header "Result"
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Sprint 1${NC}: QA bounced (missing email validation) → Build retried → Digest tightened gate"
echo -e "  ${BOLD}Sprint 2${NC}: Build gate ${BOLD}spec contains EMAIL_REGEX${NC} passed on attempt #1 — QA never had to catch it"
echo ""
echo -e "  The spec is in the substrate.  It is not in the prompt."
echo -e "  The model did not get smarter.  The constraint got earlier."
echo ""
ok "Demo complete.  DB: $DB"
