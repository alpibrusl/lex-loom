# demo/org1_seed.lex — CLI scaffolding for demo/org1-org-roundtrip.sh.
#
# seed_parked_cmd: a company with (a) reporting lines saved through the real
# org.parse_org_spec/save_org path and (b) a parked iteration whose blocking
# gate ("human legal blocking 1h") already has a pending attention item —
# the shape the scheduler's ORG1 escalation walks. The demo script backdates
# the item so the 1h timeout has genuinely elapsed.

import "std.str" as str

import "std.io" as io

import "std.env" as env

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/org" as org

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

fn seed_parked_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "orgco")
  let org_spec := get_env("ORG_EDGES", "legal:eng_manager,eng_manager:founder")
  match conn.open(db_path) {
    Err(_) => io.print("[org1-seed] FATAL: open db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => io.print(str.concat("[org1-seed] FATAL: ", e)),
      Ok(_) => match org.parse_org_spec(org_spec) {
        Err(m) => io.print(str.concat("[org1-seed] FATAL: ", m)),
        Ok(edges) => {
          let __o := org.save_org(db, company_id, edges)
          let cfg := { id: company_id, goal: "demo goal", model: "gemma4:latest", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
          let __c := company.save_company(db, cfg)
          let sprint_id := company.iteration_sprint_id(company_id, 1)
          let __it := company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: sprint_id, parent_sprint_id: "", status: "running", goal: "demo goal" })
          let __fin := company.finish_iteration(db, company_id, 1, "parked")
          let __at := tr.push_attention(db, sprint_id, "legal_review", "human legal blocking 1h", "legal", "demo-artifact")
          io.print(str.join(["[org1-seed] ", company_id, ": org saved, iteration 1 parked on a 'human legal blocking 1h' gate"], ""))
        },
      },
    },
  }
}

