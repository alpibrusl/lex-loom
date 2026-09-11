#!/usr/bin/env bash
# consortium-run.sh -- run 1 of the consortium, one phase per invocation
# (docs/consortium-freeze.md). Everything persists in $CONSORTIUM_DB, so a
# phase can be re-run or resumed after a crash.
#
#   bin/consortium-run.sh open       fund both treasuries, award the research
#                                    contract, write ResearchCo's manifest
#   bin/consortium-run.sh research   bootstrap + run ResearchCo on that manifest
#                                    (a real loom company; STOP_WHEN=verdict-passed)
#   bin/consortium-run.sh deliver    re-run the report gate over what ResearchCo
#                                    delivered and record the evidence
#   ANSWER=yes|no [NOTE=...] bin/consortium-run.sh answer
#                                    the founder's answer; verdict + settlement
#   bin/consortium-run.sh open-software
#                                    SoftwareCo contracts itself to build the
#                                    settled report's product; writes its manifest
#   bin/consortium-run.sh software   bootstrap + run SoftwareCo on that manifest
#   bin/consortium-run.sh deliver-software
#                                    re-derive the evidence from SoftwareCo's
#                                    trail + workspace; verdict + settlement
#   bin/consortium-run.sh open-operable
#                                    SoftwareCo contracts itself to make the
#                                    built product operable; writes the manifest
#   bin/consortium-run.sh operable   bootstrap + run SoftwareCo on that manifest
#                                    (re-bootstraps the same company id; first
#                                    exercised live by #453)
#   bin/consortium-run.sh deliver-operable
#                                    re-derive the operable evidence; verdict +
#                                    settlement. DEPLOY_DOMAIN assesses TLS.
#   bin/consortium-run.sh open-launch
#                                    SoftwareCo contracts itself to launch the
#                                    operable product by #452's stages; manifest
#   bin/consortium-run.sh launch     bootstrap + run SoftwareCo on that manifest
#   bin/consortium-run.sh deliver-launch
#                                    re-derive the checkable half by counting in
#                                    the product's own store; the three human
#                                    criteria then wait for
#   CONTRACT_ID=c-launch-1 ATTR=human:approved-to-publish ANSWER=yes bin/consortium-run.sh answer
#                                    (and human:approved-to-send, human:product-created)
#   bin/consortium-run.sh status
#
# Env: LOOM_WORKSPACE (default ~/loom-companies), CONSORTIUM_DB (default
# $LOOM_WORKSPACE/consortium.db), PROBLEM_SPACE (default: the frozen one),
# MODEL. Nothing here touches real money, a host, or a publish.
set -euo pipefail
cd "$(dirname "$0")/.."
PHASE="${1:-}"
WS="${LOOM_WORKSPACE:-$HOME/loom-companies}"
export LOOM_WORKSPACE="$WS"
export CONSORTIUM_DB="${CONSORTIUM_DB:-$WS/consortium.db}"
MANIFEST="$WS/researchco.company.toml"
SW_MANIFEST="$WS/softwareco.company.toml"
OP_MANIFEST="$WS/softwareco-operable.company.toml"
LAUNCH_MANIFEST="$WS/softwareco-launch.company.toml"
LEDGER="/tmp/loom-search-ledger-researchco.txt"
EFFECTS="env,io,sql,time,fs_read,fs_write,proc,crypto,random,net,concurrent,vcs,llm,approval,stream"
mkdir -p "$WS"

run_cmd() { lex run --allow-effects "$EFFECTS" src/consortium_main.lex "$1"; }

case "$PHASE" in
  open)
    RESEARCHCO_MANIFEST="$MANIFEST" run_cmd consortium_open_cmd
    ;;
  research)
    [ -f "$MANIFEST" ] || { echo "no $MANIFEST -- run 'open' first" >&2; exit 1; }
    # This run's search ledger only: the gate grounds every cited URL in it.
    rm -f "$LEDGER"
    STOP_WHEN='verdict-passed' bin/bootstrap-company.sh "$MANIFEST"
    ;;
  deliver)
    DIR="$WS/researchco"
    if [ ! -f "$DIR/report.md" ]; then
      # The passing iteration syncs the report here; if the company ended
      # without a sync, pull the research node's artifact from its trail.
      python3 - "$DIR/company.db" "$DIR" <<'PY'
import sqlite3, sys, subprocess, pathlib
db, out = sys.argv[1], sys.argv[2]
rows = sqlite3.connect(db).execute("SELECT content FROM artifacts WHERE content LIKE '%## Sources%' ORDER BY length(content) DESC LIMIT 1").fetchall()
if not rows:
    print("no report artifact in the company trail", file=sys.stderr); sys.exit(1)
art = pathlib.Path(out) / "delivered-art.txt"; art.write_text(rows[0][0])
subprocess.run(["python3", "bin/extract_fenced.py", str(art), out], check=False)
PY
    fi
    [ -f "$DIR/report.md" ] || { echo "no report.md delivered in $DIR" >&2; exit 1; }
    REPORT_DIR="$DIR" LOOM_SEARCH_LEDGER="${LOOM_SEARCH_LEDGER:-$LEDGER}" run_cmd consortium_deliver_cmd
    ;;
  answer)
    run_cmd consortium_answer_cmd
    ;;
  open-software)
    REPORT_PATH="${REPORT_PATH:-$WS/researchco/report.md}" SOFTWARECO_MANIFEST="$SW_MANIFEST" run_cmd consortium_open_software_cmd
    ;;
  software)
    [ -f "$SW_MANIFEST" ] || { echo "no $SW_MANIFEST -- run 'open-software' first" >&2; exit 1; }
    STOP_WHEN='verdict-passed' bin/bootstrap-company.sh "$SW_MANIFEST"
    ;;
  deliver-software)
    COMPANY_DB="$WS/softwareco/company.db" WORKSPACE_DIR="$WS/softwareco" run_cmd consortium_deliver_software_cmd
    ;;
  open-operable)
    OPERABLE_MANIFEST="$OP_MANIFEST" run_cmd consortium_open_operable_cmd
    ;;
  operable)
    [ -f "$OP_MANIFEST" ] || { echo "no $OP_MANIFEST -- run 'open-operable' first" >&2; exit 1; }
    STOP_WHEN='verdict-passed' bin/bootstrap-company.sh "$OP_MANIFEST"
    ;;
  deliver-operable)
    COMPANY_DB="$WS/softwareco/company.db" WORKSPACE_DIR="$WS/softwareco" run_cmd consortium_deliver_operable_cmd
    ;;
  open-launch)
    LAUNCH_MANIFEST="$LAUNCH_MANIFEST" run_cmd consortium_open_launch_cmd
    ;;
  launch)
    [ -f "$LAUNCH_MANIFEST" ] || { echo "no $LAUNCH_MANIFEST -- run 'open-launch' first" >&2; exit 1; }
    STOP_WHEN='verdict-passed' bin/bootstrap-company.sh "$LAUNCH_MANIFEST"
    ;;
  deliver-launch)
    COMPANY_DB="$WS/softwareco/company.db" WORKSPACE_DIR="$WS/softwareco" run_cmd consortium_deliver_launch_cmd
    ;;
  status)
    run_cmd consortium_status_cmd
    ;;
  *)
    sed -n 2,40p "$0"; exit 2
    ;;
esac
