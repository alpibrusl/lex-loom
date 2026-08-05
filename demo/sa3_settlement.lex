# demo/sa3_settlement.lex — CLI scaffolding for demo/sa3-settlement-roundtrip.sh
# (SA3, lex-loom#180).
#
# Every real code path here is production code: seed_company_cmd is the only
# demo-only piece (a company row with [soft].settlement on); check_revenue_cmd
# calls the exact same company.check_and_record_revenue every real iteration
# calls, report_cmd calls the exact same company.board_report the real CLI
# does, and reverify_cmd/tamper_cmd exercise soft_settlement's re-derivation
# directly — this demo proves the promotion criterion against real code, not
# a reimplementation of it.

import "std.io" as io

import "std.str" as str

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-soft/src/settlement" as settlement

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/soft_settlement" as soft_settlement

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

# A company with [soft].settlement on — the only demo-only piece; every
# other command below calls real production code.
fn seed_company_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "demo/sa3-settlement-demo.db")
  let company_id := get_env("COMPANY_ID", "sa3-demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[sa3-demo] FATAL: ", e)),
    Ok(db) => match company.save_company(db, { id: company_id, goal: "SA3 settlement demo", model: "none", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "1", policy_isolation: "" }) {
      Err(e) => io.print(str.concat("[sa3-demo] FATAL save_company: ", e)),
      Ok(_) => io.print(str.join(["[sa3-demo] company seeded (soft_settlement=1): ", company_id], "")),
    },
  }
}

# Real production code: reads REVENUE_URL, fetches it, and — since this
# company has [soft].settlement on — records + verifies it through
# soft_settlement before storing.
fn check_revenue_cmd() -> [env, io, sql, fs_read, fs_write, time, proc] Unit {
  let db_path := get_env("DB_PATH", "demo/sa3-settlement-demo.db")
  let company_id := get_env("COMPANY_ID", "sa3-demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[sa3-demo] FATAL: ", e)),
    Ok(db) => match company.check_and_record_revenue(db, company_id, 1) {
      Err(e) => io.print(str.concat("[sa3-demo] check_and_record_revenue reported: ", e)),
      Ok(_) => io.print("[sa3-demo] revenue checked + settled"),
    },
  }
}

fn report_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "demo/sa3-settlement-demo.db")
  let company_id := get_env("COMPANY_ID", "sa3-demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[sa3-demo] FATAL: ", e)),
    Ok(db) => io.print(company.board_report(db, company_id)),
  }
}

# Independent re-verification: opens a FRESH trail handle on the same db and
# re-derives the Verdict from scratch, given only the trail_id printed by
# report_cmd — proves the settlement event survives re-derivation outside
# the original check_revenue_cmd call, not just immediately after writing it.
fn reverify_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "demo/sa3-settlement-demo.db")
  let trail_id := get_env("TRAIL_ID", "")
  if str.is_empty(trail_id) {
    io.print("[sa3-demo] TRAIL_ID is required")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[sa3-demo] FATAL: ", e)),
      Ok(db) => {
        let log := settlement.trail_on(db.handle)
        let v := soft_settlement.verify_revenue_claim(log, trail_id)
        io.print(str.join(["[sa3-demo] independent re-verification of ", trail_id, ": verified=", bool_str(v.verified), " intact=", bool_str(v.intact), " linked=", bool_str(v.linked), " legal=", bool_str(v.legal), " reason=", v.reason], ""))
      },
    }
  }
}

fn bool_str(b :: Bool) -> Str {
  if b {
    "true"
  } else {
    "false"
  }
}

# Mutates the recorded event's payload directly in the db (simulating a
# tamper after the fact) so a subsequent reverify_cmd call demonstrates
# detection — the strongest form of "survives an independent
# re-verification": it doesn't just pass once, it correctly FAILS once the
# underlying trail is no longer honest.
fn tamper_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "demo/sa3-settlement-demo.db")
  let trail_id := get_env("TRAIL_ID", "")
  if str.is_empty(trail_id) {
    io.print("[sa3-demo] TRAIL_ID is required")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[sa3-demo] FATAL: ", e)),
      Ok(db) => match sql.exec(db.handle, str.concat("UPDATE events SET payload_json='{\"revenue_cents\":999999999,\"tampered\":true}' WHERE id='", str.concat(trail_id, "'")), []) {
        Err(e) => io.print(str.concat("[sa3-demo] tamper failed: ", e.message)),
        Ok(_) => io.print(str.concat("[sa3-demo] tampered with event ", trail_id)),
      },
    }
  }
}

