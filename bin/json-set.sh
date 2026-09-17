#!/usr/bin/env bash
# Set one field on a JSON document read from stdin.
#   echo '{"a":1}' | json-set.sh runner_token "$TOKEN"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_set \
  "$(jsonarg "$(cat)")" "$(jsonarg "${1:?field}")" "$(jsonarg "${2-}")"
