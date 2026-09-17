#!/usr/bin/env bash
# Argument shim for bin/evidence_report.lex.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/evidence_report.lex" main "$(jsonarg "${1:?db path}")"
