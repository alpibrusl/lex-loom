#!/usr/bin/env bash
# Argument shim for bin/check_derived_values.lex — see bin/extract-fenced.sh.
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects fs_read,fs_walk,io,proc "$(dirname "$0")/check_derived_values.lex" main "$(jsonarg "${1-.}")" "$(jsonarg "$(cd "$(dirname "$0")" && pwd)/py_test_pins.py")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -qE '^check_derived_values: [0-9]+ test file\(s\), expected values are derived' <<<"$out"
