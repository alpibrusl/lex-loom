#!/usr/bin/env bash
# The first column of every row, one per line, read-only.
#   sql-rows.sh <db> "select id from t order by id"
# The query's first column must be named `v` or be aliased to it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,fs_write,io,sql "$HERE/query.lex" main_sql_rows \
  "$(jsonarg "${1:?db path}")" "$(jsonarg "${2:?query}")"
