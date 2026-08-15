# demo/gov4_seed.lex — CLI scaffolding for demo/gov4-board-surface-roundtrip.sh.
#
# Queues all five board decision types through the REAL producers:
#   gate       — a real GOV1 blocking human gate parking via orchestrator.run_phase
#   allocation — a real GOV3 allocation.heartbeat proposal
#   strategy   — a real ORG4 ceo.heartbeat proposal
#   role       — a real ORG5 role_registry.propose_role
#   operate    — queued at the exact address board.queue_operate_dossiers uses
#
# Commands (DB_PATH + COMPANY_ID via env):
#   seed_cmd         — company + pool (docs/finance/ceo proc agents) +
#                      envelope + verified revenue + 2 failed iterations.
#   gate_cmd         — park a real blocking human gate (SPRINT_ID).
#   gov_pass_cmd     — allocation.heartbeat + ceo.heartbeat (real proposals).
#   propose_role_cmd — role_registry.propose_role (real ORG5 path).
#   operate_cmd      — queue an operate escalation dossier decision.
#   contact_cmd      — company.add_contact(ORACLE, CONTACT_ID) — after this,
#                      only that contact may decide for the oracle (#165).

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-llm/src/providers" as providers

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/budget" as budget

import "../src/allocation" as allocation

import "../src/ceo" as ceo

import "../src/role_registry" as registry

import "../src/orchestrator" as orch

import "../src/cast" as cast

import "../src/transport" as tr

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None => default,
    Some(v) => if str.is_empty(v) {
      default
    } else {
      v
    },
  }
}

fn open_db() -> [env, sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(get_env("DB_PATH", "company.db")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, model_name :: Str) -> [sql, fs_write] Unit {
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(id), PStr(role), PStr(model_name)] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

fn fin_model() -> Str {
  "proc:echo '{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 2000}], \"rationale\": \"fund the next push\", \"prediction\": {\"target_cents\": 500, \"by_iteration\": 4}}'"
}

fn ceo_model() -> Str {
  "proc:echo '{\"proposal\": \"pivot\", \"new_goal\": \"pivot to a paid analytics API\", \"rationale\": \"two failed iterations and flat revenue\"}'"
}

fn seed_iteration(db :: conn.ConnDb, cid :: Str, idx :: Int, status :: Str, sid :: Str) -> [sql, fs_write, time] Unit {
  let __r := company.record_iteration(db, { company_id: cid, idx: idx, sprint_id: sid, parent_sprint_id: "", status: "running", goal: "g" })
  let __f := company.finish_iteration(db, cid, idx, status)
  ()
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: cid, goal: "sell widget analytics", model: "proc:cat", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __i1 := seed_iteration(db, cid, 1, "failed", str.concat(cid, "/iter-1"))
      let __i2 := seed_iteration(db, cid, 2, "failed", str.concat(cid, "/iter-2"))
      let __r := company.record_operate_signal(db, cid, 2, "revenue_cents", "{\"revenue_cents\": 100}")
      let __e := budget.set_envelope(db, cid, "total", 1000, "founder")
      let __a1 := seed_pool_agent(db, "gov4-pool-docs", "docs", "proc:cat")
      let __a2 := seed_pool_agent(db, "gov4-pool-finance", "finance", fin_model())
      let __a3 := seed_pool_agent(db, "gov4-pool-ceo", "ceo", ceo_model())
      io.print(str.join(["[gov4-seed] ", cid, ": company + pool + envelope + verified revenue + failing streak seeded"], ""))
    },
  }
}

fn proc_agent(node_id :: Str) -> cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: "docs", system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn gate_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  let sid := get_env("SPRINT_ID", str.concat(cid, "/iter-3"))
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => {
      let g := { id: sid, phase: Implementation, nodes: [{ id: "legal_review", role: "docs", gate: "human legal blocking", expand: None, activate_when: "" }], edges: [] }
      let trail_none :: Option[tlog.Log] := None
      let cfg := { id: sid, request: "publish the landing page", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("legal_review")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
      let __pr := orch.run_phase(g, Implementation, "", [], cfg)
      io.print(str.join(["[gov4-seed] blocking human gate parked in ", sid], ""))
    },
  }
}

fn gov_pass_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => {
      let __a := allocation.heartbeat(db, cid, 50)
      let __c := ceo.heartbeat(db, cid, 50)
      ()
    },
  }
}

fn propose_role_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto, vcs] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => match registry.propose_role(db, cid, "growth_hacker", "You are the Growth Hacker.", "none", "Demo", "ceo") {
      Ok(att) => io.print(str.concat("[gov4-seed] role proposal queued: ", att)),
      Err(m) => io.print(str.concat("[gov4-seed] ", m)),
    },
  }
}

fn operate_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => match tr.push_attention(db, str.concat(cid, "/operate"), "dossier", "operate escalation dossier", "board", "") {
      Ok(att) => io.print(str.concat("[gov4-seed] operate dossier decision queued: ", att)),
      Err(m) => io.print(str.concat("[gov4-seed] FATAL: ", m)),
    },
  }
}

fn contact_cmd() -> [env, io, sql, fs_read, fs_write, time, random] Unit {
  let cid := get_env("COMPANY_ID", "gov4co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov4-seed] FATAL: ", e)),
    Ok(db) => match company.add_contact(db, cid, get_env("ORACLE", "board"), get_env("CONTACT_ID", "board-jane"), "Jane", "") {
      Ok(_) => io.print(str.join(["[gov4-seed] contact ", get_env("CONTACT_ID", "board-jane"), " registered for oracle ", get_env("ORACLE", "board")], "")),
      Err(m) => io.print(str.concat("[gov4-seed] FATAL: ", m)),
    },
  }
}

