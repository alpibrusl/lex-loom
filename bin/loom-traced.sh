#!/usr/bin/env bash
# loom-traced.sh — run a sprint under native `lex run --trace` recording (#7),
# then link sprint_id → run_id so the run is inspectable/replayable later.
#
# Usage:
#   SPRINT_ID=my-sprint REQUEST='...' MODEL=qwen3-coder:30b bin/loom-traced.sh
#
# Env (same as main.lex run_sprint_cmd): DB_PATH, MODEL, REQUEST, SPRINT_ID,
#   MAX_API_CALLS, plus any feature flags (e.g. DYNAMIC_DAG=1).
#
# After it finishes:
#   lex trace  <run_id>                         # the full native trace tree
#   lex replay <run_id> src/main.lex run_sprint_cmd --override NODE=JSON
#   bin/loom-replay.sh                          # replays the latest run for SPRINT_ID
set -euo pipefail

cd "$(dirname "$0")/.."

SPRINT_ID="${SPRINT_ID:-sprint-1}"
EFFECTS=env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval
# A sprint is trusted first-party code, not the untrusted agent-tool sandbox the
# VM's opcode step-limit guards against — and node layers fan out via list.par_map
# whose workers inherit this limit (lex vm.rs). Run unbounded (--max-steps 0) so a
# node parsing a large model output can't spuriously trip "step limit exceeded".
# Override with MAX_STEPS env (e.g. a finite cap) if you want a ceiling.
MAX_STEPS="${MAX_STEPS:-0}"

# `trace saved: <run_id>` is printed to STDERR; tee it through so the user still
# sees live sprint output on stdout while we capture stderr for the run_id.
err_file="$(mktemp /tmp/loom-traced.XXXXXX)"
trap 'rm -f "$err_file"' EXIT

SPRINT_ID="$SPRINT_ID" lex run --trace --max-steps "$MAX_STEPS" --allow-effects "$EFFECTS" \
  src/main.lex run_sprint_cmd 2> >(tee "$err_file" >&2)

run_id="$(sed -n 's/^trace saved: //p' "$err_file" | tail -1)"
if [ -z "$run_id" ]; then
  echo "[loom-traced] WARNING: no 'trace saved:' line found — run_id not linked" >&2
  exit 0
fi

# main.lex is effect-checked whole-program, so any of its fns needs the full row.
SPRINT_ID="$SPRINT_ID" RUN_ID="$run_id" lex run --allow-effects "$EFFECTS" \
  src/main.lex link_native_run

echo "[loom-traced] inspect: lex trace $run_id" >&2
echo "[loom-traced] replay:  lex replay $run_id src/main.lex run_sprint_cmd --override NODE=JSON" >&2
