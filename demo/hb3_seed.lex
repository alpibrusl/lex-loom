# demo/hb3_seed.lex — CLI scaffolding for demo/hb3-concurrency-roundtrip.sh.
#
# Commands (DB_PATH via env):
#   seed_cmd         — migrate + seed a docs proc agent whose executor sleeps
#                      briefly (demo/hb3_slow_cat.sh), so two workers visibly
#                      interleave on one sprint's layer.
#   queue_sprint_cmd — build a one-layer Implementation graph of NODES
#                      independent docs nodes (gate "spec non-empty") and run
#                      it with exec_mode "queue": this process only enqueues
#                      and awaits; the separately-launched worker processes
#                      execute every node.
#   seed_company_cmd — a fresh, due-to-run company (COMPANY_ID, WAKE_WHEN
#                      empty, Growth stage) for the multi-company tick.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/orchestrator" as orch

import "../src/cast" as cast

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

fn open_db(db_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("open db failed: ", db_path)),
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

fn seed_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  match open_db(get_env("DB_PATH", "company.db")) {
    Err(e) => io.print(str.concat("[hb3-seed] FATAL: ", e)),
    Ok(db) => {
      let __a := seed_pool_agent(db, "hb3-pool-docs", "docs", "proc:bash demo/hb3_slow_cat.sh")
      io.print("[hb3-seed] pool seeded (docs -> slow proc executor)")
    },
  }
}

fn docs_node(i :: Int) -> { id :: Str, role :: Str, gate :: Str, expand :: Option[Str], activate_when :: Str } {
  { id: str.concat("doc_", int.to_str(i)), role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }
}

fn make_nodes(n :: Int) -> List[{ id :: Str, role :: Str, gate :: Str, expand :: Option[Str], activate_when :: Str }] {
  if n <= 0 {
    []
  } else {
    list.concat(make_nodes(n - 1), [docs_node(n)])
  }
}

fn queue_sprint_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let sid := get_env("SPRINT_ID", "hb3co/iter-1")
  let nodes_n := match str.to_int(get_env("NODES", "6")) {
    Some(n) => n,
    None => 6,
  }
  match open_db(get_env("DB_PATH", "company.db")) {
    Err(e) => io.print(str.concat("[hb3-seed] FATAL: ", e)),
    Ok(db) => {
      let g := { id: sid, phase: Implementation, nodes: make_nodes(nodes_n), edges: [] }
      let trail_none :: Option[tlog.Log] := None
      let cfg := { id: sid, request: "write the docs", model: "proc:cat", db: db, api_calls_max: 50, roster: cast.empty_roster(), trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "queue", policy_isolation: "" }
      let pr := orch.run_phase(g, Implementation, "", [], cfg)
      let ok_n := list.fold(pr.outcomes, 0, fn (n :: Int, o :: orch.NodeOutcome) -> Int {
        if o.attested {
          n + 1
        } else {
          n
        }
      })
      io.print(str.join(["[hb3-seed] queue sprint done: ", int.to_str(ok_n), "/", int.to_str(nodes_n), " nodes attested"], ""))
    },
  }
}

fn seed_company_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "hb3co")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb3-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: company_id, goal: "demo goal", model: "gemma4:latest", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __s := company.save_stage(db, company_id, Growth)
      io.print(str.join(["[hb3-seed] ", company_id, ": Growth, no iterations yet (due to run)"], ""))
    },
  }
}

