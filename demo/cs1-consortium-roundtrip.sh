#!/usr/bin/env bash
# cs1-consortium-roundtrip.sh -- run 1 of the consortium through its real
# commands (bin/consortium-run.sh phases), against a temp workspace, with a
# fixture report standing in for ResearchCo's model run. Proves the loop the
# freeze document requires: request -> bid -> procurement -> award ->
# commitment -> delivery re-checked by the buyer -> Ambiguous held for the
# human -> answer -> settlement by the 100/50/0 rule. No model, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
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

echo "== 1. open: treasuries funded, research bought from ResearchCo, price reserved"
out=$(bin/consortium-run.sh open 2>&1) || true
if [[ "$out" == *"c-research-1 awarded: softwareco buys opportunity-research/v1 from researchco for 40000c"* ]] && [[ "$out" == *"softwareco: balance=200000c committed=40000c available=160000c"* ]] && [[ "$out" == *"researchco: balance=100000c committed=0c"* ]]; then ok "contract awarded and 40000c reserved on the buyer"; else bad "open did not award/reserve: $out"; fi
case "$out" in *"[answered by a human, not by you] human:would-fund"*) ok "the goal marks the human criterion as not the machine's" ;; *) bad "the goal does not mark the human criterion" ;; esac
if [ -f "$LOOM_WORKSPACE/researchco.company.toml" ] && command grep -q 'packs = \["core", "research"\]' "$LOOM_WORKSPACE/researchco.company.toml" && command grep -q 'path  = "research-report"' "$LOOM_WORKSPACE/researchco.company.toml"; then ok "ResearchCo manifest written with the research pack and the document path"; else bad "no usable ResearchCo manifest"; fi
python3 -c 'import tomllib,sys; m=tomllib.load(open(sys.argv[1],"rb")); assert "checkable:sources-grounded" in m["identity"]["mission"]' "$LOOM_WORKSPACE/researchco.company.toml" && ok "the manifest parses as TOML and its mission carries the criteria" || bad "the manifest does not parse or lost the criteria"

echo "== 2. open again is refused and reserves nothing more"
out=$(bin/consortium-run.sh open 2>&1) || true
case "$out" in *"already open"*) ok "second open refused" ;; *) bad "second open not refused: $out" ;; esac

echo "== 3. deliver: the buyer re-runs the gate; the human's half holds the verdict Ambiguous"
report > "$LOOM_WORKSPACE/researchco/report.md"
out=$(bin/consortium-run.sh deliver 2>&1) || true
if [[ "$out" == *"RESEARCH_REPORT_OK"* ]] && [[ "$out" == *"c-research-1 verified: ambiguous; awaiting: human:would-fund"* ]] && [[ "$out" == *"QUESTION FOR THE FOUNDER"* ]] && [[ "$out" == *"committed=40000c"* ]]; then ok "delivery verified by the buyer's own checker run; commitment held; founder asked"; else bad "deliver did not hold Ambiguous with the question: $out"; fi

echo "== 4. the founder says yes: settled in full by the freeze rule"
out=$(ANSWER=yes NOTE='fund it' bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"c-research-1 settled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]] && [[ "$out" == *"should terminate=yes"* ]]; then ok "settled: 40000c paid, commitment cleared, run terminal"; else bad "yes did not settle 40000c: $out"; fi
out=$(ANSWER=no bin/consortium-run.sh answer 2>&1) || true
case "$out" in *"answer FAILED"*) ok "a second answer on a settled contract is refused" ;; *) bad "a settled contract took another answer: $out" ;; esac

