#!/usr/bin/env bash
# ti1-typed-issues-roundtrip.sh — live proof of the typed-issue binding
# (lex-loom#521, lex-lang#949 phase 5) with NO provider keys and no network:
#
#   1. pure halves   — the shape rule and the proposal parser are pinned by
#                      `examples {}` in src/issues.lex; `lex check` runs them.
#   2. untyped path  — without LOOM_WORKSPACE a cx proposal still queues,
#                      untyped, with issue_create_failed on the trail.
#   3. typed loop    — against a real lex-vcs store: create two issues
#                      (typed_delta + failing_example), publish the sealed
#                      source with --intent-issue, verify: the typed delta is
#                      VERIFIED at the head, the wrong expected value FAILS
#                      (the example ran), the same proposal yields the same
#                      content-addressed id.
#   4. negative      — a sabotaged copy of the test (the bug's expected value
#                      made correct) must FAIL: the suite can say no.
#
# Needs `lex` >= 0.11.50 on PATH (lex issue + --intent-issue + JSON output).
# Run from the repo root:  bash demo/ti1-typed-issues-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

EFFECTS="concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,approval,stream"
pass=0
fail=0
say()  { printf '\n== %s\n' "$*"; }
ok()   { echo "   OK: $*"; pass=$((pass+1)); }
bad()  { echo "   FAIL: $*"; fail=$((fail+1)); }

say "toolchain"
if lex issue 2>&1 | grep -q 'usage: lex issue' && lex publish 2>&1 | grep -q -- '--intent-issue'; then
  ok "lex on PATH knows lex issue and publish --intent-issue ($(lex --version | head -1))"
else
  bad "lex on PATH lacks lex issue / --intent-issue (need lex-lang >= 0.11.50)"
  echo "$pass passed, $fail failed"; exit 1
fi

say "1. pure halves (examples run under lex check --strict)"
if lex check --strict src/issues.lex >/dev/null 2>&1; then
  ok "src/issues.lex strict-checks; shape_for / parse_proposals / sh_quote examples hold"
else
  bad "src/issues.lex does not strict-check"
fi

say "2+3. the test file: untyped fallback, then the typed loop on a real store"
out="$(env -u LOOM_WORKSPACE lex run --allow-effects "$EFFECTS" tests/test_typed_issues.lex run_all 2>&1 || true)"
if grep -q 'ok   2 typed issue tests' <<<"$out"; then
  ok "both tests pass"
else
  bad "test_typed_issues did not pass:"; echo "$out" | tail -8
fi
if grep -q 'skip: toolchain' <<<"$out"; then
  bad "the typed loop was SKIPPED (toolchain probe said no) — nothing was proven"
else
  ok "the typed loop RAN (no skip line)"
fi
if grep -q 'queued untyped' <<<"$out"; then
  ok "untyped fallback exercised without a workspace"
else
  bad "expected the untyped-fallback path to print 'queued untyped'"
fi

say "4. negative control: a sabotaged test must fail"
sab="$(mktemp "${TMPDIR:-/tmp}/loom-ti1-sab.XXXXXX.lex")"
trap 'rm -f "$sab"' EXIT
sed 's/example: "gcd(0, 0) => 1"/example: "gcd(0, 0) => 0"/' tests/test_typed_issues.lex > "$sab"
# the test imports ../src/* relative to tests/, so run the copy from there
cp "$sab" tests/_ti1_sabotage.lex
sout="$(env -u LOOM_WORKSPACE lex run --allow-effects "$EFFECTS" tests/_ti1_sabotage.lex run_all 2>&1 || true)"
rm -f tests/_ti1_sabotage.lex
if grep -q 'FAIL: wrong expected value fails' <<<"$sout"; then
  ok "sabotage caught: a correct expected value no longer 'fails', and the test says so"
else
  bad "sabotage NOT caught — the suite cannot say no:"; echo "$sout" | tail -5
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
