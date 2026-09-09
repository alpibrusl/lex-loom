#!/usr/bin/env bash
# fp1-founding-plan-roundtrip.sh -- the founding-plan checker, checked: every
# section by name, the budget Total recomputed (a pasted total is refused),
# the verified attrs printed for the approval, the total printed for the
# envelope.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-fp1.XXXXXX")"; trap 'rm -rf "$W"' EXIT
good() {
cat <<'MD'
# Founding plan: DateNorm

## Idea
A paid micro-API that normalises free-text dates to ISO 8601 for solo developers.

## Budget
| Item | EUR / month | Notes |
|---|---|---|
| Model inference | 120 | LiteLLM on our own box |
| Hosting | 25 | one small VM |
| Marketing | 100 | two developer newsletters |
| Other | 15 | domain, status page |
| Total | 260 | |

## Resources
- one 2 vCPU VM
- a LiteLLM endpoint

## Human actions
- register the domain datenorm.dev
- create the Stripe account and connect it

## Success metric
50 paying calls a day by week 8.

## Timeline
Week 1 build, week 2 launch, weeks 3-8 grow.
MD
}
echo "== 1. a complete plan passes with its attrs and total"
mkdir -p "$W/good"; good > "$W/good/plan.md"
out=$(cd "$W/good" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"FOUNDING_PLAN_OK checkable:idea checkable:budget checkable:resources checkable:human-actions checkable:success-metric checkable:timeline"* ]] && [[ "$out" == *"FOUNDING_PLAN_TOTAL_EUR=260"* ]]; then ok "complete plan accepted; attrs + total printed"; else bad "complete plan refused: $out"; fi
echo "== 2. a pasted Total is refused (derived value)"
mkdir -p "$W/paste"; good | sed 's/^| Total | 260 | |$/| Total | 300 | |/' > "$W/paste/plan.md"
out=$(cd "$W/paste" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:budget"* ]] && [[ "$out" == *"sum to 260"* ]]; then ok "Total 300 over rows summing to 260 refused, naming the sum"; else bad "a pasted total was accepted: $out"; fi
echo "== 3. each missing section is refused by name"
for sec in "## Idea:checkable:idea" "## Resources:checkable:resources" "## Human actions:checkable:human-actions" "## Success metric:checkable:success-metric" "## Timeline:checkable:timeline"; do
  h="${sec%%:*}"; a="${sec#*:}"; mkdir -p "$W/miss"; good | sed "s|^$h\$|## Removed|" > "$W/miss/plan.md"
  out=$(cd "$W/miss" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1) && rc=0 || rc=$?
  if [ "$rc" != 0 ] && [[ "$out" == *"$a"* ]]; then ok "missing '$h' refused as $a"; else bad "missing '$h' not refused as $a: $out"; fi
done
echo "== 4. human actions must be bullets; no plan on disk is a denial"
mkdir -p "$W/nob"; good | sed 's/^- register the domain.*$/register the domain/; s/^- create the Stripe.*$/create the Stripe account/' > "$W/nob/plan.md"
out=$(cd "$W/nob" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && [[ "$out" == *"checkable:human-actions"* ]]; then ok "prose human actions refused (bullets required)"; else bad "unbulleted human actions accepted"; fi
mkdir -p "$W/none"; out=$(cd "$W/none" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"plan.md"* ]] && ok "empty dir refused, naming plan.md" || bad "empty dir accepted"
echo "== 5. the verified line is printed on a refusal too (partial evidence)"
[[ "$(cd "$W/paste" && python3 "$OLDPWD/bin/check_founding_plan.py" . 2>&1)" == *"FOUNDING_PLAN_VERIFIED checkable:idea"* ]] && ok "refusal still lists the met criteria" || bad "refusal hides the met criteria"
echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" = 0 ]
