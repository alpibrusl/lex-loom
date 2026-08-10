# migrate.lex — full DDL for loom.
#
# Platform tables (agents, relationships, agent_state, traces) are created
# first, followed by loom-specific tables: sprint_graphs, phase_transitions,
# artifacts, digests, tightened_specs.

import "std.sql" as sql

import "std.list" as list

import "lex-jobs/src/jobs" as jobs

import "lex-orm/src/connection" as conn

import "lex-agent/src/memory" as mem

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

# AG-UI replay events (agui_store.lex): one row per LLM turn, keyed by the
# same run_id runner.lex's trace events already use to correlate a step()
# call. events_json is the pre-encoded AguiEvent list (lex-ag-ui's own
# wire format) -- server.lex replays it as-is, it never re-derives it.
fn ddl_node_agui_events() -> Str {
  "CREATE TABLE IF NOT EXISTS node_agui_events (run_id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, agent_id TEXT NOT NULL, events_json TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn ddl_node_agui_events_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_agui_sprint_created ON node_agui_events(sprint_id, created_at)"
}

fn ddl_agent_pool() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_pool (id TEXT PRIMARY KEY, role TEXT NOT NULL, system_prompt TEXT NOT NULL, model_name TEXT NOT NULL DEFAULT '', domain_tags_json TEXT NOT NULL DEFAULT '[]', attestation_count INTEGER NOT NULL DEFAULT 0, bounce_count INTEGER NOT NULL DEFAULT 0, retired_at TEXT NOT NULL DEFAULT '', last_attested_at TEXT, created_at TEXT NOT NULL)"
}

fn ddl_agent_pool_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_ap_role ON agent_pool(role)"
}

# Attention queue — items awaiting human attestation (Judgeable-lane gates).
# verdict: pending | approved | rejected
fn ddl_attention_queue() -> Str {
  "CREATE TABLE IF NOT EXISTS attention_queue (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, node_id TEXT NOT NULL, gate TEXT NOT NULL, oracle TEXT NOT NULL, artifact_hash TEXT NOT NULL DEFAULT '', verdict TEXT NOT NULL DEFAULT 'pending', rejection_reason TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT '', resolved_by TEXT NOT NULL DEFAULT '')"
}

fn ddl_attention_queue_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_aq_oracle_verdict ON attention_queue(oracle, verdict)"
}

# sprint_runs — maps a sprint_id to the native `lex run --trace` run_id (#7),
# so a finished sprint can be inspected with `lex trace <run_id>` and re-run
# with `lex replay <run_id> ... --override`. A sprint may be traced more than
# once (re-runs); the latest row by created_at is the canonical native run.
fn ddl_sprint_runs() -> Str {
  "CREATE TABLE IF NOT EXISTS sprint_runs (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, run_id TEXT NOT NULL, created_at TEXT NOT NULL)"
}

fn ddl_sprint_runs_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_sprint_runs_sprint ON sprint_runs(sprint_id, created_at)"
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

fn ddl_traces() -> Str {
  "CREATE TABLE IF NOT EXISTS traces (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, agent_id TEXT NOT NULL, event_kind TEXT NOT NULL, data_json TEXT, ts TEXT NOT NULL)"
}

fn ddl_traces_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_traces_agent_ts ON traces(agent_id, ts)"
}

# Company layer (#53): a persistent goal producing a series of iterating looms.
fn ddl_companies() -> Str {
  "CREATE TABLE IF NOT EXISTS companies (id TEXT PRIMARY KEY, goal TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', max_iterations INTEGER NOT NULL DEFAULT 1, stop_when TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL)"
}

fn ddl_company_iterations() -> Str {
  "CREATE TABLE IF NOT EXISTS company_iterations (company_id TEXT NOT NULL, idx INTEGER NOT NULL, sprint_id TEXT NOT NULL, parent_sprint_id TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'running', started_at TEXT NOT NULL DEFAULT '', ended_at TEXT NOT NULL DEFAULT '', PRIMARY KEY (company_id, idx))"
}

fn ddl_company_iterations_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_citer_company ON company_iterations(company_id, idx)"
}

