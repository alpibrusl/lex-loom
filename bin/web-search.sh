#!/usr/bin/env bash
# Argument shim for bin/web_search.lex — see bin/extract-fenced.sh.
# Usage: web-search.sh <query...>   |   web-search.sh --backend=<name> <query...>
set -uo pipefail
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
ONLY=
if [ "${1-}" != "${1#--backend=}" ]; then ONLY="${1#--backend=}"; shift; fi
Q="$*"
[ -n "$Q" ] || Q="$(cat)"
out=$(lex run --allow-effects env,fs_read,fs_write,io,net "$(dirname "$0")/web_search.lex" main \
  "$(jsonarg "$Q")" "$(jsonarg "$ONLY")" 2>&1)
printf '%s\n' "$out" | drop_rc
