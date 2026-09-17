#!/usr/bin/env bash
# See bin/query.lex for what main_len does.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_len "$(jsonarg "$(cat)")" "$(jsonarg "${1-}")"
