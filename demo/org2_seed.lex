# demo/org2_seed.lex — CLI scaffolding for demo/org2-delegation-roundtrip.sh.
#
# Drives ORG2 delegation through ONLY the real production functions
# (org.save_org, delegation.offer / delegate_tool / flush_delegations,
# company_runner.drain_assignments) — no reimplementation, so what the demo
# proves is what the running system actually does.
#
# Commands (env-driven, DB_PATH + COMPANY_ID always):
#   seed_cmd       — migrate, save the ORG_EDGES org chart, seed proc-executor
#                    pool agents: docs -> `cat` (echoes its prompt: succeeds),
#                    qa -> `true` (produces nothing: fails its gate).
#   offer_cmd      — one delegation.offer(FROM_ROLE, TO_ROLE, KIND, GOAL);
#                    prints ok/refused exactly as the gate decides.
#   tool_flush_cmd — the real delegate tool appends one org-authorized and one
#                    unauthorized request to its per-run file, then
#                    flush_delegations replays them through the gate.
#   drain_cmd      — company_runner.drain_assignments: offered assignments run
#                    as ordinary sprint nodes (SPRINT_ID) with cast/gates/trail.
#   status_cmd     — print every assignment as "status|kind|to_role|artifact|reason".

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "../src/migrate" as migrate

import "../src/org" as org

import "../src/delegation" as delegation

import "../src/company" as company

import "../src/company_runner" as company_runner

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

fn seed_pool_agent(db :: conn.ConnDb, role :: Str, model_name :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(str.concat("org2-pool-", role)), PStr(role), PStr(model_name)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random] Unit {
  let cid := get_env("COMPANY_ID", "org2co")
  match open_db() {
    Err(e) => io.print(str.concat("[org2-seed] FATAL: ", e)),
    Ok(db) => match org.parse_org_spec(get_env("ORG_EDGES", "docs:eng_manager,qa:eng_manager,eng_manager:founder")) {
      Err(e) => io.print(str.concat("[org2-seed] FATAL: bad org spec: ", e)),
      Ok(edges) => match org.save_org(db, cid, edges) {
        Err(e) => io.print(str.concat("[org2-seed] FATAL: save_org: ", e)),
        Ok(_) => {
          let __a := seed_pool_agent(db, "docs", "proc:cat")
          let __b := seed_pool_agent(db, "qa", "proc:true")
          io.print(str.join(["[org2-seed] ", cid, ": org saved (", org.org_chart(edges), "); pool: docs=proc:cat, qa=proc:true"], ""))
        },
      },
    },
  }
}

fn offer_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "org2co")
  match open_db() {
    Err(e) => io.print(str.concat("[org2-seed] FATAL: ", e)),
    Ok(db) => match delegation.offer(db, cid, get_env("FROM_ROLE", "eng_manager"), get_env("TO_ROLE", "docs"), get_env("KIND", "write_docs"), get_env("GOAL", "")) {
      Ok(id) => io.print(str.concat("[org2-seed] offer ok: ", id)),
      Err(m) => io.print(str.concat("[org2-seed] offer refused: ", m)),
    },
  }
}

fn tool_flush_cmd() -> [env, io, net, proc, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "org2co")
  match open_db() {
    Err(e) => io.print(str.concat("[org2-seed] FATAL: ", e)),
    Ok(db) => {
      let path := delegation.delegations_file(str.concat(cid, "-tooldemo"))
      let tool := delegation.delegate_tool(path)
      let exec := tool.execute
      let __c1 := exec(JObj([("to_role", JStr("docs")), ("kind", JStr("write_docs")), ("goal", JStr("write the launch changelog"))]))
      let __c2 := exec(JObj([("to_role", JStr("founder")), ("kind", JStr("write_docs")), ("goal", JStr("try to delegate upward"))]))
      let n := delegation.flush_delegations(db, cid, get_env("FROM_ROLE", "eng_manager"), path)
      io.print(str.join(["[org2-seed] tool emitted 2 requests; ", int.to_str(n), " authorized by the org chart"], ""))
    },
  }
}

fn drain_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "org2co")
  match open_db() {
    Err(e) => io.print(str.concat("[org2-seed] FATAL: ", e)),
    Ok(db) => {
      let ccfg :: company.CompanyCfg := { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      company_runner.drain_assignments(db, ccfg, get_env("SPRINT_ID", str.concat(cid, "/assign-demo")), 50)
    },
  }
}

fn status_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org2co")
  match open_db() {
    Err(e) => io.print(str.concat("[org2-seed] FATAL: ", e)),
    Ok(db) => {
      let all := list.concat(delegation.load_by_status(db, cid, "offered"), list.concat(delegation.load_by_status(db, cid, "done"), delegation.load_by_status(db, cid, "returned")))
      let __each := list.map(all, fn (a :: delegation.Assignment) -> [io] Unit {
        io.print(str.join([a.status, "|", a.kind, "|", a.to_role, "|", a.artifact_ref, "|", a.reason], ""))
      })
      ()
    },
  }
}

