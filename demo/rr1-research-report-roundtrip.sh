#!/usr/bin/env bash
# rr1-research-report-roundtrip.sh -- the opportunity-report gate, checked.
#
# ResearchCo (docs/consortium-freeze.md) sells opportunity-research/v1. Its
# deliverable is a markdown report whose checkable criteria are verified by
# bin/check_research_report.lex, one attr per criterion, so lex-economy's
# evidence items can be built from the checker's own output. This demo proves
# the checker accepts a complete report, refuses each missing criterion BY
# NAME, and never answers the human's question. It also proves the search
# backend the role depends on returns URLs offline-parsable from a fixture,
# because a report grounded in "no results found" is what the gate refuses.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-rr1.XXXXXX")"; trap 'rm -rf "$W"' EXIT
# The search ledger: every URL web_search returned in this run. The gate
# refuses any cited source outside it.
export LOOM_SEARCH_LEDGER="$W/ledger.txt"
printf 'https://cloudmersive.com/convert/validate-csv-api\nhttps://flatfile.com/pricing/\nhttps://csvlint.io/\n' > "$LOOM_SEARCH_LEDGER"

good() {
cat <<'MD'
# Opportunity: CSV schema validation API

## Problem
Solo developers accepting CSV uploads re-implement validation on every project. Errors surface as bad rows in production instead of at upload time.

## Target user
Solo developers building SaaS back-offices who accept spreadsheet uploads from customers.

## Alternatives
| Alternative | What it does | Price / gap |
|---|---|---|
| Cloudmersive Validate CSV | validates CSV syntax via API | free tier 800 calls/month; no schema rules |
| Flatfile | full import UI | from $599/month; too heavy for a solo developer |
| csvlint.io | web validator | free; no API, no schema rules |

## Implementation estimate
40 hours: a FastAPI service with a JSON schema-rules dialect, streaming parser and a test suite.

## Dependencies
- FastAPI
- a CSV parser with streaming support

## Sources
- https://cloudmersive.com/convert/validate-csv-api
- https://flatfile.com/pricing

## Confidence
70 -- would rise with three interviews of developers who accept CSV uploads.

## Recommendation
Build it: the gap between a syntax-only free validator and a $599/month import suite is real and reachable in a week.
MD
}

echo "== 1. a complete report passes and names every verified attr"
mkdir -p "$W/good"; good > "$W/good/report.md"
out=$(cd "$W/good" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"RESEARCH_REPORT_OK"* ]] && [[ "$out" == *"checkable:two-sources"* ]] && [[ "$out" == *"checkable:sources-grounded"* ]] && [[ "$out" == *"checkable:three-alternatives"* ]]; then ok "complete report accepted; attrs printed for the evidence bundle"; else bad "complete report refused or attrs missing: $out"; fi

