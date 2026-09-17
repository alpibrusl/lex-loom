#!/usr/bin/env bash
# cs2-operable-contract-roundtrip.sh -- run 2's operable-delivery contract
# through its real commands, on top of run 1's settled research and software
# contracts (rebuilt here exactly as cs1 does). Proves: the operable contract
# waits for the settled software, reserves 30000c, and settles by the 100/50/0
# rule from evidence the BUYER re-derives -- re-running the roles' own grounded
# gates. Offline it settles at 50% with exactly reachable-over-tls unmet: a
# hostname is a founder-provided need. No model, no network, no real host.
cd "$(dirname "$0")/.."
# There is no default model any more, so this demo names one like any
# operator would. Nothing here calls it: the model string only ends up in the
# manifests/config this demo writes and checks.
export MODEL="${MODEL:-kimi-k2.7-code}"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-cs1.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export LOOM_WORKSPACE="$W/ws" CONSORTIUM_DB="$W/ws/consortium.db"
export LOOM_SEARCH_LEDGER="$W/ledger.txt"
mkdir -p "$LOOM_WORKSPACE/researchco"
printf 'https://cloudmersive.com/convert/validate-csv-api\nhttps://flatfile.com/pricing\n' > "$LOOM_SEARCH_LEDGER"

report() {
cat <<'MD'
# Opportunity: CSV schema validation API

## Problem
Solo developers accepting CSV uploads re-implement validation on every project.

## Target user
Solo developers building SaaS back-offices who accept spreadsheet uploads.

## Alternatives
| Alternative | What it does | Price / gap |
|---|---|---|
| Cloudmersive Validate CSV | validates CSV syntax via API | free tier; no schema rules |
| Flatfile | full import UI | from $599/month; too heavy |
| csvlint.io | web validator | free; no API |

## Implementation estimate
40 hours: a FastAPI service with a schema-rules dialect and a test suite.

## Dependencies
- FastAPI

## Sources
- https://cloudmersive.com/convert/validate-csv-api
- https://flatfile.com/pricing

## Confidence
70 -- would rise with three developer interviews.

## Recommendation
Build it: the gap between a free syntax validator and a $599/month suite is real.
MD
}

. "$(dirname "$0")/_fixtures.sh"

echo "== 1. open: treasuries funded, research bought from ResearchCo, price reserved"
out=$(bin/consortium-run.sh open 2>&1) || true
if [[ "$out" == *"c-research-1 awarded: softwareco buys opportunity-research/v1 from researchco for 40000c"* ]] && [[ "$out" == *"softwareco: balance=200000c committed=40000c available=160000c"* ]] && [[ "$out" == *"researchco: balance=100000c committed=0c"* ]]; then ok "contract awarded and 40000c reserved on the buyer"; else bad "open did not award/reserve: $out"; fi
case "$out" in *"[answered by a human, not by you] human:would-fund"*) ok "the goal marks the human criterion as not the machine's" ;; *) bad "the goal does not mark the human criterion" ;; esac
if [ -f "$LOOM_WORKSPACE/researchco.company.toml" ] && command grep -q 'packs = \["core", "research"\]' "$LOOM_WORKSPACE/researchco.company.toml" && command grep -q 'path  = "research-report"' "$LOOM_WORKSPACE/researchco.company.toml"; then ok "ResearchCo manifest written with the research pack and the document path"; else bad "no usable ResearchCo manifest"; fi
( manifest_has "$LOOM_WORKSPACE/researchco.company.toml" "checkable:sources-grounded" ) && ok "the manifest parses as TOML and its mission carries the criteria" || bad "the manifest does not parse or lost the criteria"

echo "== 2. open again is refused and reserves nothing more"
out=$(bin/consortium-run.sh open 2>&1) || true
case "$out" in *"already open"*) ok "second open refused" ;; *) bad "second open not refused: $out" ;; esac

echo "== 3. deliver: the buyer re-runs the gate; the human's half holds the verdict Ambiguous"
report > "$LOOM_WORKSPACE/researchco/report.md"
out=$(bin/consortium-run.sh deliver 2>&1) || true
if [[ "$out" == *"RESEARCH_REPORT_OK"* ]] && [[ "$out" == *"c-research-1 verified: ambiguous; awaiting: human:would-fund"* ]] && [[ "$out" == *"QUESTION FOR THE FOUNDER"* ]] && [[ "$out" == *"committed=40000c"* ]]; then ok "delivery verified by the buyer's own checker run; commitment held; founder asked"; else bad "deliver did not hold Ambiguous with the question: $out"; fi

echo "== 4. the founder says yes: settled in full by the freeze rule"
out=$(ANSWER=yes NOTE='fund it' bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"c-research-1 settled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]] && [[ "$out" == *"researchco: balance=140000c committed=0c"* ]] && [[ "$out" == *"should terminate=yes"* ]]; then ok "settled: 40000c left the buyer AND arrived at the supplier, commitment cleared, run terminal"; else bad "yes did not settle 40000c: $out"; fi
out=$(ANSWER=no bin/consortium-run.sh answer 2>&1) || true
case "$out" in *"answer FAILED"*) ok "a second answer on a settled contract is refused" ;; *) bad "a settled contract took another answer: $out" ;; esac

