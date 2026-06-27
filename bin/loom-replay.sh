#!/usr/bin/env bash
# loom-replay.sh — replay a sprint's latest native trace (#7), optionally
# overriding a node's effect output.
#
# Usage:
#   SPRINT_ID=my-sprint bin/loom-replay.sh
#   SPRINT_ID=my-sprint bin/loom-replay.sh --override n_0.1.2='{"$variant":"Ok","args":["..."]}'
#
# Looks up the run_id linked by bin/loom-traced.sh, then runs
#   lex replay <run_id> src/main.lex run_sprint_cmd [--override ...]
#
# Find NodeIds to override with:  lex trace <run_id>
set -euo pipefail

cd "$(dirname "$0")/.."

SPRINT_ID="${SPRINT_ID:-sprint-1}"
EFFECTS=env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs

# sprint_run prints the run_id, then lex prints the Unit return as `null`;
# drop blanks/null and take the first real line. Full effect row: whole-program check.
run_id="$(SPRINT_ID="$SPRINT_ID" lex run --allow-effects "$EFFECTS" \
  src/main.lex sprint_run 2>/dev/null | grep -vE '^(null)?$' | head -1)"

if [ -z "$run_id" ]; then
  echo "[loom-replay] no native run linked for sprint '$SPRINT_ID' — run bin/loom-traced.sh first" >&2
  exit 1
fi

echo "[loom-replay] replaying sprint '$SPRINT_ID' from native run $run_id" >&2
exec lex replay "$run_id" --max-steps "${MAX_STEPS:-500000000}" --allow-effects "$EFFECTS" \
  src/main.lex run_sprint_cmd "$@"
