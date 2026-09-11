#!/usr/bin/env bash
# gp1-growth-pack-roundtrip.sh — live proof of the growth pack (#443: the
# packs behind #440 lifecycle and #441 community), fully offline (no LLM,
# no network):
#
#   1. a company.toml declaring packs = ["core", "ops", "growth"] flattens
#      through bootstrap --no-run into ROLE_PACKS exactly;
#   2. launching with it staffs every pack: lifecycle, community (growth) and
#      analytics, ops, release_manager (ops) are castable, while an
#      undeclared pack's roles (finance) are not;
#   3. an UNKNOWN pack still fails the launch loudly and saves nothing;
#   4. community carries web_search under a preset that keeps it, and
#      lifecycle (no tools) sits under Demo. Registration ORDER (the silent
#      failure #443 documents) is tests/test_role_registry.lex's job.
#
# Run from the repo root:  bash demo/gp1-growth-pack-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export MODEL="${MODEL:-kimi-k2.7-code}"

EFFECTS="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-gp1-demo.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/growthco"
DB="$WS/growthco/company.db"

pass=0
fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

say "1. [roles].packs = [core, ops, growth] flattens through bootstrap --no-run"
cat > "$WS/company.toml" <<'TOML'
[identity]
id = "growthco"
name = "Growth Pack Co"
mission = "Prove the growth pack staffs lifecycle and community."

[stack]
path = "python-flask"
model = "kimi-k2.7-code"

[roles]
packs = ["core", "ops", "growth"]
TOML
BOOT="$(LOOM_WORKSPACE="$WS" bash bin/bootstrap-company.sh "$WS/company.toml" --no-run 2>&1)"
echo "$BOOT" | grep -q "ROLE_PACKS='core,ops,growth'" && ok "[roles].packs -> ROLE_PACKS flattening exact" || bad "ROLE_PACKS not flattened: $(echo "$BOOT" | tail -2)"

say "2. launching with it staffs ops + growth; undeclared packs stay out"
OUT="$(DB_PATH="$DB" COMPANY_ID=growthco MAX_ITERATIONS=0 EVOLVE=0 ROLE_PACKS=core,ops,growth \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT" | grep -q "role packs staffed: core + core, ops, growth" && ok "packs staffed at launch" || bad "packs not staffed: $(echo "$OUT" | grep -i 'pack' | head -2)"
KS="$(DB_PATH="$DB" COMPANY_ID=growthco lex run --max-steps 0 --allow-effects "$EFFECTS" demo/org5_seed.lex castable_cmd 2>&1)"
for r in lifecycle community analytics ops release_manager; do
  echo "$KS" | grep -qw "$r" && ok "$r castable" || bad "$r not castable: $KS"
done
echo "$KS" | grep -qw "finance" && bad "undeclared finance pack leaked in" || ok "undeclared packs not staffed"

say "3. an unknown pack still fails the launch loudly"
OUT="$(DB_PATH="$WS/growthco/other.db" COMPANY_ID=badco MAX_ITERATIONS=0 EVOLVE=0 ROLE_PACKS=core,growthhacking \
  lex run --max-steps 0 --allow-effects "$EFFECTS" src/main.lex run_company_cmd 2>&1)"
echo "$OUT" | grep -q "unknown role pack 'growthhacking'" && ok "unknown pack refused, launch aborted" || bad "unknown pack not refused: $OUT"
ROWS="$(python3 -c "import sqlite3,os,sys; p=sys.argv[1]; c=sqlite3.connect(p) if os.path.exists(p) else None; print(0 if c is None else sum(c.execute('select count(*) from '+t).fetchone()[0] for (t,) in c.execute(\"select name from sqlite_master where type='table'\")))" "$WS/growthco/other.db")"
[ "$ROWS" = "0" ] && ok "refused launch saved nothing (schema only, zero rows)" || bad "refused launch wrote $ROWS rows"

say "4. community keeps web_search; lifecycle needs nothing"
TOOLS="$(ROLE=community lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gp1_probe.lex tools_cmd 2>&1)"
echo "$TOOLS" | grep -q "web_search" && ok "community carries web_search" || bad "community has no web_search: $TOOLS"
PRESET="$(ROLE=community lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gp1_probe.lex preset_cmd 2>&1)"
echo "$PRESET" | grep -q "Research" && ok "community runs under the Research preset (sandboxed exec for web_search)" || bad "community preset is '$PRESET', web_search would be stripped"
PRESET="$(ROLE=lifecycle lex run --max-steps 0 --allow-effects "$EFFECTS" demo/gp1_probe.lex preset_cmd 2>&1)"
echo "$PRESET" | grep -q "Demo" && ok "lifecycle (no tools) runs under Demo" || bad "lifecycle preset is '$PRESET'"

printf '\n== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
