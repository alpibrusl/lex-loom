#!/usr/bin/env bash
# loom-scheduler.sh — the loom heartbeat (HB1, lex-loom#213): a long-lived
# process that owns the lifecycle of every company in $LOOM_WORKSPACE.
#
# Each tick it discovers <workspace>/<id>/company.db, classifies each company
# from its own persisted state (run / dormant / stopped / sunset /
# max_iterations), starts at most MAX_RUNS_PER_TICK runs through the exact
# same path bin/run-company.sh uses, and gives every company it did NOT run
# the between-run revenue/liveness monitor sweep so wake_when has fresh
# signals to fire against. All scheduler state lives in the company DBs —
# killing and restarting this process is always safe.
#
# Usage:
#   LOOM_WORKSPACE=~/loom-companies bin/loom-scheduler.sh          # forever
#   MAX_TICKS=1 TICK_MS=1000 bin/loom-scheduler.sh                 # one tick
#
# Environment:
#   LOOM_WORKSPACE    — where companies live       (default: ~/loom-companies)
#   TICK_MS           — sleep between ticks        (default: 60000)
#   EVENT_POLL_MS     — between-tick event poll    (default: 2000; 0 disables)
#                       HB2 (#214): an unconsumed event of a kind a company's
#                       wake_when opted into cuts the tick sleep short — a
#                       board note wakes a dormant company within seconds.
#   MAX_RUNS_PER_TICK — company runs per tick cap  (default: 1)
#   MAX_TICKS         — 0 = run forever            (default: 0)
#   MAX_API_CALLS     — per-run LLM budget         (default: 200)
#   EVOLVE            — strategist on/off          (default: 1)
#   EXEC_MODE         — "inline" (default here). The two entrypoints default
#                       DIFFERENTLY, on purpose (#242): run-company.sh runs
#                       ONE company and launches/tears down its own workers,
#                       so it defaults to "queue" (crash-surviving builds);
#                       this daemon owns MANY companies and launches no
#                       workers of its own, so it defaults to "inline"
#                       (in-process fan-out). Set EXEC_MODE=queue ONLY if
#                       you run `src/worker.lex run_worker` processes
#                       yourself against each company DB — since HB3,
#                       several workers per DB are safe.
#
# Provider keys: same as run-company.sh — set OPENCODE_API_KEY (or the usual
# provider keys); falls back to the credentials file, then Ollama.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$HOME/.credentials/opencode/key" ]; then
  OPENCODE_API_KEY="$(tr -d '\n' < "$HOME/.credentials/opencode/key")"
  export OPENCODE_API_KEY
fi

: "${LOOM_WORKSPACE:=$HOME/loom-companies}"
: "${TICK_MS:=60000}"
: "${EVENT_POLL_MS:=2000}"
: "${MAX_RUNS_PER_TICK:=1}"
: "${MAX_TICKS:=0}"
: "${MAX_API_CALLS:=200}"
: "${EVOLVE:=1}"
: "${EXEC_MODE:=inline}"

export LOOM_WORKSPACE TICK_MS EVENT_POLL_MS MAX_RUNS_PER_TICK MAX_TICKS MAX_API_CALLS EVOLVE EXEC_MODE

echo "[loom-scheduler] workspace=$LOOM_WORKSPACE tick_ms=$TICK_MS event_poll_ms=$EVENT_POLL_MS max_runs_per_tick=$MAX_RUNS_PER_TICK max_ticks=$MAX_TICKS exec_mode=$EXEC_MODE"
exec lex run --max-steps 0 \
  --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream \
  src/scheduler.lex run_scheduler