# Backlog (#75): features the strategist has queued but not yet worked on.
# status: pending | active | done.
fn ddl_company_backlog() -> Str {
  "CREATE TABLE IF NOT EXISTS company_backlog (company_id TEXT NOT NULL, idx INTEGER NOT NULL, goal TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL, PRIMARY KEY (company_id, idx))"
}

fn ddl_company_backlog_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_backlog_company_status ON company_backlog(company_id, status, idx)"
}

# Portfolio (C7, #78): a company can hold N concurrent product tracks. A track
# IS a company — its id is the composite "<portfolio_id>/<track_id>" — so it
# gets the full FSM/backlog/dormancy/resume machinery for free. This table is
# just the portfolio's own bookkeeping of which tracks exist and whether
# they're still being worked. status: active | paused | done.
fn ddl_portfolio_tracks() -> Str {
  "CREATE TABLE IF NOT EXISTS portfolio_tracks (portfolio_id TEXT NOT NULL, track_id TEXT NOT NULL, goal TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active', created_at TEXT NOT NULL, PRIMARY KEY (portfolio_id, track_id))"
}

fn ddl_portfolio_tracks_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_portfolio_status ON portfolio_tracks(portfolio_id, status)"
}

# Board layer (#82): the human board member's advisory input. Notes are
# one-shot — the strategist reads pending ones on its next decision, then
# they're marked consumed, so a note doesn't repeat forever. Advisory only:
# the company runs unattended whether or not any notes exist.
fn ddl_company_board_notes() -> Str {
  "CREATE TABLE IF NOT EXISTS company_board_notes (company_id TEXT NOT NULL, idx INTEGER NOT NULL, note TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL, PRIMARY KEY (company_id, idx))"
}

fn ddl_company_board_notes_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_board_notes_status ON company_board_notes(company_id, status, idx)"
}

# Operate loop (#84/#85) — observations from OUTSIDE a company's own build
# sandbox: is the last-launched server actually still responding, between
# iterations. Append-only, timestamped, sourced by `kind` so later signal
# types (revenue, support volume) can share the table without a schema change.
fn ddl_company_operate_signals() -> Str {
  "CREATE TABLE IF NOT EXISTS company_operate_signals (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, idx INTEGER NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, observed_at TEXT NOT NULL)"
}

fn ddl_company_operate_signals_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_operate_signals_company ON company_operate_signals(company_id, kind, idx)"
}

# Operate ledger (#118/#120) — the controller's record, CTL2. Row ids are
# content-addressed (SHA-256 over canonical fields, computed in
# operate_ledger.lex) so the same logical fact has the same id wherever it
# is materialized; the authoritative tamper-evident record is the lex-trail
# chain (loom.operate.* kinds), these tables are the queryable projection —
# same dual-write pattern as sprint traces vs loom_trail.
fn ddl_operate_incidents() -> Str {
  "CREATE TABLE IF NOT EXISTS operate_incidents (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, opened_at TEXT NOT NULL, closed_at TEXT NOT NULL DEFAULT '', status TEXT NOT NULL, symptoms_json TEXT NOT NULL, budget_spent_milli INTEGER NOT NULL DEFAULT 0, budget_cap_milli INTEGER NOT NULL DEFAULT 0, root_cause TEXT NOT NULL DEFAULT '')"
}

fn ddl_operate_incidents_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_op_inc_company ON operate_incidents(company_id, opened_at)"
}

fn ddl_operate_actions() -> Str {
  "CREATE TABLE IF NOT EXISTS operate_actions (id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, company_id TEXT NOT NULL, class_key TEXT NOT NULL, subsystem TEXT NOT NULL, params_json TEXT NOT NULL DEFAULT '{}', tier TEXT NOT NULL, executed_at TEXT NOT NULL)"
}

fn ddl_operate_actions_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_op_act_incident ON operate_actions(incident_id, executed_at)"
}

fn ddl_operate_effects() -> Str {
  "CREATE TABLE IF NOT EXISTS operate_effects (id TEXT PRIMARY KEY, action_id TEXT NOT NULL, incident_id TEXT NOT NULL, signal TEXT NOT NULL, cmp TEXT NOT NULL, threshold_milli INTEGER NOT NULL, contracted_at TEXT NOT NULL, deadline_at TEXT NOT NULL, confidence_pct INTEGER NOT NULL, on_falsify TEXT NOT NULL, disposition TEXT NOT NULL DEFAULT 'pending', disposed_at TEXT NOT NULL DEFAULT '')"
}

