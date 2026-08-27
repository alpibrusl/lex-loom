#!/usr/bin/env bash
# company-reliability.sh — run the SAME company manifest N times and report how
# often it actually succeeds, and how it fails when it doesn't.
#
# Why this exists: a single green run is an anecdote. This repo has already
# produced a company that sealed an iteration whose test suite really failed
# 1 of 9 -- so "it worked once" is not evidence of anything. Before investing
# in harder missions or tighter isolation, the useful number is: out of N
# identical attempts, how many end with an honestly-passing iteration, and
# where do the rest die?
#
# Classification reads the run's DB, never stdout. Learned the hard way:
# bin/smoke-health-sprint.sh greps stdout for "verdict not grounded", but that
# string only ever reaches the traces table, so real grounding failures were
# silently reported as "other" for months.
#
# INFRA failures are counted SEPARATELY and never as pipeline failures. A dead
# LiteLLM proxy or an upstream 4xx says nothing about whether loom works, and
# folding those into the denominator would understate the real pass rate.
#
# Usage:
#   bin/company-reliability.sh <manifest.toml> [N] [MODEL]
#
# Deliberately bash 3.2 compatible (no associative arrays): macOS still ships
# bash 3.2 as /bin/bash, and bootstrap-company.sh was unrunnable there for
# exactly that kind of reason.
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="${1:-}"
N="${2:-5}"
MODEL_OVERRIDE="${3:-}"
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "usage: bin/company-reliability.sh <manifest.toml> [N] [MODEL]" >&2; exit 2; }

WORK="$(mktemp -d /tmp/loom-reliability.XXXXXX)"
RESULTS="$WORK/results.tsv"
: > "$RESULTS"
BASE_ID="$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['identity']['id'])" "$MANIFEST")"
GOAL="$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['identity']['mission'])" "$MANIFEST")"
MODEL="${MODEL_OVERRIDE:-$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb'))['stack']['model'])" "$MANIFEST")}"
MAXIT="$(python3 -c "import tomllib,sys;print(tomllib.load(open(sys.argv[1],'rb')).get('policy',{}).get('max_iterations',3))" "$MANIFEST")"
PACKS="$(python3 -c "import tomllib,sys;print(','.join(tomllib.load(open(sys.argv[1],'rb')).get('roles',{}).get('packs',[])))" "$MANIFEST")"

echo "[reliability] manifest=$MANIFEST model=$MODEL attempts=$N max_iterations=$MAXIT"
echo "[reliability] logs in $WORK"
echo

for i in $(seq 1 "$N"); do
  ID="${BASE_ID}r${i}"
  DB="$HOME/loom-companies/$ID/company.db"
  rm -rf "$HOME/loom-companies/$ID"
  sed "s/^id      = \"$BASE_ID\"/id      = \"$ID\"/" "$MANIFEST" > "$WORK/$ID.toml"
  bash bin/bootstrap-company.sh "$WORK/$ID.toml" --no-run >/dev/null 2>&1 || true

  started=$(date +%s)
  LOOM_WORKSPACE="$HOME/loom-companies" COMPANY_ID="$ID" MODEL="$MODEL" \
    MAX_ITERATIONS="$MAXIT" ROLE_PACKS="$PACKS" DB_PATH="$DB" GOAL="$GOAL" \
    bin/run-company.sh > "$WORK/$ID.log" 2>&1 || true
  elapsed=$(( $(date +%s) - started ))

  # ---- classify from the DB ----------------------------------------------
  cls="unknown"; detail=""
  if [ ! -f "$DB" ]; then
    cls="infra"; detail="no company.db — the run never started"
  else
    provider_errs=$(sqlite3 "$DB" "select count(*) from traces where event_kind='llm_done' and data_json like '%[provider error%';" 2>/dev/null || echo 0)
    passed=$(sqlite3 "$DB" "select count(*) from traces where event_kind='sprint_complete' and data_json like '%\"success\":true%';" 2>/dev/null || echo 0)
    if [ "${passed:-0}" -gt 0 ]; then
      cls="pass"; detail="$(sqlite3 "$DB" "select count(*) from traces where event_kind='phase_bounced';" 2>/dev/null || echo 0) bounce(s)"
    elif [ "${provider_errs:-0}" -gt 0 ]; then
      cls="infra"; detail="$provider_errs provider error(s) — model/proxy unreachable, NOT a pipeline failure"
    else
      # the node that actually sank it: the last denial recorded
      detail="$(sqlite3 "$DB" "select json_extract(data_json,'\$.node')||': '||json_extract(data_json,'\$.reason') from traces where event_kind='node_denied' order by id desc limit 1;" 2>/dev/null || true)"
      [ -n "$detail" ] && cls="fail" || { cls="fail"; detail="no node_denied recorded — check $WORK/$ID.log"; }
    fi
    toks=$(sqlite3 "$DB" "select coalesce(sum(json_extract(data_json,'\$.total_tokens')),0) from traces where event_kind='llm_usage';" 2>/dev/null || echo 0)
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$ID" "$cls" "${elapsed}s" "${toks:-0}" "$detail" >> "$RESULTS"
  printf '  [%d/%d] %-14s %-6s %5ss  %s\n' "$i" "$N" "$ID" "$cls" "$elapsed" "$detail"
done

echo
p=$(awk -F'\t' '$2=="pass"{n++}END{print n+0}' "$RESULTS")
f=$(awk -F'\t' '$2=="fail"{n++}END{print n+0}' "$RESULTS")
x=$(awk -F'\t' '$2=="infra"{n++}END{print n+0}' "$RESULTS")
valid=$((p + f))
echo "[reliability] pass=$p  fail=$f  infra=$x   (infra runs excluded from the rate)"
if [ "$valid" -gt 0 ]; then
  echo "[reliability] pass rate: $p/$valid ($(( p * 100 / valid ))%) over runs that actually reached the model"
else
  echo "[reliability] no run reached the model — nothing measured"
fi
echo
echo "[reliability] failure modes:"
awk -F'\t' '$2=="fail"{print "  " $5}' "$RESULTS" | sort | uniq -c | sort -rn
echo
echo "[reliability] per-run detail: $RESULTS"
