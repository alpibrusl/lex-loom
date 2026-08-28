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
# instead of in-process, executed by WORKER_COUNT (default 1) separate
# `worker.lex::run_worker` processes this script launches, monitors, and
# tears down on exit — so a company's long-running, unattended build phase
# survives an individual worker crashing (reclaim_stale requeues its
# orphaned job for another worker) instead of taking the whole run down
# with it. Set EXEC_MODE=inline to go back to the old single-process
# in-process fan-out (no workers launched). Note the deliberate divergence
# (#242): loom-scheduler.sh defaults EXEC_MODE=inline because the daemon
# owns many companies and launches no workers of its own; this script owns
# ONE company and manages its workers' whole lifecycle, so queue is safe
# to default here.
#
# WORKER_COUNT > 1 is supported since HB3 (lex-loom#215): loom is
# SQLite-only, where lex-jobs' single-statement claim is atomic under the
# database write lock — the race its README warns about is Postgres-only.
# If loom ever grows a Postgres path, re-gate multi-worker until lex-jobs
# ships SELECT...FOR UPDATE SKIP LOCKED.
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
: "${MODEL:=qwen3.8:27b-mlx}"  # keep in sync with src/defaults.lex (the one place the fallback model lives)
: "${MAX_ITERATIONS:=3}"
: "${STOP_WHEN:=}"
: "${MAX_API_CALLS:=200}"
: "${DB_PATH:=company-${COMPANY_ID}.db}"
: "${GOAL:=Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.}"
: "${EXEC_MODE:=queue}"
: "${WORKER_COUNT:=1}"
: "${POLL_MS:=500}"
: "${RECLAIM_LEASE_SECONDS:=300}"
# Optional, read-only (#160): a human-configured endpoint returning
# {"revenue_cents": N} from whatever payment rail they actually use. loom
# never touches a payment rail itself -- unset means no real economics
# signal is tracked, not that revenue is zero.
: "${REVENUE_URL:=}"
# Optional, declarative-only for now (SA1, lex-loom#178): the company's
# [soft] mesh identity. Nothing reads or dials out to it yet -- it's stored
# and shown in board_report so SA2 (registering a role in soft's mesh) has
# a real declarative surface to build on. Unset means "not soft-aware".
: "${SOFT_MESH_URL:=}"
: "${SOFT_ORG_ID:=}"
: "${SOFT_ROLES:=}"
: "${SOFT_SETTLEMENT:=}"
: "${POLICY_ISOLATION:=}"
# ORG1 (lex-loom#216): "child:parent,..." reporting lines from [org]; empty
# means flat (exactly the pre-ORG1 behavior). An invalid spec aborts the
# launch inside run_company_cmd -- refuse, don't downgrade.
: "${ORG_EDGES:=}"
: "${ROLE_PACKS:=}"
: "${MODEL_OVERRIDES:=}"
: "${BUDGET_ENVELOPES:=}"

export COMPANY_ID MODEL MAX_ITERATIONS STOP_WHEN MAX_API_CALLS DB_PATH GOAL EXEC_MODE POLL_MS RECLAIM_LEASE_SECONDS REVENUE_URL SOFT_MESH_URL SOFT_ORG_ID SOFT_ROLES SOFT_SETTLEMENT POLICY_ISOLATION ORG_EDGES ROLE_PACKS BUDGET_ENVELOPES MODEL_OVERRIDES

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

# HB3 (lex-loom#215): WORKER_COUNT > 1 is supported. loom is SQLite-only,
# where lex-jobs' single-statement claim (UPDATE ... WHERE id=(SELECT ...)
# RETURNING) is atomic under the database write lock — two workers can never
# own the same job (proven under contention in tests/test_concurrency.lex;
# the old #197 refusal guarded against a race that is Postgres-specific).
# Each worker gets a stable WORKER_ID so trail events attribute per worker.

if [ "$EXEC_MODE" = "queue" ]; then
  echo "[run-company] EXEC_MODE=queue: launching $WORKER_COUNT worker process(es), logs in $WORKER_LOG_DIR"
  for i in $(seq 1 "$WORKER_COUNT"); do
    WORKER_ID="w$i" lex run --max-steps 0 \
      --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval \
      src/worker.lex run_worker > "$WORKER_LOG_DIR/worker-$i.log" 2>&1 &
    WORKER_PIDS+=("$!")
  done
  echo "[run-company] worker pids: ${WORKER_PIDS[*]}"
  sleep 1
fi

echo "[run-company] id=$COMPANY_ID model=$MODEL max_iterations=$MAX_ITERATIONS stop_when='${STOP_WHEN}' db=$DB_PATH exec_mode=$EXEC_MODE"
lex run --max-steps 0 \
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval \
  src/main.lex run_company_cmd

echo
echo "[run-company] iterations recorded:"
sqlite3 "$DB_PATH" \
  "SELECT idx, sprint_id, parent_sprint_id, status FROM company_iterations ORDER BY idx;" 2>/dev/null \
  || echo "  (sqlite3 not available — inspect $DB_PATH manually)"
