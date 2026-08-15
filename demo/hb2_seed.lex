# demo/hb2_seed.lex — CLI scaffolding for demo/hb2-event-wake-roundtrip.sh.
#
# Seeds dormant companies using ONLY the real production functions, exactly
# like hb1_seed.lex — the only HB2-specific knob is each company's wake_when:
#
#   seed_dormant_cmd — a Maintenance-stage company with a successful last
#                      iteration and WAKE_WHEN from env: dormant until an
#                      event of a declared kind arrives (or never, if its
#                      wake_when declares no event kinds).
#
# DB_PATH + COMPANY_ID + WAKE_WHEN via env.

import "std.io" as io

import "std.str" as str

import "std.env" as env

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

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

fn open_db(db_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("open db failed: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_dormant_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "wakeco")
  let wake_when := get_env("WAKE_WHEN", "board_note")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb2-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: company_id, goal: "demo goal", model: "gemma4:latest", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: wake_when, soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let __s := company.save_stage(db, company_id, Maintenance)
      let __it := company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: str.concat(company_id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "demo goal" })
      let __fin := company.finish_iteration(db, company_id, 1, "success")
      io.print(str.join(["[hb2-seed] ", company_id, ": Maintenance, wake_when=", wake_when, ", last iteration=success (dormant)"], ""))
    },
  }
}

