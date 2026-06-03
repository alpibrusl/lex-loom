# migrate.lex — DDL for loom-specific tables.
#
# Calls soft_migrate.run first so the full lex-soft schema
# (agents, relationships, agent_state, traces) is always present.
# Loom adds: sprint_graphs, phase_transitions, artifacts.

import "std.sql" as sql

import "lex-soft/src/migrate" as soft_migrate

fn ddl_sprint_graphs() -> Str {
  "CREATE TABLE IF NOT EXISTS sprint_graphs (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, phase TEXT NOT NULL, graph_json TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn ddl_sprint_graphs_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_sg_sprint ON sprint_graphs(sprint_id)"
}

fn ddl_phase_transitions() -> Str {
  "CREATE TABLE IF NOT EXISTS phase_transitions (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, from_phase TEXT NOT NULL, to_phase TEXT NOT NULL, evidence TEXT NOT NULL, ts TEXT NOT NULL)"
}

fn ddl_artifacts() -> Str {
  "CREATE TABLE IF NOT EXISTS artifacts (hash TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, node_id TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn exec_ddl(db :: Db, stmt :: Str) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, stmt, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn run(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match soft_migrate.run(db) {
    Err(e) => Err(e),
    Ok(_) => match exec_ddl(db, ddl_sprint_graphs()) {
      Err(e) => Err(e),
      Ok(_) => match exec_ddl(db, ddl_sprint_graphs_idx()) {
        Err(e) => Err(e),
        Ok(_) => match exec_ddl(db, ddl_phase_transitions()) {
          Err(e) => Err(e),
          Ok(_) => exec_ddl(db, ddl_artifacts()),
        },
      },
    },
  }
}
