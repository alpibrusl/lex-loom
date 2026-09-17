#!/usr/bin/env bash
# Argument shim for bin/iac_verdict.lex.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,io "$HERE/iac_verdict.lex" main "$(jsonarg "${1:?verdict path}")"
