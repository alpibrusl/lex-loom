#!/usr/bin/env bash
# The first element of a list whose field equals a value, then a path into it.
#   json-find.sh --str "$resp" decisions status=decided verdict
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
if [ "${1-}" = "--str" ]; then TEXT="$2"; shift 2; else TEXT="$(cat)"; fi
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_find \
  "$(jsonarg "$TEXT")" "$(jsonarg "${1:?list path}")" "$(jsonarg "${2:?field=value}")" "$(jsonarg "${3-}")"
