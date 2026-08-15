# cast.lex — Cast phase: assign best pool agent per sprint node.
#
# Between Design and Implementation the Caster scores pool agents against
# the sprint request and builds a Roster — a per-node agent assignment.
# Attestation counts grow after each accepted node, tightening the ranking.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.env" as env

import "lex-orm/src/connection" as conn

import "std.time" as time

import "lex-schema/json_value" as jv

import "lex-llm/src/providers" as providers

import "./agent/runner" as runner

import "./roles" as roles

import "./graph" as graph

import "./manifests" as manifests

import "./org" as org

import "./role_registry" as registry

import "./transport" as tr

import "lex-orm/src/query" as ormq

# ── Types ─────────────────────────────────────────────────────────────────────
# `reputation` is the did:lex layer (#52): the count of this agent's VERIFIED
# sprint attestations — earned only from runs that passed the four-layer
# verifier, portable across looms. Distinct from attestation_count, the local
# accept/bounce fitness signal that accrues without independent verification.
type PoolAgent = { id :: Str, role :: Str, system_prompt :: Str, model_name :: Str, domain_tags_json :: Str, attestation_count :: Int, reputation :: Int }

type RosterEntry = { node_id :: Str, pool_agent_id :: Str, agent_config :: runner.AgentDef }

type Roster = List[RosterEntry]

# ── Pool query ────────────────────────────────────────────────────────────────
type PoolAgentRow = { id :: Str, role :: Str, system_prompt :: Str, model_name :: Str, domain_tags_json :: Str, attestation_count :: Int, reputation :: Int }

fn row_to_agent(r :: PoolAgentRow) -> PoolAgent {
  { id: r.id, role: r.role, system_prompt: r.system_prompt, model_name: r.model_name, domain_tags_json: r.domain_tags_json, attestation_count: r.attestation_count, reputation: r.reputation }
}

fn load_pool_for_role(db :: conn.ConnDb, role :: Str) -> [sql, fs_read] List[PoolAgent] {
  let qd := ormq.for_dialect({ sql: "SELECT id, role, system_prompt, model_name, domain_tags_json, attestation_count, (SELECT COUNT(*) FROM attestations a WHERE a.agent_id = agent_pool.id AND a.verified = 1) AS reputation FROM agent_pool WHERE role=? AND retired_at='' ORDER BY attestation_count DESC", params: [PStr(role)] }, db.dialect)
  let rows :: Result[List[PoolAgentRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, row_to_agent),
  }
}

# ── Scoring ───────────────────────────────────────────────────────────────────
fn domain_bonus(tags_json :: Str, request :: Str) -> Int {
  match jv.parse(tags_json) {
    Err(_) => 0,
    Ok(JList(items)) => list.fold(items, 0, fn (acc :: Int, item :: jv.Json) -> Int {
      match item {
        JStr(tag) => if str.contains(request, tag) {
          acc + 10
        } else {
          acc
        },
        _ => acc,
      }
    }),
    Ok(_) => 0,
  }
}

# A verified-run reputation point (independently re-derivable, #52) outweighs
# a raw local attestation, but not a domain-tag match (+10) — a proven
# generalist should not displace a matching specialist.
fn score_agent(agent :: PoolAgent, request :: Str) -> Int {
  agent.attestation_count + 3 * agent.reputation + domain_bonus(agent.domain_tags_json, request)
}

fn best_agent(agents :: List[PoolAgent], request :: Str) -> Option[PoolAgent] {
  match list.head(agents) {
    None => None,
    Some(first) => Some(list.fold(agents, first, fn (acc :: PoolAgent, a :: PoolAgent) -> PoolAgent {
      if score_agent(a, request) > score_agent(acc, request) {
        a
      } else {
        acc
      }
    })),
  }
}

