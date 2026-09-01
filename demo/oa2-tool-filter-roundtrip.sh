#!/usr/bin/env bash
# demo/oa2-tool-filter-roundtrip.sh — the OA2 promotion criterion, live
# (lex-loom#183, docs/design/soft-os-aware-agents.md /
# docs/design/oa2-tool-call-mediation.md):
#
#   "A QA-shaped grant denies a tool call it shouldn't have, end to end,
#    with the LLM loop still completing the sprint via its remaining
#    permitted tools — proven first under --simulated."
#
# No live LLM is invoked here — this repo has no LLM credentials in CI, and
# lex-os-isolation.md's own Phase 0 precedent is the same shape: a
# dependency-free proof on the grant-generation/mediation side, not a live
# end-to-end model call. What IS proven live is the exact filtering step
# src/agent/runner.lex's LLM branch performs, against the real "build" role
# (real AgentDef, real Tool implementations from src/roles.lex) built by the
# real cast.select_roster:
#
#   1. Under build's own default grant (Implementation: exec Sandboxed) —
#      no override — BOTH of build's tools (lex_guidelines, lex_check)
#      survive the filter.
#   2. Under a declared [policy.isolation] override (build -> Demo:
#      exec None) — the same override machinery OA1 shipped — lex_check
#      (needs exec:Sandboxed) is denied, lex_guidelines (needs nothing)
#      survives.
#   3. The surviving tool in case 2 is not just a name still in a list — it
#      is actually CALLED (a real lex_guidelines invocation) to prove the
#      LLM loop's remaining permitted tools are genuinely still functional,
#      the "loop still completing via its remaining tools" half of the
#      promotion criterion.
#
#   bash demo/oa2-tool-filter-roundtrip.sh

set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

DB_PATH="demo/oa2-tool-filter-demo.db"
rm -f "$DB_PATH"
cleanup() { rm -f "$DB_PATH"; }
trap cleanup EXIT

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"

echo "+ case 1: no override — build keeps its own default grant (Implementation: exec Sandboxed)"
BASELINE=$(DB_PATH="$DB_PATH" SPRINT_ID="oa2-demo/iter-1" POLICY_ISOLATION="" \
  lex run --allow-effects "$EFFECTS" \
  demo/oa2_tool_filter.lex report_cmd)
echo "$BASELINE"

echo
echo "+ case 2: [policy.isolation] override build -> Demo (exec None) — lex_check should be denied"
OVERRIDDEN=$(DB_PATH="$DB_PATH" SPRINT_ID="oa2-demo/iter-1" POLICY_ISOLATION="build:Demo" \
  lex run --allow-effects "$EFFECTS" \
  demo/oa2_tool_filter.lex report_cmd)
echo "$OVERRIDDEN"

echo
echo "+ checking both cases against expectations"
fail=0
check() {
  if echo "$1" | grep -qE "$2"; then
    echo "  ok: $3"
  else
    echo "  FAILED: expected to find '$2' — $3" >&2
    fail=1
  fi
}
check "$BASELINE"   "tools after filter:  lex_guidelines,lex_check" "case 1: both tools survive under build's own default grant"
check "$OVERRIDDEN" "tools after filter:  lex_guidelines$"          "case 2: only lex_guidelines survives the build:Demo override"
check "$OVERRIDDEN" "called surviving tool 'lex_guidelines' for real -- ok" "case 2: the surviving tool was actually called, and it worked"

if [ "$fail" -ne 0 ]; then
  echo
  echo "oa2-tool-filter-roundtrip: FAILED" >&2
  exit 1
fi

echo
echo "oa2-tool-filter-roundtrip: OK — the QA/Demo-shaped grant denied the tool it shouldn't have, and the remaining tool is still genuinely callable"
