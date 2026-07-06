#!/usr/bin/env bash
# run-company.sh — run a Loom Company: a persistent goal that produces a series
# of iterating looms (#53). Each iteration is a full sprint; learning (tightened
# specs + agent memory) carries forward; the loop stops on STOP_WHEN or
# MAX_ITERATIONS.
#
# Usage:
#   COMPANY_ID=acme MAX_ITERATIONS=3 \
#   GOAL='Build a Lex function ...' \
#   MODEL=deepseek-v4-pro bin/run-company.sh
#
# Condition DSL for STOP_WHEN (and node activate_when):
#   iter ge N | verdict-passed | verdict-failed | digest contains "..."
#   accepted ge N | bounced ge N | always | never
#
# Provider: set OPENCODE_API_KEY (+ optional OPENCODE_BASE_URL for a local proxy)
# to use OpenCode Go, or the usual provider keys; falls back to Ollama.
#
# Uses --max-steps 0 (unbounded): a real multi-agent build phase can exceed the
# lex VM's default 10M-step cap (par_map worker step limit), aborting a sprint
# mid-build with no code defect involved.
set -euo pipefail
cd "$(dirname "$0")/.."

# Fall back to the credentials file if the key isn't already in the environment —
# a missing key here causes every LLM call to silently return an empty answer
# (no error), which is easy to mistake for a provider outage.
if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$HOME/.credentials/opencode/key" ]; then
  OPENCODE_API_KEY="$(tr -d '\n' < "$HOME/.credentials/opencode/key")"
  export OPENCODE_API_KEY
fi

: "${COMPANY_ID:=acme}"
: "${MODEL:=gemma4:latest}"
: "${MAX_ITERATIONS:=3}"
: "${STOP_WHEN:=}"
: "${MAX_API_CALLS:=200}"
: "${DB_PATH:=company-${COMPANY_ID}.db}"
: "${GOAL:=Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.}"

export COMPANY_ID MODEL MAX_ITERATIONS STOP_WHEN MAX_API_CALLS DB_PATH GOAL

echo "[run-company] id=$COMPANY_ID model=$MODEL max_iterations=$MAX_ITERATIONS stop_when='${STOP_WHEN}' db=$DB_PATH"
lex run --max-steps 0 \
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
  src/main.lex run_company_cmd

echo
echo "[run-company] iterations recorded:"
sqlite3 "$DB_PATH" \
  "SELECT idx, sprint_id, parent_sprint_id, status FROM company_iterations ORDER BY idx;" 2>/dev/null \
  || echo "  (sqlite3 not available — inspect $DB_PATH manually)"