echo "== 4b. SoftwareCo contracts itself to build the settled report's product"
out=$(bin/consortium-run.sh open-software 2>&1) || true
if [[ "$out" == *"c-software-1 awarded: softwareco builds software-delivery/v1 itself for 60000c"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=60000c available=100000c"* ]]; then ok "software contract awarded as an internal build; 60000c reserved"; else bad "open-software did not award/reserve: $out"; fi
( [ "$(bin/toml-get.sh "$LOOM_WORKSPACE/softwareco.company.toml" stack.path)" = "python-fastapi" ] \
    && manifest_has "$LOOM_WORKSPACE/softwareco.company.toml" "CSV schema validation API" \
    && manifest_has "$LOOM_WORKSPACE/softwareco.company.toml" "checkable:acceptance-passed" ) && ok "SoftwareCo manifest carries the report and the delivery criteria" || bad "SoftwareCo manifest missing or without the report"

echo "== 4c. deliver-software re-derives the evidence from the company's trail and workspace"
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests"
seed_trail "$SW/company.db" 2026-09-09T00:00:00Z
# Run 1 live: the product landed in main.py, app.py stayed the skeleton's.
cp paths/python-fastapi/app.py "$SW/app.py"
printf 'from fastapi import FastAPI\napp = FastAPI()\n\n@app.post("/validate")\ndef validate(row: dict):\n    return {"ok": True}\n' > "$SW/main.py"
printf 'def test_validate_rejects_bad_row():\n    assert True\n' > "$SW/tests/test_validate.py"
out=$(bin/consortium-run.sh deliver-software 2>&1) || true
if [[ "$out" == *"SOFTWARE_DELIVERY_OK"* ]] && [[ "$out" == *"c-software-1 settled: fulfilled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]] && [[ "$out" == *"objective met=yes; should terminate=yes"* ]]; then ok "delivery verified from the trail (product in main.py, not app.py); settled in full; run 1 terminal"; else bad "deliver-software did not settle: $out"; fi

echo "== 5. open-operable waits for the settled software contract, then reserves 30000c"
out=$(bin/consortium-run.sh open-operable 2>&1) || true
if [[ "$out" == *"c-operable-1 awarded: softwareco makes operable-delivery/v1 itself for 30000c"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=30000c available=130000c"* ]]; then ok "operable contract awarded as an internal build; 30000c reserved"; else bad "open-operable did not award/reserve: $out"; fi
[ -f "$LOOM_WORKSPACE/softwareco-operable.company.toml" ] && grep -q 'packs = \["core", "ops", "governance"\]' "$LOOM_WORKSPACE/softwareco-operable.company.toml" && ok "operable manifest carries the ops and governance packs" || bad "operable manifest missing or without the packs"

echo "== 6. deliver-operable re-derives every criterion; offline, TLS is the one it cannot"
seed_accepted_graph "$SW/company.db" g1 pm:pm release-runbook:release_manager dpa:data_protection
mkdir -p "$SW/ops" "$SW/backup"
printf '# PRD\n## Success metrics\n- Activation: %% of accounts with a first `submission_delivered` within 7 days\n' > "$SW/prd.md"
printf 'def deliver(s):\n    track("submission_delivered", {"id": s})\n' > "$SW/analytics_hooks.py"
seed_restore "$SW"
out=$(bin/consortium-run.sh deliver-operable 2>&1) || true
if [[ "$out" == *"OPERABLE_DELIVERY_VERIFIED checkable:iteration-passed checkable:acceptance-passed checkable:metrics-instrumented checkable:restore-performed checkable:runbook-present checkable:data-map-present"* ]]; then ok "the buyer re-derived six criteria by re-running the roles' own gates"; else bad "checker did not verify the six offline criteria: $out"; fi
if [[ "$out" == *"partially fulfilled; unmet: checkable:reachable-over-tls"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]]; then ok "offline settles at 50% with exactly TLS unmet; commitment released"; else bad "offline operable delivery did not settle at 50% on TLS alone: $out"; fi

echo "== 7. sabotage: a lying restore evidence is caught by an independent restore"
rm -rf "$LOOM_WORKSPACE"; mkdir -p "$LOOM_WORKSPACE/researchco"
bin/consortium-run.sh open >/dev/null 2>&1; report > "$LOOM_WORKSPACE/researchco/report.md"; bin/consortium-run.sh deliver >/dev/null 2>&1; ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1; bin/consortium-run.sh open-software >/dev/null 2>&1
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests" "$SW/ops" "$SW/backup"
seed_trail "$SW/company.db" 2026-09-11T00:00:00Z
cp paths/python-fastapi/app.py "$SW/app.py"; printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$SW/main.py"; printf 'def test_x():\n    assert True\n' > "$SW/tests/test_x.py"
bin/consortium-run.sh deliver-software >/dev/null 2>&1; bin/consortium-run.sh open-operable >/dev/null 2>&1
seed_restore "$SW" 1 300
out=$(bin/consortium-run.sh deliver-operable 2>&1) || true
vline=$(printf '%s\n' "$out" | grep -E '^OPERABLE_DELIVERY_VERIFIED' | head -1)
if [[ "$vline" != *"checkable:restore-performed"* ]] && [[ "$out" == *"checkable:restore-performed: checkable:evidence-matches-restore: the evidence claims"* ]]; then ok "evidence claiming 300 rows against a 1-row backup is refused by the buyer's own restore"; else bad "a lying restore evidence was accepted: $out"; fi

echo "== 8. status alone reconstructs the run, three contracts deep"
out=$(bin/consortium-run.sh status 2>&1) || true
if [[ "$out" == *"c-research-1: softwareco -> researchco 40000c state=settled"* ]] && [[ "$out" == *"c-software-1: softwareco -> softwareco 60000c state=settled"* ]] && [[ "$out" == *"c-operable-1: softwareco -> softwareco 30000c state=settled"* ]]; then ok "status reads all three contracts back with no process state"; else bad "status did not list three settled contracts: $out"; fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
