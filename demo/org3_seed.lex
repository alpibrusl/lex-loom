# demo/org3_seed.lex — CLI scaffolding for demo/org3-manager-review-roundtrip.sh.
#
# Drives ORG3 manager review through ONLY the real production functions
# (delegation.offer, company_runner.drain_assignments,
# manager.review_assignments / record_reports / reports_section,
# company_runner.strategist_prompt) — no reimplementation.
#
# Commands (env-driven, DB_PATH + COMPANY_ID always):
#   seed_cmd   — migrate, save the org chart, seed the pool: docs -> `cat`
#                (the worker), eng_manager -> MGR_MODEL (the reviewer; the
#                demo passes demo/org3_reviewer.sh, which returns a first
#                attempt and accepts a rework).
#   offer_cmd  — one delegation.offer(FROM_ROLE, TO_ROLE, KIND, GOAL).
#   cycle_cmd  — one management pass, exactly as run_iterations does it:
#                drain (work happens) -> review (judgment) -> file reports.
#   status_cmd — "status|kind|to_role|rework|artifact|reason" per assignment.
#   pool_cmd   — "id|attestations|bounces|retired" for AGENT_ID.
#   report_cmd — the manager reports section the Strategist consumes.
#   prompt_cmd — a full strategist prompt built with that section, to prove
#                the summary (not raw artifacts) is what flows up.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/org" as org

import "../src/delegation" as delegation

import "../src/manager" as manager

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

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, model_name :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(id), PStr(role), PStr(model_name)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => match org.parse_org_spec(get_env("ORG_EDGES", "docs:eng_manager,eng_manager:founder")) {
      Err(e) => io.print(str.concat("[org3-seed] FATAL: bad org spec: ", e)),
      Ok(edges) => match org.save_org(db, cid, edges) {
        Err(e) => io.print(str.concat("[org3-seed] FATAL: save_org: ", e)),
        Ok(_) => {
          let __a := seed_pool_agent(db, "org3-pool-docs", "docs", "proc:cat")
          let __b := seed_pool_agent(db, "org3-pool-mgr", "eng_manager", get_env("MGR_MODEL", "proc:bash demo/org3_reviewer.sh"))
          io.print(str.join(["[org3-seed] ", cid, ": org saved (", org.org_chart(edges), "); pool: docs worker + eng_manager reviewer"], ""))
        },
      },
    },
  }
}

fn offer_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => match delegation.offer(db, cid, get_env("FROM_ROLE", "eng_manager"), get_env("TO_ROLE", "docs"), get_env("KIND", "write_docs"), get_env("GOAL", "")) {
      Ok(id) => io.print(str.concat("[org3-seed] offer ok: ", id)),
      Err(m) => io.print(str.concat("[org3-seed] offer refused: ", m)),
    },
  }
}

fn cycle_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => {
      let ccfg := mk_ccfg(cid)
      let sprint := get_env("SPRINT_ID", str.concat(cid, "/mgmt-demo"))
      let __d := company_runner.drain_assignments(db, ccfg, sprint, 50)
      let n := manager.review_assignments(db, ccfg, sprint, 50)
      let __rep := manager.record_reports(db, cid)
      io.print(str.join(["[org3-seed] cycle complete: ", int.to_str(n), " review(s) conducted"], ""))
    },
  }
}

fn status_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => {
      let all := list.fold(["offered", "rework", "done", "approved", "returned"], [], fn (acc :: List[delegation.Assignment], s :: Str) -> [sql, fs_read] List[delegation.Assignment] {
        list.concat(acc, delegation.load_by_status(db, cid, s))
      })
      let __each := list.map(all, fn (a :: delegation.Assignment) -> [io] Unit {
        io.print(str.join([a.status, "|", a.kind, "|", a.to_role, "|", int.to_str(a.rework_count), "|", a.artifact_ref, "|", a.reason], ""))
      })
      ()
    },
  }
}

type PoolStateRow = { attestation_count :: Int, bounce_count :: Int, retired_at :: Str }

fn pool_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let agent_id := get_env("AGENT_ID", "org3-pool-docs")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => {
      let q := ormq.for_dialect({ sql: "SELECT attestation_count, bounce_count, retired_at FROM agent_pool WHERE id=?", params: [PStr(agent_id)] }, db.dialect)
      let rows :: Result[List[PoolStateRow], SqlError] := sql.query(db.handle, q.sql, q.params)
      match rows {
        Err(_) => io.print("[org3-seed] pool query failed"),
        Ok(rs) => match list.head(rs) {
          None => io.print("[org3-seed] no such pool agent"),
          Some(p) => io.print(str.join([agent_id, "|", int.to_str(p.attestation_count), "|", int.to_str(p.bounce_count), "|", p.retired_at], "")),
        },
      }
    },
  }
}

fn report_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => io.print(manager.reports_section(db, cid)),
  }
}

fn prompt_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org3co")
  match open_db() {
    Err(e) => io.print(str.concat("[org3-seed] FATAL: ", e)),
    Ok(db) => {
      let section := manager.reports_section(db, cid)
      let ctx := { idx: 1, last_verdict: "accepted", digest_summary: "(demo)", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
      io.print(company_runner.strategist_prompt("demo mission", "(shipped)", [], "(operate)", "(product)", "(economics)", "(distribution)", "(build status)", section, "demo goal", ctx))
    },
  }
}

