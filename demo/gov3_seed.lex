# demo/gov3_seed.lex — CLI scaffolding for demo/gov3-allocation-roundtrip.sh.
#
# Drives GOV3 through ONLY real production functions (allocation.heartbeat,
# budget.*, company.record_operate_signal) — no reimplementation.
#
# Commands (DB_PATH + COMPANY_ID via env):
#   seed_cmd      — save the company + a proc-executor finance agent whose
#                   proposal is deterministic (FIN_MODEL env).
#   revenue_cmd   — record a settlement-style verified revenue reading
#                   (IDX, CENTS).
#   iter_cmd      — record a finished iteration (IDX) so the company's
#                   iteration clock advances.
#   heartbeat_cmd — one real allocation.heartbeat pass (apply -> grade ->
#                   maybe propose).
#   allocs_cmd    — ledger rows as "status|target|by_iter|grade".
#   hitrate_cmd   — the allocation track record line the evidence carries.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/allocation" as allocation

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

fn default_fin_model() -> Str {
  "proc:echo '{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 2000}, {\"scope\": \"role:docs\", \"cap_cents\": 500}], \"rationale\": \"verified revenue is real - fund the docs push and raise the total\", \"prediction\": {\"target_cents\": 500, \"by_iteration\": 2}}'"
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: cid, goal: "sell widget analytics", model: "proc:cat", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __i := company.record_iteration(db, { company_id: cid, idx: 1, sprint_id: str.concat(cid, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g" })
      let __f := company.finish_iteration(db, cid, 1, "success")
      let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES ('gov3-pool-finance', 'finance', '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(get_env("FIN_MODEL", default_fin_model()))] }, db.dialect)
      let __a := sql.exec(db.handle, q.sql, q.params)
      io.print(str.join(["[gov3-seed] ", cid, " saved with a finance agent in the pool"], ""))
    },
  }
}

fn revenue_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => {
      let idx := match str.to_int(get_env("IDX", "1")) {
        Some(i) => i,
        None => 1,
      }
      let cents := get_env("CENTS", "100")
      let __r := company.record_operate_signal(db, cid, idx, "revenue_cents", str.join(["{\"revenue_cents\": ", cents, "}"], ""))
      io.print(str.join(["[gov3-seed] verified revenue reading recorded: ", cents, "c at iteration ", int.to_str(idx)], ""))
    },
  }
}

fn iter_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => {
      let idx := match str.to_int(get_env("IDX", "2")) {
        Some(i) => i,
        None => 2,
      }
      let __r := company.record_iteration(db, { company_id: cid, idx: idx, sprint_id: str.join([cid, "/iter-", int.to_str(idx)], ""), parent_sprint_id: "", status: "running", goal: "g" })
      let __f := company.finish_iteration(db, cid, idx, "success")
      io.print(str.join(["[gov3-seed] iteration ", int.to_str(idx), " recorded"], ""))
    },
  }
}

fn heartbeat_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => allocation.heartbeat(db, cid, 50),
  }
}

fn allocs_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => {
      let statuses := ["proposed", "applied", "rejected"]
      let __each := list.map(statuses, fn (s :: Str) -> [env, io, sql, fs_read] Unit {
        let __rows := list.map(allocation.load_allocations(db, cid, s), fn (a :: allocation.AllocationRow) -> [io] Unit {
          io.print(str.join([a.status, "|", int.to_str(a.predicted_target_cents), "|", int.to_str(a.predicted_by_iter), "|", a.grade], ""))
        })
        ()
      })
      ()
    },
  }
}

fn hitrate_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "gov3co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov3-seed] FATAL: ", e)),
    Ok(db) => io.print(allocation.hit_rate_line(db, cid)),
  }
}

