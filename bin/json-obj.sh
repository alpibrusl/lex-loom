#!/usr/bin/env bash
# Build a JSON object from k=v arguments, with the quoting done once.
#   json-obj.sh item_id=abc kind=need         -> {"item_id":"abc","kind":"need"}
# A value that is itself JSON is embedded as JSON, so nesting composes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_obj "$(jsonarg "$(printf '%s\n' "$@")")"
