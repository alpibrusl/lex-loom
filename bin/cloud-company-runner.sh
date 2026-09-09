#!/usr/bin/env bash
# cloud-company-runner.sh -- runner protocol v2 (loom-cloud#47): the cloud
# holds companies and board decisions; this machine executes.
#
#   LOOM_SERVER=http://127.0.0.1:8880 LOOM_RUNNER_TOKEN=... bin/cloud-company-runner.sh [--once]
#
# Loop: claim one queued company (POST /api/runners/poll-company), run it
# here, report iterations + events + status (POST /api/companies/:id/report).
# kind=consortium-research: the company is ResearchCo under the consortium's
# research contract (bin/consortium-run.sh open/research/deliver); the
# contract's human criterion becomes a board decision the founder answers in
# the dashboard; this runner polls for it and settles (answer). kind=company:
# bin/bootstrap-company.sh on the manifest, then report.
# Nothing here touches real money, a host, or a publish; the cloud never
# executes anything.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LOOM_SERVER:?LOOM_SERVER is required}"; : "${LOOM_RUNNER_TOKEN:?LOOM_RUNNER_TOKEN is required}"
ONCE="${1:-}"
WS_ROOT="${LOOM_WORKSPACE:-$HOME/loom-companies}"

jpost() { # path json-file -> body (fails loudly on non-2xx)
  local out; out=$(curl -sS --max-time 40 -w '\n%{http_code}' -H 'Content-Type: application/json' -d @"$2" "$LOOM_SERVER$1"); local code="${out##*$'\n'}"; local body="${out%$'\n'*}"
  if [ "${code:0:1}" != "2" ]; then echo "[runner] $1 -> $code: $body" >&2; return 1; fi; printf '%s' "$body"
}
with_token() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["runner_token"]=sys.argv[2]; print(json.dumps(d))' "$1" "$LOOM_RUNNER_TOKEN"; }
report() { # company-uuid json-fields
  local f; f=$(mktemp); with_token "$2" > "$f"; jpost "/api/companies/$1/report" "$f" >/dev/null; rm -f "$f"
}
report_from_db() { # company-uuid company.db status last_verdict summary
  local f; f=$(mktemp)
  python3 - "$2" "$3" "$4" "$5" "$LOOM_RUNNER_TOKEN" > "$f" <<'PY'
import sqlite3, json, sys
db, status, verdict, summary, tok = sys.argv[1:6]
its, evs = [], []
try:
    c = sqlite3.connect(db)
    its = [dict(idx=r[0], sprint_id=r[1], status=r[2], started_at=r[3], ended_at=r[4]) for r in c.execute("select idx, sprint_id, status, started_at, ended_at from company_iterations order by idx")]
    rows = c.execute("select ts, event_kind, data_json from traces where event_kind in ('stage_transition','goal_decision','sprint_complete','acceptance_passed','acceptance_failed','node_denied','treasury_opened','company_parked','qa_skipped_document_sprint') order by ts").fetchall()
    for i, (ts, k, d) in enumerate(rows[-400:]):
        try: data = json.loads(d)
        except Exception: data = {"raw": (d or "")[:300]}
        evs.append(dict(seq=i, kind=k, data=data, ts=ts))
except Exception as e:
    evs.append(dict(seq=0, kind="runner_error", data={"error": str(e)}, ts=""))
print(json.dumps(dict(runner_token=tok, status=status, last_verdict=verdict, summary=summary, iterations=its, events=evs)))
PY
  jpost "/api/companies/$1/report" "$f" >/dev/null; rm -f "$f"
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
  report "$uuid" '{"status":"running","summary":"research contract awarded; ResearchCo running"}'
  bin/consortium-run.sh research > "$ws/research.log" 2>&1 || true
  report_from_db "$uuid" "$ws/researchco/company.db" "running" "$(command grep -o 'last_verdict=[a-z]*' "$ws/research.log" | tail -1 | cut -d= -f2)" "ResearchCo finished; delivering"
  bin/consortium-run.sh deliver > "$ws/deliver.log" 2>&1 || true
  if ! command grep -q 'awaiting: human:would-fund' "$ws/deliver.log"; then
    report_from_db "$uuid" "$ws/researchco/company.db" "failed" "$(command grep -o 'last_verdict=[a-z]*' "$ws/research.log" | tail -1 | cut -d= -f2)" "$(command grep -o 'contract c-research-1 .*' "$ws/deliver.log" | head -1 | cut -c1-200)"; return
  fi
  local ctx f; ctx=$(python3 -c 'import sys,json; r=open(sys.argv[1]).read() if __import__("os").path.exists(sys.argv[1]) else "(no report.md)"; print(json.dumps({"item_id":"human:would-fund","kind":"human-criterion","question":"Is the recommended opportunity one you would fund? (contract c-research-1, 40000c held on softwareco)","context_md":r}))' "$ws/researchco/report.md")
  f=$(mktemp); with_token "$ctx" > "$f"; jpost "/api/companies/$uuid/decisions" "$f" >/dev/null; rm -f "$f"
  report "$uuid" '{"status":"awaiting-decision","summary":"report delivered; awaiting the founder on human:would-fund"}'
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
  report_from_db "$uuid" "$ws/researchco/company.db" "done" "$(command grep -o 'last_verdict=[a-z]*' "$ws/research.log" | tail -1 | cut -d= -f2)" "${settled:-settled}"
}

run_plain_company() { # uuid manifest-file stop_when
  local uuid="$1" manifest="$2" ws="$WS_ROOT/cloud-$1"; mkdir -p "$ws"
  export LOOM_WORKSPACE="$ws"
  report "$uuid" '{"status":"running"}'
  STOP_WHEN="$3" bin/bootstrap-company.sh "$manifest" > "$ws/company.log" 2>&1 || true
  local cid; cid=$(python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["identity"]["id"])' "$manifest")
  local v; v=$(command grep -o 'last_verdict=[a-z]*' "$ws/company.log" | tail -1 | cut -d= -f2)
  report_from_db "$uuid" "$ws/$cid/company.db" "$([ "$v" = passed ] && echo done || echo failed)" "$v" "$(command grep '\[company\] done' "$ws/company.log" | tail -1 | cut -c1-200)"
}

while :; do
  f=$(mktemp); with_token '{}' > "$f"; resp=$(jpost /api/runners/poll-company "$f" || echo '{"company":null}'); rm -f "$f"
  uuid=$(python3 -c 'import sys,json; c=json.loads(sys.argv[1]).get("company"); print(c["id"] if c else "")' "$resp")
  if [ -z "$uuid" ]; then [ "$ONCE" = "--once" ] && { echo "[runner] nothing queued"; exit 0; }; sleep 15; continue; fi
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
