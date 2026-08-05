# demo/oa1_grant_report.lex — CLI scaffolding for demo/oa1-grant-report-roundtrip.sh
# (OA1, lex-loom#182).
#
# seed_company_cmd + seed_iteration_cmd are the only demo-only pieces (a
# company row with [policy].isolation set + one iteration with a seeded
# sprint graph) — the actual promotion criterion is proven by calling
# src/main.lex's real roster_grant_report_cmd, the same production CLI
# entrypoint an operator would run, not a reimplementation of it.

import "std.io" as io

import "std.str" as str

import "std.env" as env

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/digest" as dg

import "../src/graph" as graph

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

# A company with [policy].isolation set on the "build" role kind only —
# leaves "qa" to fall back to manifests.lex's own default (QA).
fn seed_company_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "demo/oa1-grant-report-demo.db")
  let company_id := get_env("COMPANY_ID", "oa1-demo")
  let policy_isolation := get_env("POLICY_ISOLATION", "build:Demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[oa1-demo] FATAL: ", e)),
    Ok(db) => match company.save_company(db, { id: company_id, goal: "OA1 grant report demo", model: "none", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: policy_isolation }) {
      Err(e) => io.print(str.concat("[oa1-demo] FATAL save_company: ", e)),
      Ok(_) => io.print(str.join(["[oa1-demo] company seeded (policy.isolation='", policy_isolation, "'): ", company_id], "")),
    },
  }
}

fn demo_node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec non-empty", expand: None, activate_when: "" }
}

# One iteration + its seed graph — three roles: "build" (overridden below to
# Demo), "qa" (not overridden, keeps its own default QA), and "docs" (an
# unmapped kind, keeps the universal safe fallback Demo).
fn seed_iteration_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := get_env("DB_PATH", "demo/oa1-grant-report-demo.db")
  let company_id := get_env("COMPANY_ID", "oa1-demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[oa1-demo] FATAL: ", e)),
    Ok(db) => {
      let sprint_id := company.iteration_sprint_id(company_id, 1)
      match company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "running", goal: "OA1 grant report demo" }) {
        Err(e) => io.print(str.concat("[oa1-demo] FATAL record_iteration: ", e)),
        Ok(_) => {
          let g := { id: sprint_id, phase: graph.Intake, nodes: [demo_node("n-build", "build"), demo_node("n-qa", "qa"), demo_node("n-docs", "docs")], edges: [] }
          match dg.save_digest(db, { sprint_id: sprint_id, next_sprint_id: "", summary: "oa1 demo seed", lessons: "", tightened_specs: [], seed_graph: g }) {
            Err(e) => io.print(str.concat("[oa1-demo] FATAL save_digest: ", e)),
            Ok(_) => io.print(str.join(["[oa1-demo] iteration 1 (", sprint_id, ") seeded with 3 nodes: build, qa, docs"], "")),
          }
        },
      }
    },
  }
}

