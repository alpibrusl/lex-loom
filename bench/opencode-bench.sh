#!/usr/bin/env bash
# bench/opencode-bench.sh — test OpenCode Go models on Lex + Python code generation
#
# Runs a minimal sprint (architect → build/py_build → qa/py_qa) for each model
# and reports: did it compile? did QA pass? how many bounces?
#
# Usage (direct):
#   OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) ./bench/opencode-bench.sh
#
# Usage (via LiteLLM — recommended, normalizes reasoning_content automatically):
#   cd litellm && OPENCODE_API_KEY=$(cat ~/.credentials/opencode/key) docker compose up -d && cd ..
#   LITELLM_BASE_URL=http://localhost:4000 ./bench/opencode-bench.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LEX="${LEX_BIN:-lex}"
KEY="${OPENCODE_API_KEY:-$(cat ~/.credentials/opencode/key 2>/dev/null)}"
# Route through LiteLLM if running, otherwise fall back to direct opencode-go
LITELLM_URL="${LITELLM_BASE_URL:-}"
EFFECTS="env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc"
MAXSTEPS="500000000"
BENCH_DIR="$(pwd)/bench/results"
mkdir -p "$BENCH_DIR"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

header() { echo -e "\n${BOLD}══ $* ══${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
dim()    { echo -e "  ${DIM}$*${NC}"; }

# Models to test (Go plan) — all run in thinking mode, tool_choice=auto required
MODELS=(
  "deepseek-v4-flash"
  "deepseek-v4-pro"
  "qwen3.7-max"
  "qwen3.7-plus"
  "qwen3.6-plus"
  "qwen3.5-plus"
  "kimi-k2.7"
  "kimi-k2.6"
  "minimax-m3"
  "minimax-m2.7"
  "glm-5.2"
  "glm-5.1"
  "mimo-v2.5-pro"
  "mimo-v2.5"
  "mimo-v2-pro"
  "mimo-v2-omni"
)

# Task — simple enough to be achievable, hard enough to need real Lex/Python knowledge
LEX_REQUEST="Write a Lex module called 'stats' with two functions:
  mean(xs :: List[Int]) -> Int   — returns the integer mean (sum/count), 0 for empty
  max_val(xs :: List[Int]) -> Int — returns the maximum value, 0 for empty
Import std.list and std.int. No side effects."

PY_REQUEST="Write a Python module stats.py with two functions:
  mean(xs: list[int]) -> int   — integer mean (sum//len), 0 for empty
  max_val(xs: list[int]) -> int — max value, 0 for empty
Add a __main__ block that prints mean([1,2,3]) and max_val([1,2,3])."

run_sprint() {
  local model="$1" task="$2" db="$3" sid="$4" req="$5"
  if [ -n "$LITELLM_URL" ]; then
    # Via LiteLLM — normalizes reasoning_content, retries, etc.
    LITELLM_BASE_URL="$LITELLM_URL" MODEL="$model" DB_PATH="$db" SPRINT_ID="$sid" REQUEST="$req" \
      "$LEX" run --allow-effects "$EFFECTS" --max-steps "$MAXSTEPS" src/main.lex run_sprint_cmd \
      >"$BENCH_DIR/${sid}.log" 2>&1
  else
    # Direct to OpenCode Go
    OPENCODE_API_KEY="$KEY" MODEL="$model" DB_PATH="$db" SPRINT_ID="$sid" REQUEST="$req" \
      "$LEX" run --allow-effects "$EFFECTS" --max-steps "$MAXSTEPS" src/main.lex run_sprint_cmd \
      >"$BENCH_DIR/${sid}.log" 2>&1
  fi
}

sprint_report() {
  local db="$1" sid="$2"
  OPENCODE_API_KEY="$KEY" DB_PATH="$db" SPRINT_ID="$sid" \
    "$LEX" run --allow-effects "$EFFECTS" src/main.lex sprint_report 2>/dev/null
}

echo ""
echo -e "${BOLD}OpenCode Go — model benchmark${NC}"
echo -e "${DIM}Task A: Lex stats module  |  Task B: Python stats module${NC}"
echo ""

RESULTS=()

for MODEL in "${MODELS[@]}"; do
  header "$MODEL"

  # ── Task A: Lex ──────────────────────────────────────────────────────────
  SID_LEX="bench-lex-${MODEL//\//-}-$(date +%s)"
  DB_LEX="$BENCH_DIR/${SID_LEX}.db"
  dim "Running Lex sprint…"
  START=$(date +%s)
  if run_sprint "$MODEL" "lex" "$DB_LEX" "$SID_LEX" "$LEX_REQUEST"; then
    END=$(date +%s)
    ELAPSED=$((END - START))
    REPORT=$(sprint_report "$DB_LEX" "$SID_LEX")
    OUTCOME=$(echo "$REPORT" | grep "Outcome:" | awk '{print $2}')
    ACCEPTED=$(echo "$REPORT" | grep "Nodes accepted:" | awk '{print $3}')
    BOUNCES=$(echo "$REPORT" | grep "QA pass attempt:" | sed 's/.*#\([0-9]*\).*/\1/')
    if [ "$OUTCOME" = "PASSED" ]; then
      ok "Lex: PASSED  (${ELAPSED}s, accepted=$ACCEPTED, QA attempt #${BOUNCES:-?})"
    else
      fail "Lex: FAILED  (${ELAPSED}s) — check $BENCH_DIR/${SID_LEX}.log"
    fi
  else
    fail "Lex: sprint crashed — check $BENCH_DIR/${SID_LEX}.log"
  fi

  # ── Task B: Python ───────────────────────────────────────────────────────
  SID_PY="bench-py-${MODEL//\//-}-$(date +%s)"
  DB_PY="$BENCH_DIR/${SID_PY}.db"
  dim "Running Python sprint…"
  START=$(date +%s)
  if run_sprint "$MODEL" "py" "$DB_PY" "$SID_PY" "$PY_REQUEST"; then
    END=$(date +%s)
    ELAPSED=$((END - START))
    REPORT=$(sprint_report "$DB_PY" "$SID_PY")
    OUTCOME=$(echo "$REPORT" | grep "Outcome:" | awk '{print $2}')
    ACCEPTED=$(echo "$REPORT" | grep "Nodes accepted:" | awk '{print $3}')
    BOUNCES=$(echo "$REPORT" | grep "QA pass attempt:" | sed 's/.*#\([0-9]*\).*/\1/')
    if [ "$OUTCOME" = "PASSED" ]; then
      ok "Python: PASSED  (${ELAPSED}s, accepted=$ACCEPTED, QA attempt #${BOUNCES:-?})"
    else
      fail "Python: FAILED  (${ELAPSED}s) — check $BENCH_DIR/${SID_PY}.log"
    fi
  else
    fail "Python: sprint crashed — check $BENCH_DIR/${SID_PY}.log"
  fi
done

echo ""
echo -e "${BOLD}Logs in $BENCH_DIR/${NC}"
