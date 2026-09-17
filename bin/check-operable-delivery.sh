#!/usr/bin/env bash
# Flag parsing + argument shim for bin/check_operable_delivery.lex.
# --domain is optional and is a founder-provided need; absent, the Lex program
# reports the TLS criterion UNMET rather than skipping it.
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
DOMAIN= POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2-}"; shift 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
out=$(lex run --allow-effects fs_read,fs_walk,fs_write,io,net,proc,sql "$(dirname "$0")/check_operable_delivery.lex" main \
  "$(jsonarg "${POS[0]-}")" "$(jsonarg "${POS[1]-}")" "$(jsonarg "$DOMAIN")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -q '^OPERABLE_DELIVERY_OK' <<<"$out"
