#!/usr/bin/env bash
# _fixtures.sh — the consortium demos' shared fixture seeds.
#
# cs1, cs2 and cs3 each build the same shapes: a company trail with one
# successful iteration, a graph whose nodes are all accepted, a backup with a
# restore-evidence file, a product store with a waitlist. Each had its own
# python3 heredoc doing it, and the four copies had already drifted in their
# column lists.
#
# The SQL is the content; nothing needs to hold a connection for it
# (lex-loom#512). Sourced, not executed.

# A company trail with one successful iteration whose sprint passed acceptance.
seed_trail() {
  bin/sql-exec.sh "$1" - <<SQL
CREATE TABLE company_iterations (company_id TEXT, idx INTEGER, sprint_id TEXT, parent_sprint_id TEXT DEFAULT '', status TEXT, started_at TEXT DEFAULT '', ended_at TEXT DEFAULT '');
CREATE TABLE traces (id INTEGER PRIMARY KEY, run_id TEXT, agent_id TEXT, event_kind TEXT, data_json TEXT, ts TEXT);
CREATE TABLE sprint_graphs (id TEXT PRIMARY KEY, sprint_id TEXT, phase TEXT, graph_json TEXT, created_at TEXT);
CREATE TABLE node_results (id TEXT PRIMARY KEY, sprint_id TEXT, node_id TEXT, phase TEXT, accepted INTEGER, artifact TEXT DEFAULT '', reason TEXT DEFAULT '', created_at TEXT);
INSERT INTO company_iterations VALUES ('softwareco', 1, 'softwareco/iter-1', '', 'success', '', '');
INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('softwareco/iter-1', 'orch', 'acceptance_passed', '{}', '$2');
SQL
}

# A graph whose nodes are all ACCEPTED. node_results carries no role column, so
# the roles have to come from the graph -- which is exactly what the delivery
# checkers re-derive, and why the fixture has to store both.
seed_accepted_graph() {
  db="$1"; gid="$2"; shift 2
  nodes=""; results=""
  for spec in "$@"; do
    nid="${spec%%:*}"; role="${spec##*:}"
    [ -z "$nodes" ] || nodes="$nodes,"
    nodes="$nodes{\"id\":\"$nid\",\"role\":\"$role\",\"gate\":\"spec judge x\"}"
    results="$results INSERT INTO node_results VALUES ('$nid-r', 'softwareco/iter-1', '$nid', 'Implementation', 1, 'x', '', 't');"
  done
  bin/sql-exec.sh "$db" "INSERT INTO sprint_graphs VALUES ('$gid', 'softwareco/iter-1', 'Implementation', '{\"id\":\"softwareco/iter-1\",\"phase\":\"Implementation\",\"nodes\":[$nodes],\"edges\":[]}', 't'); $results"
}

# A restore fixture: a backup with three rows, and an evidence file whose
# claim the gate re-derives rather than believes.
# seed_restore <dir> [rows] [claimed]
#
# `claimed` defaults to `rows`, and differs from it deliberately in cs2: the
# gate must catch an evidence file that claims 300 rows over a backup holding
# one. A fixture that could only ever agree with itself would not test the
# check the gate exists for.
seed_restore() {
  rows="${2:-3}"; claimed="${3:-$rows}"
  values=""; i=1
  while [ "$i" -le "$rows" ]; do [ -z "$values" ] || values="$values,"; values="$values($i)"; i=$((i+1)); done
  bin/sql-exec.sh "$1/backup/product.sqlite" "create table submissions(id); insert into submissions values $values;"
  bin/json-obj.sh "backup=backup/product.sqlite" "tables={\"submissions\":$claimed}" > "$1/ops/restore-evidence.json"
}

# The product's own store. `would_pay` is set by position with a recursive CTE
# rather than by a hundred INSERTs -- the same rows, and the generator is
# visible instead of hidden in a comprehension.
seed_store() {
  bin/sql-exec.sh "$1/data/app.sqlite" - <<SQL
create table waitlist(email, would_pay integer);
create table submissions(id, genuine integer, created_at);
create table payments(id, status);
insert into waitlist select 'dev' || (i-1) || '@example.eu', case when i <= $3 then 1 else 0 end
  from (with recursive c(i) as (select 1 union all select i+1 from c where i < $2) select i from c);
SQL
}

# The manifest PARSES as TOML and its mission carries a criterion -- both at
# once, because a mission read out of a file that does not parse is not a
# mission. bin/toml-get.sh fails on a manifest it cannot read, so the
# substring test only runs on a parsed one.
manifest_has() { case "$(bin/toml-get.sh "$1" identity.mission)" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