echo "== 4b. SoftwareCo contracts itself to build the settled report's product"
out=$(bin/consortium-run.sh open-software 2>&1) || true
if [[ "$out" == *"c-software-1 awarded: softwareco builds software-delivery/v1 itself for 60000c"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=60000c available=100000c"* ]]; then ok "software contract awarded as an internal build; 60000c reserved"; else bad "open-software did not award/reserve: $out"; fi
python3 -c 'import tomllib,sys; m=tomllib.load(open(sys.argv[1],"rb")); assert m["stack"]["path"]=="python-fastapi" and "CSV schema validation API" in m["identity"]["mission"] and "checkable:acceptance-passed" in m["identity"]["mission"]' "$LOOM_WORKSPACE/softwareco.company.toml" && ok "SoftwareCo manifest carries the report and the delivery criteria" || bad "SoftwareCo manifest missing or without the report"

echo "== 4c. deliver-software re-derives the evidence from the company's trail and workspace"
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests"
python3 - "$SW/company.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE company_iterations (company_id TEXT, idx INTEGER, sprint_id TEXT, parent_sprint_id TEXT DEFAULT '', status TEXT, started_at TEXT DEFAULT '', ended_at TEXT DEFAULT '')")
c.execute("CREATE TABLE traces (id INTEGER PRIMARY KEY, run_id TEXT, agent_id TEXT, event_kind TEXT, data_json TEXT, ts TEXT)")
c.execute("INSERT INTO company_iterations VALUES ('softwareco', 1, 'softwareco/iter-1', '', 'success', '', '')")
c.execute("INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('softwareco/iter-1', 'orch', 'acceptance_passed', '{}', '2026-09-09T00:00:00Z')")
c.commit()
PY
# Run 1 live: the product landed in main.py, app.py stayed the skeleton's.
cp paths/python-fastapi/app.py "$SW/app.py"
printf 'from fastapi import FastAPI\napp = FastAPI()\n\n@app.post("/validate")\ndef validate(row: dict):\n    return {"ok": True}\n' > "$SW/main.py"
printf 'def test_validate_rejects_bad_row():\n    assert True\n' > "$SW/tests/test_validate.py"
out=$(bin/consortium-run.sh deliver-software 2>&1) || true
if [[ "$out" == *"SOFTWARE_DELIVERY_OK"* ]] && [[ "$out" == *"c-software-1 settled: fulfilled"* ]] && [[ "$out" == *"softwareco: balance=100000c committed=0c"* ]] && [[ "$out" == *"objective met=yes; should terminate=yes"* ]]; then ok "delivery verified from the trail (product in main.py, not app.py); settled in full; run 1 terminal"; else bad "deliver-software did not settle: $out"; fi

echo "== 4d. sabotage: a workspace still holding the skeleton's app.py is half a delivery"
rm -rf "$LOOM_WORKSPACE"; mkdir -p "$LOOM_WORKSPACE/researchco"
bin/consortium-run.sh open >/dev/null 2>&1; report > "$LOOM_WORKSPACE/researchco/report.md"; bin/consortium-run.sh deliver >/dev/null 2>&1; ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1; bin/consortium-run.sh open-software >/dev/null 2>&1
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests"
python3 - "$SW/company.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE company_iterations (company_id TEXT, idx INTEGER, sprint_id TEXT, parent_sprint_id TEXT DEFAULT '', status TEXT, started_at TEXT DEFAULT '', ended_at TEXT DEFAULT '')")
c.execute("CREATE TABLE traces (id INTEGER PRIMARY KEY, run_id TEXT, agent_id TEXT, event_kind TEXT, data_json TEXT, ts TEXT)")
c.execute("INSERT INTO company_iterations VALUES ('softwareco', 1, 'softwareco/iter-1', '', 'success', '', '')")
c.execute("INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('softwareco/iter-1', 'orch', 'acceptance_passed', '{}', '2026-09-09T00:00:00Z')")
c.commit()
PY
cp paths/python-fastapi/app.py "$SW/app.py"; cp paths/python-fastapi/tests/test_app.py "$SW/tests/test_app.py"
out=$(bin/consortium-run.sh deliver-software 2>&1) || true
if [[ "$out" == *"partially fulfilled; unmet: checkable:app-present, checkable:tests-present"* ]] && [[ "$out" == *"softwareco: balance=130000c committed=0c"* ]]; then ok "skeleton-only workspace pays 50%: the trail said passed, the workspace says nothing was built"; else bad "a skeleton-only workspace was paid in full: $out"; fi

echo "== 5. a report the gate refuses (sabotage: sources outside the ledger) pays nothing"
rm -rf "$LOOM_WORKSPACE"; mkdir -p "$LOOM_WORKSPACE/researchco"
bin/consortium-run.sh open >/dev/null 2>&1
report | sed 's|https://flatfile.com/pricing|https://numverify.com/|' > "$LOOM_WORKSPACE/researchco/report.md"
out=$(bin/consortium-run.sh deliver 2>&1) || true
case "$out" in *"checkable:sources-grounded"*"ambiguous"*) ok "a remembered source is refused by the buyer's checker run; verdict still waits for the human" ;; *) bad "the buyer accepted a report its own gate refuses: $out" ;; esac
out=$(ANSWER=yes bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"partially fulfilled; unmet: checkable:sources-grounded"* ]] && [[ "$out" == *"softwareco: balance=180000c committed=0c"* ]]; then ok "one unmet checkable criterion pays 50%: 20000c"; else bad "the 50% rule did not apply: $out"; fi

echo "== 6. status alone reconstructs the run from the tables"
out=$(bin/consortium-run.sh status 2>&1) || true
if [[ "$out" == *"run-1: opened at"* ]] && [[ "$out" == *"c-research-1: softwareco -> researchco 40000c state=settled"* ]]; then ok "status reads the run back with no process state"; else bad "status incomplete: $out"; fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
