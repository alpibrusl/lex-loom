#!/usr/bin/env bash
# Argument shim for bin/check_launch_delivery.lex — see bin/extract-fenced.sh.
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects fs_read,fs_walk,fs_write,io,sql "$(dirname "$0")/check_launch_delivery.lex" main \
  "$(jsonarg "${1-}")" "$(jsonarg "${2-}")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -q '^LAUNCH_DELIVERY_OK' <<<"$out"