# ── AgentConfig assembly ──────────────────────────────────────────────────────
# model_name conventions:
#   "proc:<cmd>"  → proc executor, cmd is the shell command (input piped via stdin)
#   "a2a:<url>"   → A2A executor, url is the remote agent endpoint
#   anything else → LLM executor
fn pool_agent_to_config(a :: PoolAgent, fallback :: runner.AgentDef, model :: Str) -> runner.AgentDef {
  let raw := if str.is_empty(a.model_name) {
    model
  } else {
    a.model_name
  }
  let is_proc := str.starts_with(raw, "proc:")
  let is_a2a := str.starts_with(raw, "a2a:")
  let proc_cmd := if is_proc {
    str.slice(raw, 5, str.len(raw))
  } else {
    ""
  }
  let a2a_url := if is_a2a {
    str.slice(raw, 4, str.len(raw))
  } else {
    ""
  }
  { id: a.id, kind: a.role, system_prompt: a.system_prompt, model_name: raw, provider: fallback.provider, tools: fallback.tools, proc_cmd: proc_cmd, a2a_url: a2a_url, sprint_id: fallback.sprint_id }
}

fn default_config_for_role(role :: Str, model :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  match roles.for_role(role, model, evidence_path, sprint_id) {
    Some(c) => c,
    None => { id: str.concat("fallback-", role), kind: role, system_prompt: "", model_name: model, provider: providers.ollama_local(), tools: [], proc_cmd: "", a2a_url: "", sprint_id: sprint_id },
  }
}

# ── Roster helpers ────────────────────────────────────────────────────────────
fn roster_lookup(roster :: Roster, node_id :: Str) -> Option[runner.AgentDef] {
  list.fold(roster, None, fn (acc :: Option[runner.AgentDef], e :: RosterEntry) -> Option[runner.AgentDef] {
    match acc {
      Some(_) => acc,
      None => if e.node_id == node_id {
        Some(e.agent_config)
      } else {
        None
      },
    }
  })
}

fn empty_roster() -> Roster {
  []
}

# ── Cast a single node ────────────────────────────────────────────────────────
fn cast_node(db :: conn.ConnDb, n :: graph.Node, request :: Str, model :: Str, sprint_id :: Str) -> [env, sql, fs_read, fs_write, time, random, crypto] RosterEntry {
  let evidence_path := runner.qa_evidence_path(sprint_id, n.id)
  let candidates := load_pool_for_role(db, n.role)
  let company_id := match list.head(str.split(sprint_id, "/")) {
    Some(cid) => cid,
    None => sprint_id,
  }
  let fallback := match roles.for_role(n.role, model, evidence_path, sprint_id) {
    Some(c) => c,
    None => match registry.lookup_active(db, company_id, n.role) {
      Some(d) => registry.def_to_agent(d, model, sprint_id),
      None => default_config_for_role(n.role, model, evidence_path, sprint_id),
    },
  }
  let entry := match best_agent(candidates, request) {
    None => { node_id: n.id, pool_agent_id: "", agent_config: fallback },
    Some(agent) => {
      let cfg := pool_agent_to_config(agent, fallback, model)
      { node_id: n.id, pool_agent_id: agent.id, agent_config: cfg }
    },
  }
  let __auth := record_cast_authority(db, sprint_id, n, entry)
  entry
}

# ORG1 (lex-loom#216): every casting records WHOSE authority it ran under —
# the cast role's manager per the company org chart ("" for a flat company or
# an unmanaged role). Consumed by ORG2/ORG3 (delegation, manager review);
# today it makes the org chart load-bearing in the audit trail rather than
# decorative.
fn record_cast_authority(db :: conn.ConnDb, sprint_id :: Str, n :: graph.Node, entry :: RosterEntry) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let company_id := match list.head(str.split(sprint_id, "/")) {
    Some(cid) => cid,
    None => sprint_id,
  }
  let manager := match org.manager_of(org.load_org(db, company_id), n.role) {
    None => "",
    Some(m) => m,
  }
  tr.trail(db, sprint_id, "node_cast", str.join(["{\"node\":\"", n.id, "\",\"role\":\"", n.role, "\",\"agent\":\"", entry.pool_agent_id, "\",\"authority\":\"", manager, "\"}"], ""))
}

