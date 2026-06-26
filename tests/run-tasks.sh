#!/usr/bin/env bash
# run-tasks.sh — fire portfolio sprints against the loom REST API and report results.
#
# Usage:
#   ./tests/run-tasks.sh [sprint-file...]
#   ./tests/run-tasks.sh tests/tasks/portfolio-sprint-1.json
#   ./tests/run-tasks.sh tests/tasks/portfolio-sprint-*.json
#
# Requires: loom running at LOOM_URL (default http://localhost:8880)
#           sqlite3 on PATH for trail DB inspection

set -euo pipefail

LOOM_URL="${LOOM_URL:-http://localhost:8880}"
LOOM_SERVER="${LOOM_SERVER:-https://loom.lexlang.org}"
LOOM_RUNNER_TOKEN="${LOOM_RUNNER_TOKEN:-}"
POLL_INTERVAL=5
MAX_WAIT=600  # 10 minutes per sprint

# If LOOM_RUNNER_TOKEN is set, publish agents to loom-cloud before running.
publish_agents_if_needed() {
  if [[ -n "$LOOM_RUNNER_TOKEN" ]]; then
    local yaml
    yaml="$(dirname "$0")/../../../loom-cloud/agents/portfolio.yaml"
    if [[ -f "$yaml" ]]; then
      echo "Publishing agents to loom-cloud ($LOOM_SERVER)..."
      LOOM_SERVER="$LOOM_SERVER" LOOM_RUNNER_TOKEN="$LOOM_RUNNER_TOKEN" \
        "$(dirname "$0")/../../../loom-cloud/bin/loom-publish" "$yaml" \
        && echo "  Agents published." || echo "  Warning: agent publish failed (continuing)"
    fi
  fi
}

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $*"; }
fail() { echo -e "${RED}FAIL${NC} $*"; }
warn() { echo -e "${YELLOW}WARN${NC} $*"; }

# Results table
declare -a RESULTS=()

run_sprint() {
  local file="$1"
  local sprint_id model request

  sprint_id=$(jq -r .sprint_id "$file")
  model=$(jq -r .model "$file")
  request=$(jq -r .request "$file")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Sprint: $sprint_id  Model: $model"
  if [[ -n "$LOOM_RUNNER_TOKEN" ]]; then
    echo "Cloud: $LOOM_SERVER (runner token set — trail will be uploaded)"
  else
    echo "Local: $LOOM_URL (set LOOM_RUNNER_TOKEN to also push to loom-cloud)"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # POST the sprint request to local loom
  local response
  response=$(curl -s -X POST "$LOOM_URL/api/sprints" \
    -H "content-type: application/json" \
    -d @"$file")

  local sprint_status
  sprint_status=$(echo "$response" | jq -r '.status // "error"')
  if [[ "$sprint_status" == "error" ]] || [[ -z "$sprint_status" ]]; then
    fail "$sprint_id — could not start sprint: $response"
    RESULTS+=("$sprint_id|FAILED|could not start")
    return
  fi

  echo "Started $sprint_id, polling for completion..."

  # Poll for completion
  local elapsed=0
  local trail_db="${sprint_id}-trail.db"
  local status="running"

  while [[ $elapsed -lt $MAX_WAIT ]]; do
    sleep $POLL_INTERVAL
    elapsed=$((elapsed + POLL_INTERVAL))

    local poll
    poll=$(curl -s "$LOOM_URL/api/sprints/$sprint_id" 2>/dev/null || echo "{}")
    status=$(echo "$poll" | jq -r '.status // "running"')

    if [[ "$status" == "complete" ]] || [[ "$status" == "failed" ]]; then
      break
    fi

    echo "  [${elapsed}s] status=$status"
  done

  if [[ $elapsed -ge $MAX_WAIT ]]; then
    warn "$sprint_id — timed out after ${MAX_WAIT}s"
    RESULTS+=("$sprint_id|TIMEOUT|exceeded ${MAX_WAIT}s")
    return
  fi

  # Extract results from trail DB
  if [[ ! -f "$trail_db" ]]; then
    warn "$sprint_id — trail DB not found: $trail_db"
    RESULTS+=("$sprint_id|${status^^}|no trail DB")
    return
  fi

  # QA verdicts per language
  local py_verdict lex_verdict
  py_verdict=$(sqlite3 "$trail_db" \
    "SELECT data_json FROM traces WHERE event_kind='node_artifact' AND data_json LIKE '%py_qa%' ORDER BY ts DESC LIMIT 1;" \
    2>/dev/null | jq -r '.verdict // "none"' 2>/dev/null || echo "none")
  lex_verdict=$(sqlite3 "$trail_db" \
    "SELECT data_json FROM traces WHERE event_kind='node_artifact' AND data_json LIKE '%loom-qa%' ORDER BY ts DESC LIMIT 1;" \
    2>/dev/null | jq -r '.verdict // "none"' 2>/dev/null || echo "none")

  # Node counts + bounce counts
  local total_nodes qa_bounces
  total_nodes=$(sqlite3 "$trail_db" \
    "SELECT COUNT(*) FROM traces WHERE event_kind='node_artifact';" 2>/dev/null || echo "?")
  qa_bounces=$(sqlite3 "$trail_db" \
    "SELECT COUNT(*) FROM traces WHERE event_kind='qa_bounce';" 2>/dev/null || echo "0")

  # Summary
  echo ""
  echo "  Sprint status : $status"
  echo "  Python QA     : $py_verdict"
  echo "  Lex QA        : $lex_verdict"
  echo "  Nodes run     : $total_nodes"
  echo "  QA bounces    : $qa_bounces"

  local row="${sprint_id}|${status}|py=${py_verdict} lex=${lex_verdict}|bounces=${qa_bounces}"
  RESULTS+=("$row")
}

# ── Main ───────────────────────────────────────────────────────────────────────

FILES=("${@:-tests/tasks/portfolio-sprint-1.json}")

echo "Loom task runner — local: $LOOM_URL"
echo "Running ${#FILES[@]} sprint(s)..."

publish_agents_if_needed

for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    warn "File not found: $f — skipping"
    continue
  fi
  run_sprint "$f"
done

# Summary table
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-30s %-12s %-30s %s\n" "Sprint" "Status" "QA Verdicts" "Notes"
echo "──────────────────────────────────────────────────────"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r sid sts qa notes <<< "$row"
  printf "%-30s %-12s %-30s %s\n" "$sid" "$sts" "$qa" "$notes"
done
echo ""
