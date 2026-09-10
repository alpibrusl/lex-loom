#!/usr/bin/env bash
# iac-gate.sh -- hold a loom deploy against the company's grant with lex-iac
# BEFORE anything reaches the server.
#
#   bin/iac-gate.sh <grant.json> <out-dir> --host H --service S --port P [--domain D] [--release R]
#
# Writes <out-dir>/plan.json, <out-dir>/audit.json, <out-dir>/verdict.json and
# prints ONE line the caller keys on:
#   IAC_ADMITTED plan=<sha256> head=<audit head>
#   IAC_REFUSED <effect> [<wall>] at <address>: <reason>; ...
#   IAC_UNAVAILABLE <why>          (lex-iac not installed: refuse, do not downgrade)
# Exit 0 only when admitted.
set -uo pipefail
GRANT="$1"; OUT="$2"; shift 2
mkdir -p "$OUT"
LEXIAC="${LEX_IAC:-lex-iac}"
if ! command -v "$LEXIAC" >/dev/null 2>&1; then
  echo "IAC_UNAVAILABLE lex-iac is not on PATH (cargo install --git https://github.com/alpibrusl/lex-iac, or set LEX_IAC); the deploy is refused, not run unchecked"; exit 3
fi
python3 "$(dirname "$0")/deploy_plan.py" "$@" --out "$OUT/plan.json" || { echo "IAC_UNAVAILABLE could not write the deploy plan"; exit 3; }
"$LEXIAC" check --grant "$GRANT" --plan "$OUT/plan.json" --audit-out "$OUT/audit.json" --json > "$OUT/verdict.json" 2> "$OUT/check.err"
python3 - "$OUT/verdict.json" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception as e:
    print("IAC_UNAVAILABLE lex-iac produced no verdict: %s" % e); sys.exit(3)
ref = v.get("refusals") or []
if ref:
    print("IAC_REFUSED " + "; ".join("%s [%s] at %s: %s" % (r.get("effect"), r.get("wall"), r.get("address"), r.get("reason")) for r in ref)); sys.exit(1)
print("IAC_ADMITTED plan=%s head=%s" % (v.get("plan_sha256"), v.get("audit_head"))); sys.exit(0)
PY
