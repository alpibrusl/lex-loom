#!/usr/bin/env bash
# One scalar out of a SQLite database, read-only. Replaces
# `python3 -c 'import sqlite3,sys; print(sqlite3.connect(...).execute(Q).fetchone()[0])'`.
#
#   sql-scalar.sh <db> "select count(*) from traces where event_kind='x'"
#
# Read-only because a script asking how many nodes were cancelled has no
# business being able to write, and these run against a company's live trail
# while it is still running.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_sql \
  "$(jsonarg "${1:?db path}")" "$(jsonarg "${2:?query}")"
