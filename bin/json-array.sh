#!/usr/bin/env bash
# A JSON array of strings, one per input line, blanks dropped.
#   ls -1 paths | json-array.sh   ->  ["python-fastapi","lex-web",...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_array "$(jsonarg "$(cat)")"
