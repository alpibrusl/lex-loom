#!/usr/bin/env bash
# smoke-health-sprint.sh — cheap, repeatable single-sprint probe (no company
# loop, no Strategist/PM-pack overhead) for exactly the scenario that stalled
# the pdfx2 company run: a minimal Lex /health route through build -> qa.
#
# Real company runs cost $50-150+ per attempt because every iteration re-runs
# the whole PM/Architect/content/devops/docs/security/demo/scribe pipeline
# even when the only open question is "does QA reliably ground its verdict
# and get the JSON shape right." This runs JUST that path (single sprint,
# no company/Strategist) directly via main.lex's run_sprint_cmd, N times in a
# row, so we can iterate on the qa/build prompts cheaply before spending real
# money on another full pdfx2 run.
#
# Usage:
#   bin/smoke-health-sprint.sh [N] [MODEL]
#
#   N       number of repeat attempts (default: 5)
#   MODEL   model name              (default: kimi-k2.7-code)
set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-5}"
MODEL="${2:-kimi-k2.7-code}"
EFFECTS=env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream
REQUEST='Build a minimal Lex HTTP server that compiles and responds to GET /health with HTTP 200 and a JSON body containing '"'"'status'"'"' and '"'"'privacy_note_url'"'"' fields. This is a standalone smoke test, not a full product -- no other routes, no x402 gating, no Python helper.'

WORKDIR="$(mktemp -d /tmp/loom-smoke-health.XXXXXX)"
echo "[smoke] workdir=$WORKDIR  attempts=$N  model=$MODEL"

pass=0
fail_ungrounded=0
fail_shape=0
fail_other=0

for i in $(seq 1 "$N"); do
  DB_PATH="$WORKDIR/attempt-$i.db"
  SPRINT_ID="smoke-health-$i"
  echo "=== attempt $i/$N ==="
  OUT=$(DB_PATH="$DB_PATH" MODEL="$MODEL" SPRINT_ID="$SPRINT_ID" REQUEST="$REQUEST" MAX_API_CALLS=40 \
    lex run --allow-effects "$EFFECTS" src/main.lex run_sprint_cmd 2>&1 | tee "$WORKDIR/attempt-$i.log")
  if echo "$OUT" | grep -q "\[loom\] SUCCESS"; then
    pass=$((pass + 1))
    echo "  -> PASS"
  else
    if echo "$OUT" | grep -qi "verdict not grounded"; then
      fail_ungrounded=$((fail_ungrounded + 1))
      echo "  -> FAIL (qa ungrounded: skipped run_code)"
    else
      if echo "$OUT" | grep -qi "verdict is 'FAIL'"; then
        fail_shape=$((fail_shape + 1))
        echo "  -> FAIL (qa ran, real shape/response mismatch)"
      else
        fail_other=$((fail_other + 1))
        echo "  -> FAIL (other -- see $WORKDIR/attempt-$i.log)"
      fi
    fi
  fi
done

echo ""
echo "[smoke] results over $N attempts: pass=$pass  ungrounded=$fail_ungrounded  shape-mismatch=$fail_shape  other=$fail_other"
echo "[smoke] logs + per-attempt DBs kept in $WORKDIR"
