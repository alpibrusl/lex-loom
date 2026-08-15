# demo/org4_seed.lex — CLI scaffolding for demo/org4-ceo-pivot-roundtrip.sh.
#
# Seeds companies for the ORG4 acceptance scenario using ONLY real
# production functions (company.save_company / record_iteration /
# finish_iteration / record_operate_signal) — what the demo proves is what
# a real company looks like to the CEO heartbeat.
#
# Commands (DB_PATH + COMPANY_ID via env):
#   seed_distressed_cmd — 2 consecutive failed iterations + a flat
#                         settlement-recorded revenue signal, plus a `ceo`
#                         pool agent (proc executor) that proposes a pivot.
#   seed_healthy_cmd    — 2 successful iterations, same CEO agent: the
#                         mechanical gate must keep the CEO un-consulted.
#   goal_cmd            — print the company's CURRENT goal (what the
#                         Strategist executes next).
#   ledger_cmd          — print mission_ledger rows as "idx|source|approved_by|mission".

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/ceo" as ceo

import "../src/company" as company

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

fn founding_goal() -> Str {
  "founding mission: build a widget factory"
}

fn base_cfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: founding_goal(), model: "proc:cat", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_iteration(db :: conn.ConnDb, cid :: Str, idx :: Int, status :: Str) -> [sql, fs_write, time] Unit {
  let __r := company.record_iteration(db, { company_id: cid, idx: idx, sprint_id: str.join([cid, "/iter-", int.to_str(idx)], ""), parent_sprint_id: "", status: "running", goal: founding_goal() })
  let __f := company.finish_iteration(db, cid, idx, status)
  ()
}

fn seed_ceo_agent(db :: conn.ConnDb) -> [sql, fs_write] Result[Unit, Str] {
  let model := "proc:echo '{\"proposal\": \"pivot\", \"new_goal\": \"pivot to a paid analytics API\", \"rationale\": \"two failed iterations and flat revenue\"}'"
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES ('org4-pool-ceo', 'ceo', '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(model)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn seed_distressed_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "org4co")
  match open_db() {
    Err(e) => io.print(str.concat("[org4-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := company.save_company(db, base_cfg(cid))
      let __i1 := seed_iteration(db, cid, 1, "failed")
      let __i2 := seed_iteration(db, cid, 2, "failed")
      let __r1 := company.record_operate_signal(db, cid, 1, "revenue_cents", "{\"revenue_cents\": 100}")
      let __r2 := company.record_operate_signal(db, cid, 2, "revenue_cents", "{\"revenue_cents\": 100}")
      let __a := seed_ceo_agent(db)
      io.print(str.join(["[org4-seed] ", cid, ": 2 failed iterations, flat revenue ($1.00 twice), CEO agent in the pool"], ""))
    },
  }
}

fn seed_healthy_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "org4well")
  match open_db() {
    Err(e) => io.print(str.concat("[org4-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := company.save_company(db, base_cfg(cid))
      let __i1 := seed_iteration(db, cid, 1, "success")
      let __i2 := seed_iteration(db, cid, 2, "success")
      let __a := seed_ceo_agent(db)
      io.print(str.join(["[org4-seed] ", cid, ": 2 successful iterations, CEO agent in the pool (must stay silent)"], ""))
    },
  }
}

fn goal_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org4co")
  match open_db() {
    Err(e) => io.print(str.concat("[org4-seed] FATAL: ", e)),
    Ok(db) => match company.load_company(db, cid) {
      None => io.print("[org4-seed] no company row"),
      Some(c) => io.print(str.concat("goal: ", c.goal)),
    },
  }
}

fn ledger_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org4co")
  match open_db() {
    Err(e) => io.print(str.concat("[org4-seed] FATAL: ", e)),
    Ok(db) => {
      let __each := list.map(ceo.mission_history(db, cid), fn (r :: ceo.LedgerRow) -> [io] Unit {
        io.print(str.join([int.to_str(r.idx), "|", r.source, "|", r.approved_by, "|", r.mission], ""))
      })
      ()
    },
  }
}

