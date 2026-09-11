#!/usr/bin/env bash
# cs3-launch-contract-roundtrip.sh -- run 2's launch-delivery contract
# (#447, Run B) through its real commands, on top of run 1's research and
# software contracts and run 2's operable contract (rebuilt here exactly as
# cs2 does; the operable one settles at 50%, offline). Proves:
#   - open-launch waits for the settled operable contract and reserves 30000c;
#   - deliver-launch re-derives the checkable half from what loom recorded
#     (accepted community / lifecycle / release_manager nodes, by the graph's
#     role) and from what the PRODUCT recorded, COUNTED by the buyer in the
#     product's own store through launch/evidence.json's read-only queries;
#   - the three human criteria (publish, send, product created) hold the
#     contract Ambiguous and are answered one ATTR at a time; the last answer
#     settles by the 100/50/0 rule;
#   - a store with 3 signups fails Stage 0 no matter what the file says;
#     a human "no" on product-created settles at 50%.
# No model, no network, no real host.
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
if [[ "$out" == *"c-research-1 settled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]] && [[ "$out" == *"researchco: balance=140000c committed=0c"* ]] && [[ "$out" == *"should terminate=yes"* ]]; then ok "settled: 40000c left the buyer AND arrived at the supplier, commitment cleared, run terminal"; else bad "yes did not settle 40000c: $out"; fi
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
if [[ "$out" == *"SOFTWARE_DELIVERY_OK"* ]] && [[ "$out" == *"c-software-1 settled: fulfilled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]] && [[ "$out" == *"objective met=yes; should terminate=yes"* ]]; then ok "delivery verified from the trail (product in main.py, not app.py); settled in full; run 1 terminal"; else bad "deliver-software did not settle: $out"; fi

echo "== 5. open-operable waits for the settled software contract, then reserves 30000c"
out=$(bin/consortium-run.sh open-operable 2>&1) || true
if [[ "$out" == *"c-operable-1 awarded: softwareco makes operable-delivery/v1 itself for 30000c"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=30000c available=130000c"* ]]; then ok "operable contract awarded as an internal build; 30000c reserved"; else bad "open-operable did not award/reserve: $out"; fi
[ -f "$LOOM_WORKSPACE/softwareco-operable.company.toml" ] && grep -q 'packs = \["core", "ops", "governance"\]' "$LOOM_WORKSPACE/softwareco-operable.company.toml" && ok "operable manifest carries the ops and governance packs" || bad "operable manifest missing or without the packs"

echo "== 6. deliver-operable re-derives every criterion; offline, TLS is the one it cannot"
python3 - "$SW/company.db" <<'PY2'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE sprint_graphs (id TEXT PRIMARY KEY, sprint_id TEXT, phase TEXT, graph_json TEXT, created_at TEXT)")
c.execute("CREATE TABLE node_results (id TEXT PRIMARY KEY, sprint_id TEXT, node_id TEXT, phase TEXT, accepted INTEGER, artifact TEXT DEFAULT '', reason TEXT DEFAULT '', created_at TEXT)")
g = {"id": "softwareco/iter-1", "phase": "Implementation", "nodes": [{"id": "pm", "role": "pm", "gate": "spec non-empty"}, {"id": "release-runbook", "role": "release_manager", "gate": "spec judge x"}, {"id": "dpa", "role": "data_protection", "gate": "spec judge y"}], "edges": []}
c.execute("INSERT INTO sprint_graphs VALUES ('g1', 'softwareco/iter-1', 'Implementation', ?, 't')", (json.dumps(g),))
for nid in ("pm", "release-runbook", "dpa"):
    c.execute("INSERT INTO node_results VALUES (?, 'softwareco/iter-1', ?, 'Implementation', 1, 'x', '', 't')", (nid + "-r", nid))
c.commit()
PY2
mkdir -p "$SW/ops" "$SW/backup"
printf '# PRD\n## Success metrics\n- Activation: %% of accounts with a first `submission_delivered` within 7 days\n' > "$SW/prd.md"
printf 'def deliver(s):\n    track("submission_delivered", {"id": s})\n' > "$SW/analytics_hooks.py"
python3 - "$SW" <<'PY2'
import sqlite3, sys, json
sw = sys.argv[1]
p = sqlite3.connect(f"{sw}/backup/product.sqlite"); p.executescript("create table submissions(id); insert into submissions values (1),(2),(3);"); p.commit(); p.close()
json.dump({"backup": "backup/product.sqlite", "tables": {"submissions": 3}}, open(f"{sw}/ops/restore-evidence.json", "w"))
PY2
out=$(bin/consortium-run.sh deliver-operable 2>&1) || true
if [[ "$out" == *"OPERABLE_DELIVERY_VERIFIED checkable:iteration-passed checkable:acceptance-passed checkable:metrics-instrumented checkable:restore-performed checkable:runbook-present checkable:data-map-present"* ]]; then ok "the buyer re-derived six criteria by re-running the roles' own gates"; else bad "checker did not verify the six offline criteria: $out"; fi
if [[ "$out" == *"partially fulfilled; unmet: checkable:reachable-over-tls"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]]; then ok "offline settles at 50% with exactly TLS unmet; commitment released"; else bad "offline operable delivery did not settle at 50% on TLS alone: $out"; fi

echo "== 7. open-launch waits for the settled operable contract, then reserves 30000c"
out=$(bin/consortium-run.sh open-launch 2>&1) || true
if [[ "$out" == *"c-launch-1 awarded: softwareco makes launch-delivery/v1 itself for 30000c"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=30000c available=130000c"* ]]; then ok "launch contract awarded as an internal build; 30000c reserved"; else bad "open-launch did not award: $out"; fi
[ -f "$LOOM_WORKSPACE/softwareco-launch.company.toml" ] && grep -q 'packs = \["core", "ops", "growth", "content", "governance"\]' "$LOOM_WORKSPACE/softwareco-launch.company.toml" && ok "launch manifest carries the growth and content packs" || bad "launch manifest missing or without growth pack"
python3 -c 'import tomllib,sys; m=tomllib.load(open(sys.argv[1],"rb")); assert "human:approved-to-publish" in m["identity"]["mission"] and "checkable:paying-customer" in m["identity"]["mission"]' "$LOOM_WORKSPACE/softwareco-launch.company.toml" && ok "the mission carries the human and checkable criteria" || bad "mission lacks the launch criteria"
out=$(bin/consortium-run.sh open-launch 2>&1) || true
case "$out" in *"already open"*) ok "second open-launch refused" ;; *) bad "second open-launch not refused: $out" ;; esac

echo "== 8. deliver-launch: the roles' nodes are there, the store is not; humans asked"
python3 - "$SW/company.db" <<'PY3'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
g = {"id": "softwareco/iter-1", "phase": "Implementation", "nodes": [{"id": "channels", "role": "community", "gate": "spec judge x"}, {"id": "welcome", "role": "lifecycle", "gate": "spec judge x"}], "edges": []}
c.execute("INSERT INTO sprint_graphs VALUES ('g2', 'softwareco/iter-1', 'Implementation', ?, 't')", (json.dumps(g),))
for nid in ("channels", "welcome"):
    c.execute("INSERT INTO node_results VALUES (?, 'softwareco/iter-1', ?, 'Implementation', 1, 'x', '', 't')", (nid + "-r", nid))
c.commit()
PY3
out=$(bin/consortium-run.sh deliver-launch 2>&1) || true
if [[ "$out" == *"LAUNCH_DELIVERY_VERIFIED checkable:iteration-passed checkable:channel-plan-present checkable:welcome-sequence-present checkable:launch-runbook-present"* ]] && [[ "$out" == *"checkable:waitlist-threshold: no launch/evidence.json"* ]]; then ok "loom's half re-derived by role; the product's half unmet without a store"; else bad "deliver-launch did not split the halves: $out"; fi
if [[ "$out" == *"c-launch-1 verified: ambiguous; awaiting: "*"human:approved-to-publish"* ]] && [[ "$out" == *"QUESTION FOR THE FOUNDER: human:product-created:"* ]] && [[ "$out" == *"committed=30000c"* ]]; then ok "held Ambiguous on the three human criteria; three questions printed; nothing settled"; else bad "human half not held: $out"; fi

echo "== 9. answers land one criterion at a time; the last one settles at 50%"
out=$(CONTRACT_ID=c-launch-1 ATTR=human:approved-to-publish ANSWER=yes NOTE='posts read fine' bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"ambiguous; awaiting: human:approved-to-send, human:product-created"* ]] && [[ "$out" == *"committed=30000c"* ]]; then ok "publish answered; still awaiting send and product; still reserved"; else bad "first answer did not narrow the wait: $out"; fi
out=$(CONTRACT_ID=c-launch-1 ATTR=human:not-a-criterion ANSWER=yes bin/consortium-run.sh answer 2>&1) || true
case "$out" in *"has no human criterion human:not-a-criterion"*) ok "an attr the contract does not list is refused" ;; *) bad "stray attr accepted: $out" ;; esac
out=$(CONTRACT_ID=c-launch-1 ATTR=human:approved-to-send ANSWER=yes bin/consortium-run.sh answer 2>&1) || true
out=$(CONTRACT_ID=c-launch-1 ATTR=human:product-created ANSWER=yes NOTE='Stripe product live' bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"c-launch-1 settled: partially fulfilled; unmet: checkable:waitlist-threshold, checkable:first-genuine-submission, checkable:paying-customer"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]]; then ok "last answer settles at 50%: humans yes, product evidence absent; commitment released"; else bad "did not settle at 50% on the product half: $out"; fi

echo "== 10. fresh round: the product's own store meets every stage; settled in full"
rm -rf "$LOOM_WORKSPACE"; mkdir -p "$LOOM_WORKSPACE/researchco"
bin/consortium-run.sh open >/dev/null 2>&1; report > "$LOOM_WORKSPACE/researchco/report.md"; bin/consortium-run.sh deliver >/dev/null 2>&1; ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1; bin/consortium-run.sh open-software >/dev/null 2>&1
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests" "$SW/ops" "$SW/backup" "$SW/launch" "$SW/data"
python3 - "$SW/company.db" <<'PY3'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE company_iterations (company_id TEXT, idx INTEGER, sprint_id TEXT, parent_sprint_id TEXT DEFAULT '', status TEXT, started_at TEXT DEFAULT '', ended_at TEXT DEFAULT '')")
c.execute("CREATE TABLE traces (id INTEGER PRIMARY KEY, run_id TEXT, agent_id TEXT, event_kind TEXT, data_json TEXT, ts TEXT)")
c.execute("INSERT INTO company_iterations VALUES ('softwareco', 1, 'softwareco/iter-1', '', 'success', '', '')")
c.execute("INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('softwareco/iter-1', 'orch', 'acceptance_passed', '{}', '2026-09-11T00:00:00Z')")
c.execute("CREATE TABLE sprint_graphs (id TEXT PRIMARY KEY, sprint_id TEXT, phase TEXT, graph_json TEXT, created_at TEXT)")
c.execute("CREATE TABLE node_results (id TEXT PRIMARY KEY, sprint_id TEXT, node_id TEXT, phase TEXT, accepted INTEGER, artifact TEXT DEFAULT '', reason TEXT DEFAULT '', created_at TEXT)")
g = {"id": "softwareco/iter-1", "phase": "Implementation", "nodes": [{"id": "release-runbook", "role": "release_manager", "gate": "spec judge x"}, {"id": "dpa", "role": "data_protection", "gate": "spec judge x"}, {"id": "channels", "role": "community", "gate": "spec judge x"}, {"id": "welcome", "role": "lifecycle", "gate": "spec judge x"}], "edges": []}
c.execute("INSERT INTO sprint_graphs VALUES ('g1', 'softwareco/iter-1', 'Implementation', ?, 't')", (json.dumps(g),))
for nid in ("release-runbook", "dpa", "channels", "welcome"):
    c.execute("INSERT INTO node_results VALUES (?, 'softwareco/iter-1', ?, 'Implementation', 1, 'x', '', 't')", (nid + "-r", nid))
c.commit()
PY3
cp paths/python-fastapi/app.py "$SW/app.py"; printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$SW/main.py"; printf 'def test_x():\n    assert True\n' > "$SW/tests/test_x.py"
printf '# PRD\n## Success metrics\n- Activation: %% of accounts with a first `submission_delivered` within 7 days\n' > "$SW/prd.md"
printf 'def deliver(s):\n    track("submission_delivered", {"id": s})\n' > "$SW/analytics_hooks.py"
python3 - "$SW" <<'PY3'
import sqlite3, sys, json
sw = sys.argv[1]
p = sqlite3.connect(f"{sw}/backup/product.sqlite"); p.executescript("create table submissions(id); insert into submissions values (1),(2),(3);"); p.commit(); p.close()
json.dump({"backup": "backup/product.sqlite", "tables": {"submissions": 3}}, open(f"{sw}/ops/restore-evidence.json", "w"))
# the product's own store: 120 signups (17 would pay), one genuine submission, one paid customer
s = sqlite3.connect(f"{sw}/data/app.sqlite")
s.executescript("create table waitlist(email, would_pay integer); create table submissions(id, genuine integer, created_at); create table payments(id, status);")
s.executemany("insert into waitlist values (?, ?)", [(f"dev{i}@example.eu", 1 if i < 17 else 0) for i in range(120)])
s.execute("insert into submissions values (1, 1, '2026-10-02T09:00:00Z')"); s.execute("insert into submissions values (2, 0, '2026-10-02T09:01:00Z')")
s.execute("insert into payments values ('pay_1', 'paid')"); s.commit(); s.close()
json.dump({"db": "data/app.sqlite", "waitlist_signups_sql": "select count(*) from waitlist", "would_pay_sql": "select count(*) from waitlist where would_pay=1", "first_genuine_submission_sql": "select min(created_at) from submissions where genuine=1", "paying_customers_sql": "select count(*) from payments where status='paid'"}, open(f"{sw}/launch/evidence.json", "w"))
PY3
bin/consortium-run.sh deliver-software >/dev/null 2>&1; bin/consortium-run.sh open-operable >/dev/null 2>&1; bin/consortium-run.sh deliver-operable >/dev/null 2>&1
out=$(bin/consortium-run.sh open-launch 2>&1) || true
[[ "$out" == *"c-launch-1 awarded"* ]] && ok "launch opened on top of a 50% operable settlement" || bad "open-launch after operable failed: $out"
out=$(bin/consortium-run.sh deliver-launch 2>&1) || true
if [[ "$out" == *"LAUNCH_DELIVERY_OK checkable:iteration-passed checkable:channel-plan-present checkable:welcome-sequence-present checkable:launch-runbook-present checkable:waitlist-threshold checkable:first-genuine-submission checkable:paying-customer"* ]] && [[ "$out" == *"ambiguous; awaiting: human:approved-to-publish, human:approved-to-send, human:product-created"* ]]; then ok "every checkable met by counting in the store; the human half still waits"; else bad "full store did not verify: $out"; fi
CONTRACT_ID=c-launch-1 ATTR=human:approved-to-publish ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1
CONTRACT_ID=c-launch-1 ATTR=human:approved-to-send ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1
out=$(CONTRACT_ID=c-launch-1 ATTR=human:product-created ANSWER=yes bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"c-launch-1 settled: fulfilled"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]]; then ok "settled in full: the buyer counted, the founder answered"; else bad "did not settle in full: $out"; fi

echo "== 11. sabotage: a store with 3 signups fails Stage 0 whatever the file says; a human no settles at 50%"
rm -rf "$LOOM_WORKSPACE"; mkdir -p "$LOOM_WORKSPACE/researchco"
bin/consortium-run.sh open >/dev/null 2>&1; report > "$LOOM_WORKSPACE/researchco/report.md"; bin/consortium-run.sh deliver >/dev/null 2>&1; ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1; bin/consortium-run.sh open-software >/dev/null 2>&1
SW="$LOOM_WORKSPACE/softwareco"; mkdir -p "$SW/tests" "$SW/ops" "$SW/backup" "$SW/launch" "$SW/data"
python3 - "$SW/company.db" <<'PY3'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE company_iterations (company_id TEXT, idx INTEGER, sprint_id TEXT, parent_sprint_id TEXT DEFAULT '', status TEXT, started_at TEXT DEFAULT '', ended_at TEXT DEFAULT '')")
c.execute("CREATE TABLE traces (id INTEGER PRIMARY KEY, run_id TEXT, agent_id TEXT, event_kind TEXT, data_json TEXT, ts TEXT)")
c.execute("INSERT INTO company_iterations VALUES ('softwareco', 1, 'softwareco/iter-1', '', 'success', '', '')")
c.execute("INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('softwareco/iter-1', 'orch', 'acceptance_passed', '{}', '2026-09-11T00:00:00Z')")
c.execute("CREATE TABLE sprint_graphs (id TEXT PRIMARY KEY, sprint_id TEXT, phase TEXT, graph_json TEXT, created_at TEXT)")
c.execute("CREATE TABLE node_results (id TEXT PRIMARY KEY, sprint_id TEXT, node_id TEXT, phase TEXT, accepted INTEGER, artifact TEXT DEFAULT '', reason TEXT DEFAULT '', created_at TEXT)")
g = {"id": "softwareco/iter-1", "phase": "Implementation", "nodes": [{"id": "release-runbook", "role": "release_manager", "gate": "spec judge x"}, {"id": "dpa", "role": "data_protection", "gate": "spec judge x"}, {"id": "channels", "role": "community", "gate": "spec judge x"}, {"id": "welcome", "role": "lifecycle", "gate": "spec judge x"}], "edges": []}
c.execute("INSERT INTO sprint_graphs VALUES ('g1', 'softwareco/iter-1', 'Implementation', ?, 't')", (json.dumps(g),))
for nid in ("release-runbook", "dpa", "channels", "welcome"):
    c.execute("INSERT INTO node_results VALUES (?, 'softwareco/iter-1', ?, 'Implementation', 1, 'x', '', 't')", (nid + "-r", nid))
c.commit()
PY3
cp paths/python-fastapi/app.py "$SW/app.py"; printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$SW/main.py"; printf 'def test_x():\n    assert True\n' > "$SW/tests/test_x.py"
printf '# PRD\n## Success metrics\n- Activation: %% of accounts with a first `submission_delivered` within 7 days\n' > "$SW/prd.md"
printf 'def deliver(s):\n    track("submission_delivered", {"id": s})\n' > "$SW/analytics_hooks.py"
python3 - "$SW" <<'PY3'
import sqlite3, sys, json
sw = sys.argv[1]
p = sqlite3.connect(f"{sw}/backup/product.sqlite"); p.executescript("create table submissions(id); insert into submissions values (1),(2),(3);"); p.commit(); p.close()
json.dump({"backup": "backup/product.sqlite", "tables": {"submissions": 3}}, open(f"{sw}/ops/restore-evidence.json", "w"))
s = sqlite3.connect(f"{sw}/data/app.sqlite")
s.executescript("create table waitlist(email, would_pay integer); create table submissions(id, genuine integer, created_at); create table payments(id, status);")
s.executemany("insert into waitlist values (?, ?)", [(f"dev{i}@example.eu", 1 if i < 2 else 0) for i in range(3)])
s.execute("insert into submissions values (1, 1, '2026-10-02T09:00:00Z')"); s.execute("insert into payments values ('pay_1', 'paid')"); s.commit(); s.close()
# the supplier's own numbers in the file are never read: only the queries are
json.dump({"db": "data/app.sqlite", "waitlist_signups": 500, "would_pay": 40, "waitlist_signups_sql": "select count(*) from waitlist", "would_pay_sql": "select count(*) from waitlist where would_pay=1", "first_genuine_submission_sql": "select min(created_at) from submissions where genuine=1", "paying_customers_sql": "delete from payments"}, open(f"{sw}/launch/evidence.json", "w"))
PY3
bin/consortium-run.sh deliver-software >/dev/null 2>&1; bin/consortium-run.sh open-operable >/dev/null 2>&1; bin/consortium-run.sh deliver-operable >/dev/null 2>&1; bin/consortium-run.sh open-launch >/dev/null 2>&1
out=$(bin/consortium-run.sh deliver-launch 2>&1) || true
if [[ "$out" == *"checkable:waitlist-threshold: counted 3 signups and 2 would-pay; Stage 0 needs 100 or 15"* ]] && [[ "$out" == *"checkable:paying-customer: not a SELECT"* ]]; then ok "the buyer counted 3, not the file's 500; a non-SELECT query is refused, not run"; else bad "sabotage not caught: $out"; fi
python3 -c 'import sqlite3,sys; assert sqlite3.connect(sys.argv[1]).execute("select count(*) from payments").fetchone()[0]==1' "$SW/data/app.sqlite" && ok "the store was opened read-only: the delete never ran" || bad "the delete ran against the product store"
CONTRACT_ID=c-launch-1 ATTR=human:approved-to-publish ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1
CONTRACT_ID=c-launch-1 ATTR=human:approved-to-send ANSWER=yes bin/consortium-run.sh answer >/dev/null 2>&1
out=$(CONTRACT_ID=c-launch-1 ATTR=human:product-created ANSWER=no NOTE='not creating a product for 3 signups' bin/consortium-run.sh answer 2>&1) || true
if [[ "$out" == *"c-launch-1 settled: partially fulfilled; unmet: "*"human:product-created"* ]] && [[ "$out" == *"softwareco: balance=160000c committed=0c"* ]]; then ok "a human no is an unmet criterion: settled at 50%, reservation released"; else bad "human no did not settle at 50%: $out"; fi

echo "== 12. status alone reconstructs the round, four contracts deep"
out=$(bin/consortium-run.sh status 2>&1) || true
if [[ "$out" == *"c-operable-1: softwareco -> softwareco 30000c state=settled"* ]] && [[ "$out" == *"c-launch-1: softwareco -> softwareco 30000c state=settled"* ]]; then ok "status lists the operable and launch contracts settled"; else bad "status did not list four contracts: $out"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