# ── Build full roster for a sprint graph ─────────────────────────────────────
fn select_roster(db :: conn.ConnDb, g :: graph.SprintGraph, request :: Str, model :: Str, sprint_id :: Str) -> [env, sql, fs_read, fs_write, time, random, crypto] Roster {
  list.map(g.nodes, fn (n :: graph.Node) -> [env, sql, fs_read, fs_write, time, random, crypto] RosterEntry {
    cast_node(db, n, request, model, sprint_id)
  })
}

# ── Attestation update ────────────────────────────────────────────────────────
fn increment_attestation(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "UPDATE agent_pool SET attestation_count = attestation_count + 1, last_attested_at = ? WHERE id = ?", params: [PStr(now), PStr(agent_id)] }, db.dialect)
  let __r := sql.exec(db.handle, qd.sql, qd.params)
  ()
}

fn decrement_attestation(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "UPDATE agent_pool SET attestation_count = attestation_count - 1, bounce_count = bounce_count + 1, last_attested_at = ? WHERE id = ?", params: [PStr(now), PStr(agent_id)] }, db.dialect)
  let __r := sql.exec(db.handle, qd.sql, qd.params)
  ()
}

fn check_and_retire(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "UPDATE agent_pool SET retired_at = ? WHERE id = ? AND attestation_count <= -3 AND retired_at = ''", params: [PStr(now), PStr(agent_id)] }, db.dialect)
  let __r := sql.exec(db.handle, qd.sql, qd.params)
  ()
}

fn record_bounce(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_write, time] Unit {
  let __d := decrement_attestation(db, agent_id)
  check_and_retire(db, agent_id)
}

# ── Grant reporting (OA1, lex-loom#182) ──────────────────────────────────────
# For a given roster, which lex-os grant preset each node's role would run
# under — the company's declared [policy.isolation] override if one exists
# for that role kind, else manifests.lex's own default mapping. Purely
# informational: doesn't call anything execution-affecting, and nothing
# else in this file (cast_node/select_roster, above) reads it — the real
# proc_cmd mediation path stays exactly as it is until OA2.
type GrantReportEntry = { node_id :: Str, role :: Str, preset :: Str }

fn roster_grant_report(roster :: Roster, policy_isolation :: Str) -> List[GrantReportEntry] {
  let overrides := manifests.parse_isolation_overrides(policy_isolation)
  list.map(roster, fn (e :: RosterEntry) -> GrantReportEntry {
    { node_id: e.node_id, role: e.agent_config.kind, preset: manifests.preset_for_kind_with_overrides(e.agent_config.kind, overrides) }
  })
}

fn grant_report_line(e :: GrantReportEntry) -> Str {
  str.join(["  ", e.node_id, " (", e.role, ") -> ", e.preset], "")
}

# Human-readable rendering of roster_grant_report — what a CLI command or
# board_report-style view would actually print.
fn grant_report_text(roster :: Roster, policy_isolation :: Str) -> Str {
  let entries := roster_grant_report(roster, policy_isolation)
  if list.is_empty(entries) {
    "(empty roster)"
  } else {
    str.join(list.map(entries, grant_report_line), "\n")
  }
}

fn update_pool_from_sprint(db :: conn.ConnDb, roster :: Roster, accepted_node_ids :: List[Str]) -> [sql, fs_write, time] Unit {
  let __r := list.map(roster, fn (entry :: RosterEntry) -> [sql, fs_write, time] Unit {
    if str.is_empty(entry.pool_agent_id) {
      ()
    } else {
      let accepted := list.fold(accepted_node_ids, false, fn (ok :: Bool, id :: Str) -> Bool {
        if ok {
          true
        } else {
          id == entry.node_id
        }
      })
      if accepted {
        increment_attestation(db, entry.pool_agent_id)
      } else {
        record_bounce(db, entry.pool_agent_id)
      }
    }
  })
  ()
}

