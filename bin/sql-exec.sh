#!/usr/bin/env bash
# Run SQL against a SQLite database, writes allowed. Replaces the
# `python3 - <<PY / import sqlite3 / c.execute("CREATE TABLE ...") / ... PY`
# fixture-seeding blocks in the demos, where the SQL was always the real
# content and Python was only holding a connection.
#
#   sql-exec.sh <db> "CREATE TABLE t (a TEXT); INSERT INTO t VALUES ('x')"
#   sql-exec.sh <db> - <<'SQL'      ... SQL from stdin
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
DB="${1:?db path}"; shift
if [ "${1-}" = "-" ] || [ $# -eq 0 ]; then SQL="$(cat)"; else SQL="$*"; fi
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_sql_exec \
  "$(jsonarg "$DB")" "$(jsonarg "$SQL")"
