#!/usr/bin/env bash
# probe-node.sh — measure ONE role's gate, N times, in minutes rather than hours.
#
# Every measurement in this repo has been a whole company run: three iterations,
# ~2.5 hours, dozens of nodes. So a question as narrow as "does the test author
# paste its expected values?" cost an afternoon and came back confounded with
# everything else that went wrong on the way. Nine runs in, the top failure had
# been the same single node's gate for three of them, and each candidate fix was
# checked by rebuilding the entire company around it.
#
# This runs the node through orch.run_phase — the same path a real node takes,
# including its gate, grounded verification and role contract — on a one-node
# graph. It is a probe that reuses the machinery, not a re-implementation of it,
# so a green here means what a green means in a sprint.
#
#   bin/probe-node.sh [N] [ROLE] [MODEL]
#   GATE=... TASK=... bin/probe-node.sh 10 py_test_author
set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-5}"
ROLE="${2:-py_test_author}"
MODEL="${3:-${MODEL:-qwen3.8:27b-mlx}}"
EFFECTS="env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream"

case "$ROLE" in
  py_test_author|test_author|ts_test_author)
    DEFAULT_GATE='spec sh "python3 $LOOM_ROOT/bin/check_derived_values.py ."' ;;
  py_build|build|ts_build) DEFAULT_GATE='spec compiles' ;;
  py_qa|qa|ts_qa)          DEFAULT_GATE='spec json-verdict-pass' ;;
  launch|deploy)           DEFAULT_GATE='spec json-ok-true' ;;
  *)                       DEFAULT_GATE='spec non-empty' ;;
esac
GATE="${GATE:-$DEFAULT_GATE}"
TASK="${TASK:-Write the tests for a POST /convert endpoint that converts a timestamp between IANA timezones and renders it as iso8601, rfc2822 or unix_epoch, rejecting an unknown timezone or format with HTTP 400.}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loom-probe.XXXXXX")"
RESULTS="$WORK/results.tsv"
echo "[probe] role=$ROLE attempts=$N model=$MODEL"
echo "[probe] gate=$GATE"
echo "[probe] logs in $WORK"
echo

for i in $(seq 1 "$N"); do
  SPRINT_ID="probe-$ROLE-$i"
  started=$(date +%s)
  OUT=$(DB_PATH="$WORK/attempt-$i.db" MODEL="$MODEL" ROLE="$ROLE" GATE="$GATE" \
        TASK="$TASK" SPRINT_ID="$SPRINT_ID" MAX_API_CALLS=60 \
        lex run --allow-effects "$EFFECTS" src/main.lex run_node_cmd 2>&1 | tee "$WORK/attempt-$i.log") || true
  elapsed=$(( $(date +%s) - started ))
  line=$(echo "$OUT" | grep '^\[probe\] role=' | tail -1 || true)
  if echo "$line" | grep -q ACCEPTED; then
    cls=accept; detail=""
  else
    cls=deny
    # NodeOutcome.reason is a generic label ("gate command failed"); the text
    # that says WHAT failed is the trail's `detail`. Reporting the label alone
    # gave "gate command failed: gate command failed:" and hid the actual cause
    # — the same discard-the-evidence defect this repo keeps finding in its own
    # gates, reproduced in the tool built to measure them.
    detail=$(sqlite3 "$WORK/attempt-$i.db" \
      "select coalesce(json_extract(data_json,'\$.detail'), json_extract(data_json,'\$.reason')) from traces where event_kind='node_denied' order by id desc limit 1;" 2>/dev/null \
      | tr '\n' ' ' | cut -c1-110)
    [ -z "$detail" ] && detail=$(echo "$line" | sed 's/.*reason=//' | cut -c1-110)
    if [ -z "$detail" ]; then
      if grep -q 'step limit exceeded' "$WORK/attempt-$i.log" 2>/dev/null; then
        detail="CRASH: step limit exceeded (large answer) — see attempt-$i.log"
      else
        detail="no verdict line — see $WORK/attempt-$i.log"
      fi
    fi
  fi
  printf '%s\t%s\t%ss\t%s\n' "$i" "$cls" "$elapsed" "$detail" >> "$RESULTS"
  printf '  [%d/%d] %-7s %4ss  %s\n' "$i" "$N" "$cls" "$elapsed" "$detail"
done

echo
a=$(awk -F'\t' '$2=="accept"{n++}END{print n+0}' "$RESULTS")
d=$(awk -F'\t' '$2=="deny"{n++}END{print n+0}' "$RESULTS")
echo "[probe] accept=$a  deny=$d  of $N"
[ "$N" -gt 0 ] && echo "[probe] accept rate: $a/$N ($(( a * 100 / N ))%)"
if [ "$d" -gt 0 ]; then
  echo
  echo "[probe] denial reasons:"
  awk -F'\t' '$2=="deny"{print "   " $4}' "$RESULTS" | sort | uniq -c | sort -rn
fi
echo
echo "[probe] per-attempt detail: $RESULTS"
