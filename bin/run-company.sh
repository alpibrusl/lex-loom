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
#
# EXEC_MODE=queue by default (#93): every sprint node runs via lex-jobs
# instead of in-process, executed by WORKER_COUNT (default 2) separate
# `worker.lex::run_worker` processes this script launches, monitors, and
# tears down on exit — so a company's long-running, unattended build phase
# survives an individual worker crashing (reclaim_stale requeues its
# orphaned job for another worker) instead of taking the whole run down
# with it. Set EXEC_MODE=inline to go back to the old single-process
# in-process fan-out (no workers launched).
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
: "${EXEC_MODE:=queue}"
: "${WORKER_COUNT:=2}"
: "${POLL_MS:=500}"
: "${RECLAIM_LEASE_SECONDS:=300}"
# Optional, read-only (#160): a human-configured endpoint returning
# {"revenue_cents": N} from whatever payment rail they actually use. loom
# never touches a payment rail itself -- unset means no real economics
# signal is tracked, not that revenue is zero.
: "${REVENUE_URL:=}"

export COMPANY_ID MODEL MAX_ITERATIONS STOP_WHEN MAX_API_CALLS DB_PATH GOAL EXEC_MODE POLL_MS RECLAIM_LEASE_SECONDS REVENUE_URL

WORKER_PIDS=()
WORKER_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loom-company-workers.XXXXXX")"

cleanup() {
  if [ "${#WORKER_PIDS[@]}" -gt 0 ]; then
    echo "[run-company] stopping ${#WORKER_PIDS[@]} worker process(es): ${WORKER_PIDS[*]}"
    kill "${WORKER_PIDS[@]}" 2>/dev/null || true
    wait "${WORKER_PIDS[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "$EXEC_MODE" = "queue" ]; then
  echo "[run-company] EXEC_MODE=queue: launching $WORKER_COUNT worker process(es), logs in $WORKER_LOG_DIR"
  for i in $(seq 1 "$WORKER_COUNT"); do
    lex run --max-steps 0 \
      --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
      src/worker.lex run_worker > "$WORKER_LOG_DIR/worker-$i.log" 2>&1 &
    WORKER_PIDS+=("$!")
  done
  echo "[run-company] worker pids: ${WORKER_PIDS[*]}"
  sleep 1
fi

echo "[run-company] id=$COMPANY_ID model=$MODEL max_iterations=$MAX_ITERATIONS stop_when='${STOP_WHEN}' db=$DB_PATH exec_mode=$EXEC_MODE"
lex run --max-steps 0 \
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
  src/main.lex run_company_cmd

echo
echo "[run-company] iterations recorded:"
sqlite3 "$DB_PATH" \
  "SELECT idx, sprint_id, parent_sprint_id, status FROM company_iterations ORDER BY idx;" 2>/dev/null \
  || echo "  (sqlite3 not available — inspect $DB_PATH manually)"
