#!/usr/bin/env bash
# eval-suite.sh — node-level accept rates against a stored baseline.
#
# Every quality claim in this project was made from whole-company runs, and
# nearly all were wrong: tzc6 → tzc7 → tzc8 read 18/2 → 13/4 → 10/4 while real
# defects were being fixed, each comparison carrying its own confound. A single
# run of a stochastic pipeline cannot separate a regression from variance.
#
# This measures one node at a time, N times, and compares against a recorded
# baseline — so "did that fix help?" is answered by a number rather than by
# memory of the last number.
#
#   bin/eval-suite.sh            measure and compare
#   bin/eval-suite.sh --update   accept current numbers as the baseline
#
# Env: MODEL, LOOM_PROVIDER / LITELLM_BASE_URL as usual; TOLERANCE (default 1)
# is how many samples a role may drop below baseline before it counts.
set -euo pipefail
cd "$(dirname "$0")/.."

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

MODEL="${MODEL:-qwen3.8:27b-mlx}"
TOLERANCE="${TOLERANCE:-1}"
SUITE=evals/suite.tsv
BASELINE=evals/baseline.tsv
mkdir -p evals/results

# A measurement taken while something else is using the GPU is not a
# measurement. This is not hypothetical: a provider comparison in this repo
# reported 1/4 versus 4/4 because curl experiments and container restarts were
# running alongside the probe. Re-run clean, it was 5/5 versus 5/5.
busy=$(ps -Ao command | grep -c '[l]ex run --max-steps 0' || true)
if [ "$busy" -gt 0 ]; then
  echo "a company run is in progress — its GPU load would confound every sample here." >&2
  echo "wait for it to finish, or stop it, then re-run." >&2
  exit 1
fi

PROVIDER="${LOOM_PROVIDER:-${LITELLM_BASE_URL:+litellm}}"
PROVIDER="${PROVIDER:-default}"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="evals/results/$STAMP.tsv"

{ echo "# model	$MODEL"
  echo "# provider	$PROVIDER"
  echo "# commit	$COMMIT"
  echo "# date	$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT"

# launch has nothing to launch unless a build is staged. Without this the role
# measures the fixture's absence rather than the role: an earlier launch probe
# scored 2/4 in an empty work dir, and the two "accepts" were a stale server
# from a previous attempt answering on the port.
stage_fixture() {
  case "$1" in
    launch|deploy)
      for i in $(seq 1 "$2"); do
        d="/tmp/loom-py-work-probe-$1-$i"
        mkdir -p "$d"
        cat > "$d/tzconvert.py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"service":"tzconvert"}')
    def log_message(self, *a): pass

HTTPServer(("", int(os.environ.get("PORT", "8081"))), H).serve_forever()
PY
      done ;;
  esac
}

clean_fixture() {
  case "$1" in
    launch|deploy)
      rm -rf /tmp/loom-py-work-probe-"$1"-* 
      pkill -9 -f 'tzconvert.py' 2>/dev/null || true
      rm -f /tmp/loom-servers.pids ;;
  esac
}

echo "== eval suite: model=$MODEL provider=$PROVIDER commit=$COMMIT"
while IFS=$'\t' read -r role samples _; do
  case "$role" in ''|\#*) continue ;; esac
  stage_fixture "$role" "$samples"
  line=$(N="$samples" ROLE="$role" bash bin/probe-node.sh "$samples" "$role" "$MODEL" 2>&1 | grep 'accept rate' || true)
  clean_fixture "$role"
  got=$(printf '%s' "$line" | sed -n 's/.*accept rate: \([0-9]*\)\/\([0-9]*\).*/\1/p')
  got="${got:-0}"
  printf '%s\t%s\t%s\n' "$role" "$got" "$samples" >> "$OUT"
  printf '  %-16s %s/%s\n' "$role" "$got" "$samples"
done < "$SUITE"

if [ "$UPDATE" = "1" ]; then
  grep -v '^#' "$OUT" > "$BASELINE"
  { echo "# baseline recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) — model $MODEL, provider $PROVIDER, commit $COMMIT"
    cat "$BASELINE"
  } > "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE"
  echo "== baseline updated: $BASELINE"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "== no baseline yet. Record one with: bin/eval-suite.sh --update"
  exit 0
fi

echo "== against $BASELINE (tolerance: $TOLERANCE sample)"
regressed=0
while IFS=$'\t' read -r role got samples; do
  case "$role" in ''|\#*) continue ;; esac
  base=$(awk -F'\t' -v r="$role" '$1==r{print $2}' "$BASELINE" | head -1)
  if [ -z "$base" ]; then
    printf '  %-16s %s/%s  (no baseline for this role)\n' "$role" "$got" "$samples"
    continue
  fi
  delta=$((got - base))
  if [ "$delta" -lt "-$TOLERANCE" ]; then
    printf '  %-16s %s/%s  REGRESSED from %s (%s)\n' "$role" "$got" "$samples" "$base" "$delta"
    regressed=$((regressed + 1))
  elif [ "$delta" -gt 0 ]; then
    printf '  %-16s %s/%s  improved from %s (+%s)\n' "$role" "$got" "$samples" "$base" "$delta"
  else
    printf '  %-16s %s/%s  (baseline %s)\n' "$role" "$got" "$samples" "$base"
  fi
done < <(grep -v '^#' "$OUT")

echo "== results: $OUT"
if [ "$regressed" -gt 0 ]; then
  echo "== $regressed role(s) regressed by more than $TOLERANCE sample" >&2
  exit 1
fi
echo "== no regressions"
