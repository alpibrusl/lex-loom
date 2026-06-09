# migrate.lex — full DDL for loom.
#
# Platform tables (agents, relationships, agent_state, traces) are created
# first, followed by loom-specific tables: sprint_graphs, phase_transitions,
# artifacts, digests, tightened_specs.

import "std.sql" as sql

import "std.list" as list

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

fn ddl_digests() -> Str {
  "CREATE TABLE IF NOT EXISTS digests (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, summary_text TEXT NOT NULL DEFAULT '', lessons TEXT NOT NULL, seed_graph_json TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn ddl_digests_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_digests_sprint ON digests(sprint_id, created_at)"
}

fn ddl_tightened_specs() -> Str {
  "CREATE TABLE IF NOT EXISTS tightened_specs (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, node_role TEXT NOT NULL, spec_src TEXT NOT NULL, reason TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn ddl_tightened_specs_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_tspec_sprint ON tightened_specs(sprint_id)"
}

# Node results written by durable-queue workers; read by the orchestrator join.
fn ddl_node_results() -> Str {
  "CREATE TABLE IF NOT EXISTS node_results (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, node_id TEXT NOT NULL, phase TEXT NOT NULL, accepted INTEGER NOT NULL DEFAULT 0, artifact TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL)"
}

fn ddl_node_results_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_nr_sprint_phase ON node_results(sprint_id, phase)"
}

fn ddl_agent_pool() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_pool (id TEXT PRIMARY KEY, role TEXT NOT NULL, system_prompt TEXT NOT NULL, model_name TEXT NOT NULL DEFAULT '', domain_tags_json TEXT NOT NULL DEFAULT '[]', attestation_count INTEGER NOT NULL DEFAULT 0, last_attested_at TEXT, created_at TEXT NOT NULL)"
}

fn ddl_agent_pool_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_ap_role ON agent_pool(role)"
}

# Attention queue — items awaiting human attestation (Judgeable-lane gates).
# verdict: pending | approved | rejected
fn ddl_attention_queue() -> Str {
  "CREATE TABLE IF NOT EXISTS attention_queue (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, node_id TEXT NOT NULL, gate TEXT NOT NULL, oracle TEXT NOT NULL, artifact_hash TEXT NOT NULL DEFAULT '', verdict TEXT NOT NULL DEFAULT 'pending', rejection_reason TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT '')"
}

fn ddl_attention_queue_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_aq_oracle_verdict ON attention_queue(oracle, verdict)"
}

fn exec_ddl(db :: Db, stmt :: Str) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, stmt, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn ddl_agents() -> Str {
  "CREATE TABLE IF NOT EXISTS agents (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, inbox_url TEXT NOT NULL, capabilities_json TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', registered_at TEXT NOT NULL, last_seen_at TEXT NOT NULL)"
}

fn ddl_relationships() -> Str {
  "CREATE TABLE IF NOT EXISTS relationships (id TEXT PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, role TEXT NOT NULL, contract_json TEXT NOT NULL DEFAULT '{}', active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)"
}

fn ddl_rel_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_agent, active)"
}

fn ddl_agent_state() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_state (agent_id TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at TEXT NOT NULL)"
}

fn ddl_agent_memory() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_memory (id TEXT NOT NULL PRIMARY KEY, agent_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL DEFAULT '', content TEXT NOT NULL, ts TEXT NOT NULL)"
}

fn ddl_agent_memory_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_mem_agent ON agent_memory(agent_id, kind)"
}

fn ddl_traces() -> Str {
  "CREATE TABLE IF NOT EXISTS traces (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, agent_id TEXT NOT NULL, event_kind TEXT NOT NULL, data_json TEXT, ts TEXT NOT NULL)"
}

fn ddl_traces_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_traces_agent_ts ON traces(agent_id, ts)"
}

fn run_step(db :: Db, stmts :: List[Str]) -> [sql, fs_write] Result[Unit, Str] {
  match list.head(stmts) {
    None => Ok(()),
    Some(stmt) => match exec_ddl(db, stmt) {
      Err(e) => Err(e),
      Ok(_) => run_step(db, list.tail(stmts)),
    },
  }
}

fn run(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  run_step(db, [
    ddl_agents(),
    ddl_relationships(),
    ddl_rel_idx(),
    ddl_agent_state(),
    ddl_agent_memory(),
    ddl_agent_memory_idx(),
    ddl_traces(),
    ddl_traces_idx(),
    ddl_sprint_graphs(),
    ddl_sprint_graphs_idx(),
    ddl_phase_transitions(),
    ddl_artifacts(),
    ddl_digests(),
    ddl_digests_idx(),
    ddl_tightened_specs(),
    ddl_tightened_specs_idx(),
    ddl_node_results(),
    ddl_node_results_idx(),
    ddl_agent_pool(),
    ddl_agent_pool_idx(),
    ddl_attention_queue(),
    ddl_attention_queue_idx(),
  ])
}

