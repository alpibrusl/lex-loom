#!/usr/bin/env bash
# A string from stdin as a JSON string: quoting and escaping, nothing else.
# The one place a shell script must not improvise its own escaping.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_quote "$(jsonarg "$(cat)")"
