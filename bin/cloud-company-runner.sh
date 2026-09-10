#!/usr/bin/env bash
# cloud-company-runner.sh -- runner protocol v2 (loom-cloud#47): the cloud
# holds companies and board decisions; this machine executes.
#
#   LOOM_SERVER=http://127.0.0.1:8880 LOOM_RUNNER_TOKEN=<runner key from the dashboard's Runners page> bin/cloud-company-runner.sh [--once]
#
# Loop: claim one queued company (POST /api/runners/poll-company), run it
# here, report iterations + events + status (POST /api/companies/:id/report).
# kind=consortium-research: the company is ResearchCo under the consortium's
# research contract (bin/consortium-run.sh open/research/deliver); the
# contract's human criterion becomes a board decision the founder answers in
# the dashboard; this runner polls for it and settles (answer). A "yes" then
# continues the round on the same card: open-software, SoftwareCo builds the
# product (software), the sealed artifact is re-executed and the delivery
# contract settled (deliver-software). Both companies' iterations and a
# consortium_status snapshot (treasuries, contracts, portfolio, phase) are
# reported, so the dashboard holds everything the founder needs.
# kind=company: bin/bootstrap-company.sh on the manifest, then report.
#
#   bin/cloud-company-runner.sh report-consortium <company-uuid>
# re-reports an existing consortium workspace (both companies + snapshot),
# for a round whose later phases ran outside this runner.
#
# Nothing here touches real money, a host, or a publish; the cloud never
# executes anything.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LOOM_SERVER:?LOOM_SERVER is required}"; : "${LOOM_RUNNER_TOKEN:?LOOM_RUNNER_TOKEN is required}"
ONCE="${1:-}"
WS_ROOT="${LOOM_WORKSPACE:-$HOME/loom-companies}"

