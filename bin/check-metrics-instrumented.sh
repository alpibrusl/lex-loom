#!/usr/bin/env bash
# Argument shim for bin/check_metrics_instrumented.lex — see bin/extract-fenced.sh.
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects fs_read,fs_walk,io "$(dirname "$0")/check_metrics_instrumented.lex" main "$(jsonarg "${1-.}")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -q '^METRICS_OK' <<<"$out"
