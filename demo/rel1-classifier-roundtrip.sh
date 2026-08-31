#!/usr/bin/env bash
# rel1-classifier-roundtrip.sh — the reliability harness must not throw away a
# run it actually measured.
#
# Found live. Any provider error at all classified a run "infra — nothing
# measured". tzshdr1 was discarded on 3 errors out of 64 calls, having produced
# 12 accepted nodes, 31 denials and 2.9M tokens of real pipeline behaviour; six
# consecutive batches reported nothing for this reason, so six batches of real
# evidence about the pipeline were never looked at.
#
# Found while fixing it, which is why this file exists at all: the fix was
# reported as landed when only half of it had been written to the file. The
# "verification" re-implemented the rule in a scratch snippet and ran THAT
# against the real database, so it passed while the artifact was still broken.
# bin/*.sh had no test anywhere in CI. This calls the real classify_run.
#
# Run from the repo root:  bash demo/rel1-classifier-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-rel-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
say() { printf '\n== %s\n' "$1"; }

# Only classify_run is wanted, not a real company run: stop the script at the
# point it would start spending.
eval "$(sed -n '/^classify_run() {/,/^}/p' bin/company-reliability.sh)"

# calls, provider errors, accepted nodes, sprint success, one denial
seed() {
  local db="$1" calls="$2" errs="$3" accepted="$4" succeeded="$5"
  sqlite3 "$db" "create table traces (id integer primary key, event_kind text, data_json text);"
  # NOT `for _ in $(seq 1 $n)`: BSD seq counts DOWN when the first bound is the
  # larger, so `seq 1 0` yields "1 0" and a zero-error fixture quietly gained
  # two provider errors. This test caught that in its own scaffolding.
  rep() {
    local n="$1" kind="$2" data="$3" i=0
    while [ "$i" -lt "$n" ]; do
      sqlite3 "$db" "insert into traces (event_kind,data_json) values ('$kind','$data');"
      i=$((i+1))
    done
  }
  rep "$calls" llm_start '{}'
  rep "$errs" llm_done '"[provider error: connection refused]"'
  rep "$accepted" node_accepted '{"node":"py-build"}' 
  sqlite3 "$db" "insert into traces (event_kind,data_json) values ('node_denied','{\"node\":\"py-qa\",\"reason\":\"verdict not grounded\"}');"
  [ "$succeeded" = "yes" ] && sqlite3 "$db" "insert into traces (event_kind,data_json) values ('sprint_complete','{\"success\":true}');"
  return 0
}

cls_of() { classify_run "$1" | cut -f1; }
det_of() { classify_run "$1" | cut -f2; }

say "1. the run that was thrown away: 3 errors in 64 calls, 12 nodes accepted"
seed "$WS/measured.db" 64 3 12 no
[ "$(cls_of "$WS/measured.db")" = "fail" ] \
  && ok "measured as a real pipeline failure, not voided" \
  || bad "still voided: $(cls_of "$WS/measured.db")"
case "$(det_of "$WS/measured.db")" in
  *"3/64 calls hit a provider error"*) ok "the error count is carried as a note" ;;
  *) bad "no provider-error note: $(det_of "$WS/measured.db")" ;;
esac
case "$(det_of "$WS/measured.db")" in
  *"py-qa: verdict not grounded"*) ok "names the node that actually sank it" ;;
  *) bad "denial not named: $(det_of "$WS/measured.db")" ;;
esac

say "2. a run that genuinely never reached the model is STILL voided"
seed "$WS/dead.db" 8 8 0 no
[ "$(cls_of "$WS/dead.db")" = "infra" ] \
  && ok "nothing accepted and every call failed — unmeasurable" \
  || bad "should be infra: $(cls_of "$WS/dead.db")"

say "3. errors dominating the traffic still void the run"
seed "$WS/mostly.db" 10 7 2 no
[ "$(cls_of "$WS/mostly.db")" = "infra" ] \
  && ok "7 of 10 calls failed — too little got through to measure" \
  || bad "should be infra: $(cls_of "$WS/mostly.db")"

say "4. a clean pass is still a pass, and a clean failure still a failure"
seed "$WS/good.db" 40 0 12 yes
[ "$(cls_of "$WS/good.db")" = "pass" ] && ok "clean success classifies pass" || bad "should be pass: $(cls_of "$WS/good.db")"
seed "$WS/bad.db" 40 0 12 no
[ "$(cls_of "$WS/bad.db")" = "fail" ] && ok "clean failure classifies fail" || bad "should be fail: $(cls_of "$WS/bad.db")"
case "$(det_of "$WS/good.db")" in
  *"provider error"*) bad "a clean run must carry no error note" ;;
  *) ok "a clean run carries no error note" ;;
esac

say "5. a missing database is still infra"
[ "$(cls_of "$WS/nope.db")" = "infra" ] && ok "no database — the run never started" || bad "missing db should be infra"

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
