#!/usr/bin/env bash
# Set one field on a JSON document read from stdin.
#   echo '{"a":1}' | json-set.sh runner_token "$TOKEN"
#   json-set.sh --path resource_changes.1.provider_name evilco < plan.json
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
FN=main_set
if [ "${1-}" = "--path" ]; then FN=main_set_path; shift; fi
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" "$FN" \
  "$(jsonarg "$(cat)")" "$(jsonarg "${1:?field}")" "$(jsonarg "${2-}")"