fn ddl_operate_effects_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_op_eff_incident ON operate_effects(incident_id, contracted_at)"
}

fn ddl_operate_evidence() -> Str {
  "CREATE TABLE IF NOT EXISTS operate_evidence (id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, query_text TEXT NOT NULL, cost_milli INTEGER NOT NULL, result_ref TEXT NOT NULL DEFAULT '', observed_at TEXT NOT NULL)"
}

fn ddl_operate_evidence_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_op_ev_incident ON operate_evidence(incident_id, observed_at)"
}

# Last-known tier per (company, class) — the baseline `actuation.lex`'s
# transition detector diffs the freshly-computed `real_tier` against, so
# `loom.operate.tier.changed` fires only on a real move, not every sweep.
fn ddl_operate_tier_state() -> Str {
  "CREATE TABLE IF NOT EXISTS operate_tier_state (company_id TEXT NOT NULL, class_key TEXT NOT NULL, tier TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY (company_id, class_key))"
}

# did:lex portable reputation (#52): signed attestation bundles. Reputation is
# DERIVED (count of verified rows per did), never stored — nothing to forge.
fn ddl_attestations() -> Str {
  "CREATE TABLE IF NOT EXISTS attestations (id TEXT PRIMARY KEY, sprint_id TEXT NOT NULL, agent_id TEXT NOT NULL, agent_did TEXT NOT NULL, role TEXT NOT NULL, bundle_json TEXT NOT NULL, sig_b64 TEXT NOT NULL, pubkey_b64 TEXT NOT NULL, verified INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)"
}

fn ddl_attestations_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_att_did ON attestations(agent_did, verified)"
}

fn try_ddl(db :: Db, stmt :: Str) -> [sql, fs_write] Unit {
  let __r := sql.exec(db, stmt, [])
  ()
}