jpost() { # path json-file -> body (fails loudly on non-2xx)
  local out; out=$(curl -sS --max-time 40 -w '\n%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $LOOM_RUNNER_TOKEN" -d @"$2" "$LOOM_SERVER$1"); local code="${out##*$'\n'}"; local body="${out%$'\n'*}"
  if [ "${code:0:1}" != "2" ]; then echo "[runner] $1 -> $code: $body" >&2; return 1; fi; printf '%s' "$body"
}
with_token() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["runner_token"]=sys.argv[2]; print(json.dumps(d))' "$1" "$LOOM_RUNNER_TOKEN"; }
report() { # company-uuid json-fields
  local f; f=$(mktemp); with_token "$2" > "$f"; jpost "/api/companies/$1/report" "$f" >/dev/null; rm -f "$f"
}
# `nodes` carries each iteration's gate results (loom's node_results): which
# node its gate accepted, and the gate's own words when it refused. The cloud
# used to be told only THAT iteration 1 failed, so the reason -- `launch`
# returned ok:false, `py-qa` came back FAIL -- stayed in a company.db the
# founder would have had to open a shell to read. Keyed by the same offset
# iteration index the iterations rows use, so both halves line up on one card.
#
# IDX_OFFSET / SEQ_OFFSET (env, default 0): a second company reported onto
# the same card (SoftwareCo after ResearchCo) must not collide with the
# first one's iteration numbers and event sequence -- the cloud upserts
# iterations on (company, idx) and ignores duplicate (company, seq) events.
# EXTRA_EVENTS_JSON (env, optional): a JSON list of {kind, data} appended
# after the trail events (the consortium_status snapshot), in a sequence
# band the trail never reaches and keyed by the second, so every report
# stores its snapshot and the dashboard shows the newest.
report_from_db() { # company-uuid company.db status last_verdict summary
  local f; f=$(mktemp)
  IDX_OFFSET="${IDX_OFFSET:-0}" SEQ_OFFSET="${SEQ_OFFSET:-0}" EXTRA_EVENTS_JSON="${EXTRA_EVENTS_JSON:-[]}" python3 - "$2" "$3" "$4" "$5" "$LOOM_RUNNER_TOKEN" > "$f" <<'PY'
import sqlite3, json, sys, os, datetime, time
db, status, verdict, summary, tok = sys.argv[1:6]
ioff, soff = int(os.environ.get("IDX_OFFSET") or 0), int(os.environ.get("SEQ_OFFSET") or 0)
its, evs, nodes = [], [], []
try:
    c = sqlite3.connect(db)
    its = [dict(idx=r[0] + ioff, sprint_id=r[1], status=r[2], started_at=r[3], ended_at=r[4]) for r in c.execute("select idx, sprint_id, status, started_at, ended_at from company_iterations order by idx")]
    sprint_idx = {r[1]: r[0] + ioff for r in c.execute("select idx, sprint_id from company_iterations")}
    for r in c.execute("select sprint_id, node_id, phase, accepted, reason from node_results order by created_at"):
        idx = sprint_idx.get(r[0])
        if idx is not None:
            nodes.append(dict(idx=idx, node_id=r[1], phase=r[2] or "", accepted=bool(r[3]), reason=(r[4] or "")[:2000]))
    rows = c.execute("select ts, event_kind, data_json from traces where event_kind in ('stage_transition','goal_decision','sprint_complete','acceptance_passed','acceptance_failed','node_denied','treasury_opened','company_parked','qa_skipped_document_sprint') order by ts").fetchall()
    for i, (ts, k, d) in enumerate(rows[-400:]):
        try: data = json.loads(d)
        except Exception: data = {"raw": (d or "")[:300]}
        evs.append(dict(seq=soff + i, kind=k, data=data, ts=ts))
except Exception as e:
    evs.append(dict(seq=soff, kind="runner_error", data={"error": str(e)}, ts=""))
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
for j, e in enumerate(json.loads(os.environ.get("EXTRA_EVENTS_JSON") or "[]")):
    evs.append(dict(seq=1000000 + int(time.time()) % 100000000 + j, kind=e["kind"], data=e.get("data", {}), ts=now))
print(json.dumps(dict(runner_token=tok, status=status, last_verdict=verdict, summary=summary, iterations=its, events=evs, nodes=nodes)))
PY
  jpost "/api/companies/$1/report" "$f" >/dev/null; rm -f "$f"
}

# The consortium's state as one JSON event, parsed from the same status text
# the CLI prints (bin/consortium-run.sh status): treasuries, contracts,
# portfolio, plus which phase the round is in. The dashboard renders it as
# the Consortium section and drives its guidance from `phase`.
consortium_snapshot() { # phase -> JSON list with one {kind, data}
  local phase="$1" txt
  txt=$(bin/consortium-run.sh status 2>/dev/null || true)
  PHASE="$phase" python3 - "$txt" <<'PY'
import sys, re, json, os
txt = sys.argv[1]
d = {"phase": os.environ["PHASE"], "treasuries": [], "contracts": [], "portfolio": {}, "problem_space": ""}
m = re.search(r"problem space: (.*)", txt)
if m: d["problem_space"] = m.group(1).strip()
for m in re.finditer(r"^\s+(\w+): balance=(\d+)c committed=(\d+)c available=(\d+)c", txt, re.M):
    d["treasuries"].append(dict(company=m.group(1), balance_cents=int(m.group(2)), committed_cents=int(m.group(3)), available_cents=int(m.group(4))))
for m in re.finditer(r"^\s+(c-[\w-]+): (\w+) -> (\w+) (\d+)c state=(\w+)", txt, re.M):
    d["contracts"].append(dict(id=m.group(1), buyer=m.group(2), supplier=m.group(3), price_cents=int(m.group(4)), state=m.group(5)))
m = re.search(r"portfolio: spent=(\d+)c of max (\d+)c; open contracts=(\d+); objective met=(\w+); should terminate=(\w+)", txt)
if m: d["portfolio"] = dict(spent_cents=int(m.group(1)), max_spend_cents=int(m.group(2)), open_contracts=int(m.group(3)), objective_met=m.group(4) == "yes", should_terminate=m.group(5) == "yes")
print(json.dumps([{"kind": "consortium_status", "data": d}]))
PY
}

# Report the whole round from a workspace: ResearchCo's iterations/events,
# SoftwareCo's (offset so they sit after ResearchCo's on the card), and the
# snapshot. Used at every phase change and by `report-consortium <uuid>`.
report_consortium() { # uuid status last_verdict summary phase
  local uuid="$1" status="$2" verdict="$3" summary="$4" phase="$5" ws="$WS_ROOT/cloud-$1"
  local snap; snap=$(consortium_snapshot "$phase")
  if [ -f "$ws/softwareco/company.db" ]; then
    [ -f "$ws/researchco/company.db" ] && report_from_db "$uuid" "$ws/researchco/company.db" "running" "" "$summary"
    local n; n=$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from company_iterations").fetchone()[0])' "$ws/researchco/company.db" 2>/dev/null || echo 0)
    IDX_OFFSET="$n" SEQ_OFFSET=10000 EXTRA_EVENTS_JSON="$snap" report_from_db "$uuid" "$ws/softwareco/company.db" "$status" "$verdict" "$summary"
  elif [ -f "$ws/researchco/company.db" ]; then
    EXTRA_EVENTS_JSON="$snap" report_from_db "$uuid" "$ws/researchco/company.db" "$status" "$verdict" "$summary"
  else
    local f; f=$(mktemp)
    python3 -c 'import sys,json,time; ev=json.loads(sys.argv[4]); print(json.dumps({"runner_token":sys.argv[5],"status":sys.argv[1],"summary":sys.argv[2],"events":[dict(e, seq=1000000+int(time.time())%100000000, ts=sys.argv[3]) for e in ev]}))' "$status" "$summary" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$snap" "$LOOM_RUNNER_TOKEN" > "$f"
    jpost "/api/companies/$uuid/report" "$f" >/dev/null; rm -f "$f"
  fi
}

# After the founder funds the opportunity: the software-delivery contract,
# SoftwareCo building the product, acceptance re-executing the sealed
# artifact, settlement. Every phase change lands on the card.
run_consortium_software() { # uuid
  local uuid="$1" ws="$WS_ROOT/cloud-$1"
  bin/consortium-run.sh open-software > "$ws/open-software.log" 2>&1 || {
    report_consortium "$uuid" "failed" "" "software contract could not be awarded: $(command grep -o 'contract c-software-1.*\|refus.*' "$ws/open-software.log" | head -1 | cut -c1-200)" "software-refused"; return; }
  local award; award=$(command grep -o 'contract c-software-1 awarded.*' "$ws/open-software.log" | head -1 | cut -c1-200)
  report_consortium "$uuid" "running" "" "${award:-software contract awarded}; SoftwareCo building" "software-building"
  echo "[runner] software contract awarded; SoftwareCo building in $ws/softwareco"
  bin/consortium-run.sh software > "$ws/software.log" 2>&1 || true
  if [ ! -f "$ws/softwareco/company.db" ]; then
    local why; why=$(command grep -E '^\s*FAIL |\[company\] FATAL|\[bootstrap\] preflight failed' "$ws/software.log" | head -3 | tr '\n' ' ' | cut -c1-300)
    report_consortium "$uuid" "failed" "" "SoftwareCo did not start: ${why:-see software.log}" "software-failed"; return
  fi
  local v; v=$(command grep -o 'last_verdict=[a-z_]*' "$ws/software.log" | tail -1 | cut -d= -f2)
  report_consortium "$uuid" "running" "$v" "SoftwareCo finished (verdict ${v:-unknown}); re-executing the sealed artifact for acceptance" "software-delivering"
  bin/consortium-run.sh deliver-software > "$ws/deliver-software.log" 2>&1 || true
  local settled; settled=$(command grep -o 'contract c-software-1 [a-z]*: [^$]*' "$ws/deliver-software.log" | tail -1 | cut -c1-200)
  local final="done"; command grep -q 'settled: rejected\|state=cancelled' "$ws/deliver-software.log" && final="failed"
  echo "[runner] ${settled:-software contract settled}"
  report_consortium "$uuid" "$final" "$v" "round complete: research fulfilled; ${settled:-software contract settled}" "round-complete"
}

run_consortium_research() { # uuid manifest-file
  local uuid="$1" manifest="$2" ws="$WS_ROOT/cloud-$1"
  export LOOM_WORKSPACE="$ws"; export CONSORTIUM_DB="$ws/consortium.db"; mkdir -p "$ws"
  echo "[runner] consortium research for $uuid in $ws"
  bin/consortium-run.sh open > "$ws/open.log" 2>&1 || { report "$uuid" '{"status":"failed","summary":"consortium open failed"}'; return; }
  cp "$manifest" "$ws/researchco.company.toml"   # the founder's manifest wins over the generated one for identity/model; mission stays the contract goal
  python3 - "$ws/researchco.company.toml" "$ws/open.log" <<'PY'
import sys, re
path, log = sys.argv[1], sys.argv[2]
toml = open(path).read()
goal = open(log).read().split("[consortium] goal for ResearchCo:\n", 1)[1].split("\nrun-1:", 1)[0] if "[consortium] goal for ResearchCo:" in open(log).read() else ""
if goal:
    esc = goal.replace("\\", "\\\\").replace('"""', '\\"""')
    toml = re.sub(r'^mission\s*=.*?(?=^\[|\Z)', 'mission = """' + esc + '"""\n\n', toml, count=1, flags=re.M | re.S)
open(path, "w").write(toml)
PY
  report_consortium "$uuid" "running" "" "research contract awarded; ResearchCo researching" "research-running"
  bin/consortium-run.sh research > "$ws/research.log" 2>&1 || true
  # A company that never started (preflight refused it: no provider, model
  # not routed, key unset) has no company.db to report from; say why here
  # instead of "delivering" into a failure two steps later (#427).
  if [ ! -f "$ws/researchco/company.db" ]; then
    local why; why=$(command grep -E '^\s*FAIL |\[company\] FATAL|\[bootstrap\] preflight failed' "$ws/research.log" | head -3 | tr '\n' ' ' | cut -c1-300)
    report "$uuid" "$(python3 -c 'import sys,json; print(json.dumps({"status":"failed","summary":"ResearchCo did not start: "+(sys.argv[1] or "see research.log")}))' "$why")"
    echo "[runner] ResearchCo did not start: ${why:-see $ws/research.log}"
    return
  fi
  local rv; rv=$(command grep -o 'last_verdict=[a-z]*' "$ws/research.log" | tail -1 | cut -d= -f2)
  report_consortium "$uuid" "running" "$rv" "ResearchCo finished; checking the report against the contract" "research-delivering"
  bin/consortium-run.sh deliver > "$ws/deliver.log" 2>&1 || true
  if ! command grep -q 'awaiting: human:would-fund' "$ws/deliver.log"; then
    report_consortium "$uuid" "failed" "$rv" "$(command grep -o 'contract c-research-1 .*' "$ws/deliver.log" | head -1 | cut -c1-200)" "research-rejected"; return
  fi
  local ctx f; ctx=$(python3 -c 'import sys,json; r=open(sys.argv[1]).read() if __import__("os").path.exists(sys.argv[1]) else "(no report.md)"; print(json.dumps({"item_id":"human:would-fund","kind":"human-criterion","question":"Is the recommended opportunity one you would fund? (contract c-research-1, 40000c held on softwareco)","context_md":r}))' "$ws/researchco/report.md")
  f=$(mktemp); with_token "$ctx" > "$f"; jpost "/api/companies/$uuid/decisions" "$f" >/dev/null; rm -f "$f"
  report_consortium "$uuid" "awaiting-decision" "$rv" "report passed its gate; awaiting the founder on human:would-fund" "research-awaiting-founder"
  echo "[runner] waiting for the founder's answer in the dashboard..."
  local verdict="" reason=""
  while [ -z "$verdict" ]; do
    sleep 10
    f=$(mktemp); with_token '{"item_id":"human:would-fund"}' > "$f"
    local resp; resp=$(jpost "/api/companies/$uuid/decisions/poll" "$f" || echo '{}'); rm -f "$f"
    verdict=$(python3 -c 'import sys,json; ds=[d for d in json.loads(sys.argv[1]).get("decisions",[]) if d.get("status")=="decided"]; print(ds[0]["verdict"] if ds else "")' "$resp")
    reason=$(python3 -c 'import sys,json; ds=[d for d in json.loads(sys.argv[1]).get("decisions",[]) if d.get("status")=="decided"]; print((ds[0].get("reason") or "") if ds else "")' "$resp")
  done
  echo "[runner] founder answered: $verdict ($reason)"
  ANSWER="$verdict" NOTE="founder via loom-cloud: $reason" bin/consortium-run.sh answer > "$ws/answer.log" 2>&1 || true
  local settled; settled=$(command grep -o 'contract c-research-1 [a-z]*: [^$]*' "$ws/answer.log" | head -1 | cut -c1-160)
  if [ "$verdict" = "yes" ]; then
    report_consortium "$uuid" "running" "$rv" "${settled:-research settled}; awarding the software contract" "software-awarding"
    run_consortium_software "$uuid"
  else
    report_consortium "$uuid" "done" "$rv" "${settled:-research settled}; the founder did not fund it, round closed" "research-not-funded"
  fi
}

# A company with [policy] founding = true parks after writing its plan: the
# attention item becomes a board decision here, the founder answers in the
# dashboard (yes, optionally "budget_eur=N" in the reason), the runner
# resolves it through loom's one decide path and resumes the company.
run_plain_company() { # uuid manifest-file stop_when
  local uuid="$1" manifest="$2" ws="$WS_ROOT/cloud-$1"; mkdir -p "$ws"
  export LOOM_WORKSPACE="$ws"
  local cid; cid=$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["identity"]["id"])' "$manifest")
  report "$uuid" '{"status":"running"}'
  STOP_WHEN="$3" bin/bootstrap-company.sh "$manifest" > "$ws/company.log" 2>&1 || true
  if command grep -q 'founding plan ready for the board' "$ws/company.log"; then
    local aid; aid=$(command grep -o 'attention [0-9a-f]*' "$ws/company.log" | head -1 | awk '{print $2}')
    local body; body=$(python3 - "$ws/$cid/company.db" "$aid" <<'PY'
import sqlite3, sys, json
db, aid = sys.argv[1:3]
c = sqlite3.connect(db)
row = c.execute("select artifact_hash from attention_queue where id=?", (aid,)).fetchone()
plan = c.execute("select content from artifacts where hash=?", (row[0],)).fetchone()[0] if row else "(plan unavailable)"
total = ""
for line in plan.splitlines():
    t = line.strip().lower()
    if t.startswith("| total"):
        total = line.split("|")[2].strip()
print(json.dumps({"item_id": aid, "kind": "board", "question": "Approve the founding plan? (monthly budget %s EUR; answer with an optional budget_eur=N in the reason to change it)" % (total or "?"), "context_md": plan}))
PY
)
    local f; f=$(mktemp); with_token "$body" > "$f"; jpost "/api/companies/$uuid/decisions" "$f" >/dev/null; rm -f "$f"
    report_from_db "$uuid" "$ws/$cid/company.db" "awaiting-decision" "" "founding plan ready; awaiting the founder's approval"
    echo "[runner] waiting for the founder's approval of the founding plan..."
    local verdict="" reason=""
    while [ -z "$verdict" ]; do
      sleep 10
      f=$(mktemp); with_token "$(python3 -c 'import json,sys; print(json.dumps({"item_id": sys.argv[1]}))' "$aid")" > "$f"
      local resp; resp=$(jpost "/api/companies/$uuid/decisions/poll" "$f" || echo '{}'); rm -f "$f"
      verdict=$(python3 -c 'import sys,json; ds=[d for d in json.loads(sys.argv[1]).get("decisions",[]) if d.get("status")=="decided"]; print(ds[0]["verdict"] if ds else "")' "$resp")
      reason=$(python3 -c 'import sys,json; ds=[d for d in json.loads(sys.argv[1]).get("decisions",[]) if d.get("status")=="decided"]; print((ds[0].get("reason") or "") if ds else "")' "$resp")
    done
    local lv; lv=$([ "$verdict" = yes ] && echo approved || echo rejected)
    echo "[runner] founder: $lv ($reason)"
    DB_PATH="$ws/$cid/company.db" ATTENTION_ID="$aid" VERDICT="$lv" REASON="$reason" RESOLVER_ID="founder-via-loom-cloud" lex run --allow-effects env,io,sql,fs_read,fs_write,time,random,crypto src/main.lex attention_resolve_cmd > "$ws/resolve.log" 2>&1 || true
    report "$uuid" '{"status":"running","summary":"founding plan decided; company resuming"}'
    STOP_WHEN="$3" bin/bootstrap-company.sh "$manifest" >> "$ws/company.log" 2>&1 || true
  fi
  local v; v=$(command grep -o 'last_verdict=[a-z_]*' "$ws/company.log" | tail -1 | cut -d= -f2)
  report_from_db "$uuid" "$ws/$cid/company.db" "$([ "$v" = passed ] && echo done || echo failed)" "$v" "$(command grep '\[company\] done' "$ws/company.log" | tail -1 | cut -c1-200)"
}