echo "== 2. each missing criterion is refused by its attr name (sabotage per section)"
for sec in "## Problem:checkable:problem-statement" "## Target user:checkable:target-user" "## Implementation estimate:checkable:implementation-estimate" "## Dependencies:checkable:dependencies" "## Confidence:checkable:confidence" "## Recommendation:checkable:recommendation"; do
  heading="${sec%%:*}"; attr="${sec#*:}"
  mkdir -p "$W/miss"; good | sed "s|^$heading\$|## Removed|" > "$W/miss/report.md"
  out=$(cd "$W/miss" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && [[ "$out" == *"$attr"* ]]; then ok "missing '$heading' refused as $attr"; else bad "missing '$heading' was not refused as $attr (rc=$rc): $out"; fi
done

echo "== 3. two alternatives are not three; one source is not two; confidence 140 is not a percentage"
mkdir -p "$W/alt2"; good | command grep -v '^| csvlint' > "$W/alt2/report.md"
out=$(cd "$W/alt2" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:three-alternatives"* ]]; then ok "two table rows refused as checkable:three-alternatives"; else bad "two alternatives accepted"; fi
mkdir -p "$W/src1"; good | command grep -v 'flatfile.com/pricing' > "$W/src1/report.md"
out=$(cd "$W/src1" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:two-sources"* ]]; then ok "one source refused as checkable:two-sources"; else bad "one source accepted"; fi
mkdir -p "$W/conf"; good | sed 's/^70 --/140 --/' > "$W/conf/report.md"
out=$(cd "$W/conf" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:confidence"* ]]; then ok "confidence 140 refused as checkable:confidence"; else bad "confidence 140 accepted"; fi
mkdir -p "$W/hrs"; good | sed 's/^40 hours:/about a week:/' > "$W/hrs/report.md"
out=$(cd "$W/hrs" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:implementation-estimate"* ]]; then ok "an estimate without hours refused"; else bad "'about a week' accepted as an hours estimate"; fi

echo "== 3b. a source the search never returned is refused, however real it looks"
# Live probe 2026-09-09: 13 of 21 cited URLs were recalled, not found.
mkdir -p "$W/recall"; good | sed 's|https://flatfile.com/pricing|https://numverify.com/|' > "$W/recall/report.md"
out=$(cd "$W/recall" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:sources-grounded"* ]] && [[ "$out" == *"numverify.com"* ]]; then ok "a remembered URL refused as checkable:sources-grounded, named"; else bad "a URL outside the ledger was accepted (rc=$rc): $out"; fi
mkdir -p "$W/noledger"; good > "$W/noledger/report.md"
out=$(cd "$W/noledger" && LOOM_SEARCH_LEDGER="$W/does-not-exist.txt" bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:sources-grounded"* ]] && [[ "$out" == *"never called"* ]]; then ok "no ledger (web_search never called) refused as checkable:sources-grounded"; else bad "a report with no search behind it was accepted (rc=$rc): $out"; fi
mkdir -p "$W/slash"; good | sed 's|https://cloudmersive.com/convert/validate-csv-api|https://cloudmersive.com/convert/validate-csv-api/|' > "$W/slash/report.md"
if (cd "$W/slash" && bash "$OLDPWD/bin/check-research-report.sh" . >/dev/null 2>&1); then ok "a trailing slash is the same source"; else bad "a trailing slash was treated as a different URL"; fi

echo "== 3c/7. the search backends, the ledger, the bot-check page and the fallback order"
# Four legs collapse to one. Each loaded bin/web_search.py through importlib
# from inside another python3 and monkeypatched its `fetch`, so every test
# depended on the module's private shape. The Lex parsers are pure functions of
# the response body and the ledger append is a plain call, so
# tests/test_web_search.lex exercises all of it directly -- same fixtures, same
# assertions, no introspection.
if LOOM_SEARCH_LEDGER="$W/ledger-tool.txt" lex run --allow-effects env,fs_read,fs_write,io,net \
     tests/test_web_search.lex run_all 2>&1 | grep -q '^FAIL'; then
  bad "a search parser, the ledger, the bot-check page or the fallback order regressed (run tests/test_web_search.lex)"
else
  ok "brave + bing + duckduckgo + yahoo parsers, the ledger, the bot-check page, and the fallback order"
fi

echo "== 4. no report on disk is a denial that says what to write"
mkdir -p "$W/none"; out=$(cd "$W/none" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"report.md"* ]]; then ok "empty scratch dir refused, naming report.md"; else bad "empty dir not refused"; fi

echo "== 5. the human's criterion is never in the verified attrs"
out=$(cd "$W/good" && bash "$OLDPWD/bin/check-research-report.sh" . 2>&1 || true)
case "$out" in *"human:"*) bad "the checker printed a human: attr -- the machine answered the founder's question" ;; *) ok "no human: attr in the checker's output" ;; esac

echo "== 6. the report reaches the gate through the fence (extract_fenced names report.md)"
mkdir -p "$W/fence"; { printf 'Here is the report.\n\n```report.md\n'; good; printf '```\n'; } > "$W/fence/art.txt"
mkdir -p "$W/fence/w"; bash bin/extract-fenced.sh "$W/fence/art.txt" "$W/fence/w" >/dev/null 2>&1 || true
if [ -f "$W/fence/w/report.md" ] && (cd "$W/fence/w" && bash "$OLDPWD/bin/check-research-report.sh" . >/dev/null 2>&1); then ok "a fenced report.md lands on disk and passes"; else bad "the fenced report did not reach the gate: $(ls "$W/fence/w" 2>/dev/null)"; fi




echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
