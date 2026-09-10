#!/usr/bin/env bash
# dp1-deploy-plan-gate-roundtrip.sh -- the deploy plan gate, checked: the
# grant loom generates for the deploy role (src/manifests.lex
# deploy_grant_json) holds the deploy's plan (bin/deploy_plan.py) in lex-iac
# before anything reaches a server. Needs `lex-iac` on PATH (or LEX_IAC).
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-dp1.XXXXXX")"; trap 'rm -rf "$W"' EXIT
unquote() { python3 -c 'import sys,json; print(json.loads(sys.stdin.read()))'; }
command -v "${LEX_IAC:-lex-iac}" >/dev/null || { echo "lex-iac not on PATH (set LEX_IAC)"; exit 2; }

echo "== 1. the deploy plan is deterministic code"
python3 bin/deploy_plan.py --host 203.0.113.9 --service api --port 8081 --out "$W/p1.json"; python3 bin/deploy_plan.py --host 203.0.113.9 --service api --port 8081 --out "$W/p2.json"
cmp -s "$W/p1.json" "$W/p2.json" && ok "same inputs, byte-identical plan" || bad "the plan is not deterministic"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); a=[c["address"] for c in p["resource_changes"]]; assert a==["hetzner_host.203_0_113_9","docker_compose.api","host_port.p8081"], a' "$W/p1.json" && ok "host update + compose create + port create, no domain" || bad "unexpected resources"

echo "== 2. loom's default deploy grant admits the plain deploy"
lex run src/manifests.lex deploy_grant_json '"dp1/iter-1"' '""' '"203.0.113.9"' | unquote > "$W/grant.json"
python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); i=g["facets"]["infra"]; assert i["providers"]==["alpibrusl/loom"] and "hetzner.host.update" in i["allow"] and g["grant"]["exec"]=="Sandboxed", g' "$W/grant.json" && ok "grant carries facets.infra (allow, provider, host scope) on the Implementation grant" || bad "grant shape wrong"
out=$(bash bin/iac-gate.sh "$W/grant.json" "$W/g1" --host 203.0.113.9 --service api --port 8081) && rc=0 || rc=$?
[ "$rc" = 0 ] && [[ "$out" == IAC_ADMITTED\ plan=*head=* ]] && ok "admitted with plan sha + audit head: $(echo "$out" | cut -c1-70)..." || bad "plain deploy refused: $out"
[ -s "$W/g1/audit.json" ] && ok "audit log written beside the plan" || bad "no audit log"

echo "== 3. a domain adds caddy.site.create; the default grant admits it, a narrowed one refuses it by name"
out=$(bash bin/iac-gate.sh "$W/grant.json" "$W/g2" --host 203.0.113.9 --service api --port 8081 --domain api.example.com) && ok "with a domain: admitted (caddy.site.create is in the default allow)" || bad "domain deploy refused: $out"
lex run src/manifests.lex deploy_grant_json '"dp1/iter-1"' '"hetzner.host.update,docker.compose.create,host.port.create"' '"203.0.113.9"' | unquote > "$W/narrow.json"
out=$(bash bin/iac-gate.sh "$W/narrow.json" "$W/g3" --host 203.0.113.9 --service api --port 8081 --domain api.example.com) && rc=0 || rc=$?
[ "$rc" != 0 ] && [[ "$out" == IAC_REFUSED*caddy.site.create* ]] && ok "narrowed grant (no caddy) refuses the domain deploy naming caddy.site.create" || bad "narrowed grant did not refuse: $out"

echo "== 4. tearing the host down is never in the default grant"
python3 bin/deploy_plan.py --host 203.0.113.9 --service api --port 8081 --out "$W/del.json"; python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["resource_changes"][0]["change"]["actions"]=["delete"]; json.dump(p,open(sys.argv[1],"w"))' "$W/del.json"
out=$({ "${LEX_IAC:-lex-iac}" check --grant "$W/grant.json" --plan "$W/del.json" --json 2>/dev/null || true; } | python3 -c 'import sys,json; r=json.load(sys.stdin)["refusals"]; print(r[0]["effect"] if r else "admitted")')
[ "$out" = hetzner.host.delete ] && ok "a plan that deletes the host is refused (hetzner.host.delete)" || bad "host delete admitted: $out"

echo "== 5. a plan from a provider the grant does not name is refused; no lex-iac means refused, never unchecked"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["resource_changes"][1]["provider_name"]="registry.terraform.io/evilcorp/loom"; json.dump(p,open(sys.argv[2],"w"))' "$W/p1.json" "$W/evil.json"
out=$({ "${LEX_IAC:-lex-iac}" check --grant "$W/grant.json" --plan "$W/evil.json" --json 2>/dev/null || true; } | python3 -c 'import sys,json; r=json.load(sys.stdin)["refusals"]; print(r[0]["wall"] if r else "admitted")')
[ "$out" = provenance ] && ok "foreign provider refused at the provenance wall" || bad "foreign provider admitted: $out"
out=$(LEX_IAC=/nonexistent/lex-iac bash bin/iac-gate.sh "$W/grant.json" "$W/g4" --host 203.0.113.9 --service api --port 8081) && rc=0 || rc=$?
[ "$rc" = 3 ] && [[ "$out" == IAC_UNAVAILABLE* ]] && ok "without lex-iac the gate refuses (exit 3), it does not wave the deploy through" || bad "missing lex-iac did not refuse: $out"

echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" = 0 ]