# `report-consortium <uuid>`: push an existing workspace's round to its card,
# with the phase read off which logs exist.
if [ "$ONCE" = "report-consortium" ]; then
  uuid="${2:?usage: cloud-company-runner.sh report-consortium <company-uuid>}"; ws="$WS_ROOT/cloud-$uuid"
  [ -d "$ws" ] || { echo "no workspace at $ws" >&2; exit 1; }
  export LOOM_WORKSPACE="$ws" CONSORTIUM_DB="$ws/consortium.db"
  phase="research-running"; status="running"; verdict=""; summary=""
  if [ -f "$ws/deliver-software.log" ]; then
    phase="round-complete"; status="done"; verdict=$(command grep -o 'last_verdict=[a-z_]*' "$ws/software.log" 2>/dev/null | tail -1 | cut -d= -f2)
    summary="round complete: research fulfilled; $(command grep -o 'contract c-software-1 [a-z]*: [^$]*' "$ws/deliver-software.log" | tail -1 | cut -c1-200)"
    command grep -q 'settled: rejected\|state=cancelled' "$ws/deliver-software.log" && status="failed"
  elif [ -f "$ws/software.log" ]; then phase="software-building"; summary="SoftwareCo building"
  elif [ -f "$ws/answer.log" ]; then phase="research-settled"; status="done"; summary=$(command grep -o 'contract c-research-1 [a-z]*: [^$]*' "$ws/answer.log" | head -1 | cut -c1-160)
  elif [ -f "$ws/deliver.log" ]; then phase="research-awaiting-founder"; status="awaiting-decision"; summary="awaiting the founder on human:would-fund"
  fi
  report_consortium "$uuid" "$status" "$verdict" "$summary" "$phase"
  echo "[runner] reported $uuid: status=$status phase=$phase"; exit 0
