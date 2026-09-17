#!/usr/bin/env bash
# The last JSON object in mixed output (logs, then an envelope).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_last_object "$(jsonarg "$(cat)")"
