# demo/hb1_seed.lex — CLI scaffolding for demo/hb1-scheduler-roundtrip.sh.
#
# Seeds companies into a scheduler workspace using ONLY the real production
# functions (company.save_company / save_stage / record_iteration /
# finish_iteration / add_board_note) — no reimplementation, so what the demo
# proves is what a bootstrapped company actually looks like to the scheduler.
#
# Commands (DB_PATH + COMPANY_ID via env):
#   seed_dormant_cmd — a Maintenance-stage company whose wake_when
#                      ("verdict-failed") is UNMET (last iteration succeeded):
#                      the scheduler must classify it dormant and skip it.
#   wake_cmd         — flip that company's last iteration to "failed" so
#                      wake_when now fires against the grounded ctx: the next
#                      tick must wake it.
#   seed_stopped_cmd — a company whose stop_when ("iter ge 1") already holds
#                      after its one recorded iteration: the scheduler must
#                      never resurrect it on its own.
#   note_cmd         — leave a pending board note on a company (the ONE thing
#                      that overrides a stop for a single iteration).

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

fn base_cfg(company_id :: Str, stop_when :: Str, wake_when :: Str) -> company.CompanyCfg {
  { id: company_id, goal: "demo goal", model: "gemma4:latest", max_iterations: 2, stop_when: stop_when, pmf_when: "", maintenance_when: "", wake_when: wake_when, soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_one_iteration(db :: conn.ConnDb, company_id :: Str, status :: Str) -> [sql, fs_write, time, io] Unit {
  let __it := company.record_iteration(db, { company_id: company_id, idx: 1, sprint_id: str.concat(company_id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "demo goal" })
  let __fin := company.finish_iteration(db, company_id, 1, status)
  ()
}

fn seed_dormant_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "wakeco")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb1-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := company.save_company(db, base_cfg(company_id, "", "verdict-failed"))
      let __s := company.save_stage(db, company_id, Maintenance)
      let __i := seed_one_iteration(db, company_id, "success")
      io.print(str.join(["[hb1-seed] ", company_id, ": Maintenance, wake_when=verdict-failed, last iteration=success (dormant)"], ""))
    },
  }
}

fn wake_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "wakeco")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb1-seed] FATAL: ", e)),
    Ok(db) => {
      let __f := company.finish_iteration(db, company_id, 1, "failed")
      io.print(str.join(["[hb1-seed] ", company_id, ": last iteration flipped to failed — wake_when now fires"], ""))
    },
  }
}

fn seed_stopped_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "stopco")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb1-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := company.save_company(db, base_cfg(company_id, "iter ge 1", ""))
      let __s := company.save_stage(db, company_id, Growth)
      let __i := seed_one_iteration(db, company_id, "success")
      io.print(str.join(["[hb1-seed] ", company_id, ": Growth, stop_when=iter ge 1 already holds (stopped)"], ""))
    },
  }
}

fn note_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "company.db")
  let company_id := get_env("COMPANY_ID", "stopco")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[hb1-seed] FATAL: ", e)),
    Ok(db) => {
      let __n := company.add_board_note(db, company_id, "board: one more iteration please")
      io.print(str.join(["[hb1-seed] ", company_id, ": pending board note left"], ""))
    },
  }
}

