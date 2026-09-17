#!/usr/bin/env bash
# Argument shim for bin/check_imports.lex — see bin/extract-fenced.sh.
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects fs_walk,io,proc "$(dirname "$0")/check_imports.lex" main "$(jsonarg "${1-.}")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -qE '^check_imports: ([0-9]+ module\(s\) import cleanly|no importable modules)' <<<"$out"
