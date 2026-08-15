# demo/cost_seed.lex — CLI scaffolding for demo/real-cost-roundtrip.sh (#94).
#
# Commands (DB_PATH via env):
#   seed_cmd    — company COMPANY_ID + docs proc pool agent + a one-node docs
#                 sprint graph saved for SPRINT_ID + spend envelopes
#                 (role:docs + total, CAP_CENTS each).
#   exhaust_cmd — burn the docs envelope to its cap via the real
#                 budget.charge, so the next dispatch must refuse.
#   enqueue_cmd — enqueue the node as a real lex-jobs node-job (the exact
#                 payload the queue-mode orchestrator produces).
#   usage_cmd   — record three llm_usage readings under SPRINT_ID exactly as
#                 runner.step would (haiku + sonnet + a free local model).
#   ledger_cmd  — record an iteration and its cost via the REAL
#                 company.record_iteration_cost, then print the total.
#   report_cmd  — print the board report (spend line basis check).

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.sql" as sql

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/budget" as budget

import "../src/graph" as graph

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

fn docs_graph(sprint_id :: Str) -> graph.SprintGraph {
  { id: sprint_id, phase: Implementation, nodes: [{ id: "write_docs", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "costco")
  let sid := get_env("SPRINT_ID", str.concat(cid, "/iter-1"))
  let cap := match str.to_int(get_env("CAP_CENTS", "100")) {
    Some(n) => n,
    None => 100,
  }
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: cid, goal: "write great docs", model: "proc:cat", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __a := seed_pool_agent(db, str.concat(cid, "-pool-docs"), "docs", "proc:cat")
      let __g := tr.save_sprint_graph(db, sid, "Implementation", graph.to_json_str(docs_graph(sid)))
      let __e1 := budget.set_envelope(db, cid, "role:docs", cap, "founder")
      let __e2 := budget.set_envelope(db, cid, "total", cap * 10, "founder")
      io.print(str.join(["[cost-seed] ", cid, ": company + docs pool agent + graph for ", sid, " + envelopes (role:docs cap ", int.to_str(cap), "c)"], ""))
    },
  }
}

fn exhaust_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "costco")
  let cap := match str.to_int(get_env("CAP_CENTS", "100")) {
    Some(n) => n,
    None => 100,
  }
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := budget.charge(db, cid, "docs", cap)
      io.print(str.join(["[cost-seed] ", cid, ": docs envelope charged to its cap — next dispatch must refuse"], ""))
    },
  }
}

fn enqueue_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "costco")
  let sid := get_env("SPRINT_ID", str.concat(cid, "/iter-1"))
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => match tr.enqueue_node(db, sid, "write_docs", "Implementation", "", "proc:cat", str.join(["Write the full user documentation for the widget analytics API: ", "an overview of every endpoint, request and response examples for each, ", "authentication setup with token rotation guidance, rate-limit behavior ", "and retry advice, a quickstart that goes from zero to a first successful ", "call, and a troubleshooting section covering the ten most common errors ", "with their causes and fixes. Keep the tone direct and the examples runnable."], ""), 10) {
      Err(e) => io.print(str.concat("[cost-seed] FATAL enqueue: ", e)),
      Ok(_) => io.print(str.join(["[cost-seed] node-job enqueued for ", sid, "/write_docs"], "")),
    },
  }
}

fn seed_usage(db :: conn.ConnDb, owner :: Str, model :: Str, p :: Int, c :: Int, t :: Int) -> [sql, fs_write, time] Unit {
  let json := str.join(["{\"model\":\"", model, "\",\"prompt_tokens\":", int.to_str(p), ",\"completion_tokens\":", int.to_str(c), ",\"total_tokens\":", int.to_str(t), "}"], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', ?, 'llm_usage', ?, ?)", params: [PStr(owner), PStr(json), PStr(time.now_str())] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

fn usage_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "ledgerco")
  let sid := get_env("SPRINT_ID", str.concat(cid, "/iter-1"))
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => {
      let __u1 := seed_usage(db, str.concat(sid, "#pm"), "claude-haiku-4-5-20251001", 10000, 2000, 12000)
      let __u2 := seed_usage(db, str.concat(sid, "#build"), "claude-sonnet-5", 10000, 2000, 12000)
      let __u3 := seed_usage(db, str.concat(sid, "#qa"), "qwen3-coder:30b", 50000, 5000, 55000)
      io.print(str.join(["[cost-seed] ", sid, ": 3 real usage readings recorded (haiku 2c + sonnet 6c + local 0c)"], ""))
    },
  }
}

fn ledger_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "ledgerco")
  let sid := get_env("SPRINT_ID", str.concat(cid, "/iter-1"))
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => {
      let __it := company.record_iteration(db, { company_id: cid, idx: 1, sprint_id: sid, parent_sprint_id: "", status: "running", goal: "g" })
      let __fin := company.finish_iteration(db, cid, 1, "success")
      match company.record_iteration_cost(db, cid, sid) {
        Err(e) => io.print(str.concat("[cost-seed] FATAL cost: ", e)),
        Ok(total) => io.print(str.join(["[cost-seed] ", cid, ": iteration cost recorded — total_cost_cents=", int.to_str(total)], "")),
      }
    },
  }
}

fn report_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto, vcs, proc] Unit {
  let cid := get_env("COMPANY_ID", "ledgerco")
  match open_db() {
    Err(e) => io.print(str.concat("[cost-seed] FATAL: ", e)),
    Ok(db) => io.print(company.board_report(db, cid)),
  }
}

