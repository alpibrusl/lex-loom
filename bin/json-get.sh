#!/usr/bin/env bash
# One field out of a JSON document, by dotted path. Replaces
# `python3 -c 'import sys,json; print(json.loads(...)["a"]["b"])'`.
#
#   json-get.sh <file> <a.b.c>        from a file
#   json-get.sh - <a.b.c>             from stdin
#   json-get.sh --str '<json>' <a.b>  from a literal
#
# A missing field is an empty result and exit 1, never a traceback: every
# caller is a $(...) substitution, where a Python stack trace lands in the
# variable and is then used as if it were a value.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
E=fs_read,fs_write,io,sql
case "${1-}" in
  --str) run_lex lex run --allow-effects "$E" "$HERE/query.lex" main_json_str "$(jsonarg "${2-}")" "$(jsonarg "${3-}")" ;;
  -)     run_lex lex run --allow-effects "$E" "$HERE/query.lex" main_json_str "$(jsonarg "$(cat)")" "$(jsonarg "${2-}")" ;;
  *)     run_lex lex run --allow-effects "$E" "$HERE/query.lex" main_json "$(jsonarg "${1-}")" "$(jsonarg "${2-}")" ;;
esac
