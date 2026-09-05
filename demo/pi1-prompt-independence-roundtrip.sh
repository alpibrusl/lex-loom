#!/usr/bin/env bash
# pi1-prompt-independence-roundtrip.sh -- keep the sprint-independence test
# from going stale (#312).
#
# tests/test_prompt_sprint_independence.lex names the two prompts that take a
# sprint id -- launch and deploy -- and asserts each renders identically for
# different sprints. That list is written by hand, so a THIRD prompt taking a
# sprint id would reintroduce the exact bug the test exists to catch while the
# test stayed green: a path frozen into text that agent_pool replays in later
# sprints.
#
# This closes that: every sprint-taking prompt in roles.lex must be named in
# the test. The failure mode being guarded here is not a wrong prompt but an
# UNWATCHED one.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

SRC=src/roles.lex
T=tests/test_prompt_sprint_independence.lex

echo "== 1. every prompt taking a sprint id is covered by the test"
# Prompts are `fn <name>_system_prompt(sprint_id :: Str)`; the ones taking no
# argument cannot vary by sprint and need no coverage.
taking_sprint=$(grep -oE 'fn [a-z_]+_system_prompt\(sprint_id' "$SRC" | sed 's/^fn //; s/(sprint_id$//' | sort -u)
if [ -z "$taking_sprint" ]; then
  bad "no sprint-taking prompt found at all -- this guard is looking at the wrong thing"
fi
for p in $taking_sprint; do
  if grep -q "roles\.$p(" "$T"; then
    ok "$p is exercised by the test"
  else
    bad "$p takes a sprint id but the test never renders it: whatever it interpolates will go stale in agent_pool"
  fi
done

echo "== 2. the guard can actually fail"
# Same reasoning as the negative control inside the Lex test: a grep-based
# check that matches nothing would report success forever.
if grep -q "roles\.a_prompt_that_does_not_exist(" "$T"; then
  bad "the coverage grep matches a name that is not in the test"
else
  ok "the coverage grep rejects a name the test does not mention"
fi

echo "== 3. no sprint path is frozen into a prompt body"
# The bug shape, checked at the source level: a work-dir helper called inside a
# prompt body rather than inside a tool.
if awk '/^fn [a-z_]+_system_prompt\(/{inp=1} inp&&/work_dir\(sprint_id\)/{print; found=1} /^}$/{inp=0} END{exit !found}' "$SRC" >/dev/null; then
  bad "a prompt body still calls a work_dir helper -- that path is frozen the moment the prompt is stored"
else
  ok "no prompt body resolves a work dir; the tools do it"
fi

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
