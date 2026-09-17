#!/usr/bin/env bash
# Flag parsing for bin/deploy_plan.lex.
#
# The flags live here because every caller already writes them this way
# (`--host H --service S --port P [--domain D] [--release R] [--out F]`) and
# `lex run` takes positional JSON arguments. Parsing them in shell keeps the
# Lex program a pure function of five values, which is what makes the plan
# deterministic and worth gating.
set -uo pipefail
HOST= SERVICE= PORT= DOMAIN= RELEASE= OUT=
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "deploy_plan: unknown argument $1" >&2; exit 2 ;;
  esac
done
for v in HOST SERVICE PORT; do
  [ -n "${!v}" ] || { echo "deploy_plan: --$(echo "$v" | tr 'A-Z' 'a-z') is required" >&2; exit 2; }
done
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects io "$(dirname "$0")/deploy_plan.lex" main \
  "$(jsonarg "$HOST")" "$(jsonarg "$SERVICE")" "$(jsonarg "$PORT")" "$(jsonarg "$DOMAIN")" "$(jsonarg "$RELEASE")" 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
if [ -n "$OUT" ]; then printf '%s\n' "$out" | drop_rc > "$OUT"; else printf '%s\n' "$out" | drop_rc; fi
