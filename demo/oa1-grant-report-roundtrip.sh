#!/usr/bin/env bash
# demo/oa1-grant-report-roundtrip.sh — the OA1 promotion criterion, live
# (lex-loom#182, docs/design/soft-os-aware-agents.md):
#
#   "cast.lex can report, for a given roster, which roles would run under
#    which grant, without anything executing differently yet."
#
# Seeds a company with a [policy.isolation] override on the "build" role
# only, seeds one iteration with a 3-node sprint graph (build/qa/docs), then
# runs the REAL production CLI entrypoint (src/main.lex roster_grant_report_cmd
# — the exact command an operator would run) and checks all three roles
# resolve to the right preset:
#   - build -> Demo      (the declared override wins over build's own default)
#   - qa    -> QA        (not overridden, keeps manifests.lex's own default)
#   - docs  -> Demo      (an unmapped role kind, the universal safe fallback)
#
# Nothing in this script or in roster_grant_report_cmd itself executes a
# node or calls lex-os — it only reports what WOULD happen, which is the
# whole point of OA1.
#
#   bash demo/oa1-grant-report-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/oa1-grant-report-demo.db"
COMPANY_ID="oa1-demo"
POLICY_ISOLATION="build:Demo"

rm -f "$DB_PATH"
cleanup() { rm -f "$DB_PATH"; }
trap cleanup EXIT

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"

echo "+ seeding a company with [policy].isolation = $POLICY_ISOLATION"
DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" POLICY_ISOLATION="$POLICY_ISOLATION" \
  lex run --allow-effects "$EFFECTS" \
  demo/oa1_grant_report.lex seed_company_cmd

echo
echo "+ seeding iteration 1 with a 3-node sprint graph (build, qa, docs)"
DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" \
  lex run --allow-effects "$EFFECTS" \
  demo/oa1_grant_report.lex seed_iteration_cmd

echo
echo "+ roster_grant_report_cmd — the real production CLI entrypoint (src/main.lex)"
REPORT=$(DB_PATH="$DB_PATH" COMPANY_ID="$COMPANY_ID" \
  lex run --allow-effects "$EFFECTS" \
  src/main.lex roster_grant_report_cmd)
echo "$REPORT"

echo
echo "+ checking the report against expectations"
fail=0
check() {
  if echo "$REPORT" | grep -qE "$1"; then
    echo "  ok: $2"
  else
    echo "  FAILED: expected to find '$2' in the report" >&2
    fail=1
  fi
}
check "n-build \(build\) -> Demo" "build -> Demo (declared override wins)"
check "n-qa \(qa\) -> QA" "qa -> QA (no override, own default)"
check "n-docs \(docs\) -> Demo" "docs -> Demo (unmapped role, safe fallback)"

if [ "$fail" -ne 0 ]; then
  echo
  echo "oa1-grant-report-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "oa1-grant-report-roundtrip: OK — reported without executing anything"