fn run_upgrades(db :: Db) -> [sql, fs_write] Unit {
  let __1 := try_ddl(db, "ALTER TABLE agent_pool ADD COLUMN bounce_count INTEGER NOT NULL DEFAULT 0")
  let __2 := try_ddl(db, "ALTER TABLE agent_pool ADD COLUMN retired_at TEXT NOT NULL DEFAULT ''")
  let __3 := try_ddl(db, "ALTER TABLE agent_pool ADD COLUMN did TEXT NOT NULL DEFAULT ''")
  let __4 := try_ddl(db, "ALTER TABLE agent_pool ADD COLUMN pubkey_b64 TEXT NOT NULL DEFAULT ''")
  let __5 := try_ddl(db, "ALTER TABLE agent_pool ADD COLUMN secret_b64 TEXT NOT NULL DEFAULT ''")
  let __6 := try_ddl(db, "ALTER TABLE companies ADD COLUMN stage TEXT NOT NULL DEFAULT 'ideation'")
  let __7 := try_ddl(db, "ALTER TABLE companies ADD COLUMN pmf_when TEXT NOT NULL DEFAULT ''")
  let __8 := try_ddl(db, "ALTER TABLE companies ADD COLUMN maintenance_when TEXT NOT NULL DEFAULT ''")
  let __9 := try_ddl(db, "ALTER TABLE companies ADD COLUMN wake_when TEXT NOT NULL DEFAULT ''")
  let __10 := try_ddl(db, "ALTER TABLE company_iterations ADD COLUMN goal TEXT NOT NULL DEFAULT ''")
  let __11 := try_ddl(db, "ALTER TABLE companies ADD COLUMN total_cost_cents INTEGER NOT NULL DEFAULT 0")
  let __12 := try_ddl(db, "ALTER TABLE company_operate_signals ADD COLUMN incident_id TEXT NOT NULL DEFAULT ''")
  let __13 := try_ddl(db, "ALTER TABLE company_operate_signals ADD COLUMN score_milli INTEGER NOT NULL DEFAULT 0")
  let __14 := try_ddl(db, "ALTER TABLE operate_incidents ADD COLUMN hypotheses_json TEXT NOT NULL DEFAULT ''")
  let __15 := try_ddl(db, "ALTER TABLE operate_incidents ADD COLUMN diagnosed_cause TEXT NOT NULL DEFAULT ''")
  let __16 := try_ddl(db, "ALTER TABLE operate_incidents ADD COLUMN diagnosed_p_pct INTEGER NOT NULL DEFAULT 0")
  let __17 := try_ddl(db, "ALTER TABLE operate_incidents ADD COLUMN diagnosis_gap INTEGER NOT NULL DEFAULT 0")
  let __18 := try_ddl(db, "ALTER TABLE operate_effects ADD COLUMN contracted_at_idx INTEGER NOT NULL DEFAULT 0")
  let __19 := try_ddl(db, "ALTER TABLE operate_effects ADD COLUMN deadline_idx INTEGER NOT NULL DEFAULT 0")
  let __20 := try_ddl(db, "ALTER TABLE operate_effects ADD COLUMN expected_state_hash TEXT NOT NULL DEFAULT ''")
  let __21 := try_ddl(db, "ALTER TABLE companies ADD COLUMN soft_mesh_url TEXT NOT NULL DEFAULT ''")
  let __22 := try_ddl(db, "ALTER TABLE companies ADD COLUMN soft_org_id TEXT NOT NULL DEFAULT ''")
  let __23 := try_ddl(db, "ALTER TABLE companies ADD COLUMN soft_roles TEXT NOT NULL DEFAULT ''")
  let __24 := try_ddl(db, "ALTER TABLE companies ADD COLUMN soft_settlement TEXT NOT NULL DEFAULT ''")
  let __25 := try_ddl(db, "ALTER TABLE companies ADD COLUMN policy_isolation TEXT NOT NULL DEFAULT ''")
  let __26 := try_ddl(db, "ALTER TABLE attention_queue ADD COLUMN resolved_by TEXT NOT NULL DEFAULT ''")
  ()
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

# agent_memory's schema is owned by lex-agent/src/memory (lex-loom#206) —
# it's the same table `agent/runner.lex` reads through `mem.recall_all`/
# `mem.load_state` every step, so this repo no longer hand-declares a second,
# driftable copy of its shape (a real gap: this repo's own copy had fallen
# behind lex-agent's extended columns — mtype/importance/scope/superseded/
# expires_at — silently breaking recall via `mem.recall_all`'s SELECT of
# columns this table didn't have, swallowed by that fn's own `Err(_) => []`).
# loom is SQLite-only (no Postgres path anywhere in this repo), so the
# dialect is hardcoded rather than probed.
fn mem_conndb(db :: Db) -> conn.ConnDb {
  { dialect: DbSqlite(()), handle: db }
}

fn run(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match run_step(db, [ddl_agents(), ddl_relationships(), ddl_rel_idx(), ddl_agent_state(), ddl_traces(), ddl_traces_idx(), ddl_sprint_graphs(), ddl_sprint_graphs_idx(), ddl_phase_transitions(), ddl_artifacts(), ddl_digests(), ddl_digests_idx(), ddl_tightened_specs(), ddl_tightened_specs_idx(), ddl_node_results(), ddl_node_results_idx(), ddl_agent_pool(), ddl_agent_pool_idx(), ddl_attention_queue(), ddl_attention_queue_idx(), ddl_sprint_runs(), ddl_sprint_runs_idx(), ddl_companies(), ddl_company_iterations(), ddl_company_iterations_idx(), ddl_attestations(), ddl_attestations_idx(), ddl_company_backlog(), ddl_company_backlog_idx(), ddl_portfolio_tracks(), ddl_portfolio_tracks_idx(), ddl_company_board_notes(), ddl_company_board_notes_idx(), ddl_company_operate_signals(), ddl_company_operate_signals_idx(), ddl_operate_incidents(), ddl_operate_incidents_idx(), ddl_operate_actions(), ddl_operate_actions_idx(), ddl_operate_effects(), ddl_operate_effects_idx(), ddl_operate_evidence(), ddl_operate_evidence_idx(), ddl_operate_tier_state(), ddl_node_agui_events(), ddl_node_agui_events_idx()]) {
    Err(e) => Err(e),
    Ok(_) => match mem.init_schema(mem_conndb(db)) {
      Err(e) => Err(e),
      Ok(_) => {
        let __jobs := jobs.init_schema(db)
        let __up := run_upgrades(db)
        Ok(())
      },
    },
  }
}