fi

# Say what is happening: the first poll reports whether the key was
# accepted and where; then one line every ten idle polls, so a runner left
# running is never silent for more than a couple of minutes.
polls=0
while :; do
  f=$(mktemp); with_token '{}' > "$f"
  if ! resp=$(jpost /api/runners/poll-company "$f"); then rm -f "$f"; echo "[runner] poll failed against $LOOM_SERVER (see above); retrying in 15s"; sleep 15; continue; fi
  rm -f "$f"
  uuid=$(python3 -c 'import sys,json; c=json.loads(sys.argv[1]).get("company"); print(c["id"] if c else "")' "$resp")
  if [ "$polls" = 0 ]; then echo "[runner] connected to $LOOM_SERVER: runner key accepted; waiting for a queued company (queue one under Companies -> New company)"; fi
  polls=$((polls+1))
  if [ -z "$uuid" ]; then
    [ "$ONCE" = "--once" ] && { echo "[runner] nothing queued"; exit 0; }
    [ $((polls % 10)) = 0 ] && echo "[runner] $(date +%H:%M:%S) still connected, nothing queued ($polls polls)"
    sleep 15; continue
  fi
  kind=$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["company"]["kind"])' "$resp")
  stop=$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["company"].get("stop_when") or "verdict-passed")' "$resp")
  mf=$(mktemp "${TMPDIR:-/tmp}/cloud-company.XXXXXX.toml"); python3 -c 'import sys,json; sys.stdout.write(json.loads(sys.argv[1])["company"]["manifest_toml"])' "$resp" > "$mf"
  echo "[runner] claimed company $uuid kind=$kind"
  case "$kind" in
    consortium-research) run_consortium_research "$uuid" "$mf" ;;
    *) run_plain_company "$uuid" "$mf" "$stop" ;;
  esac
  rm -f "$mf"
  [ "$ONCE" = "--once" ] && exit 0
done
