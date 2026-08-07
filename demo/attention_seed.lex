# demo/attention_seed.lex — CLI scaffolding for demo/attention-governance-roundtrip.sh.
#
# seed_cmd calls the exact real production function
# src/transport.lex::push_attention with a company.lex::save_company'd
# company first (attention_resolve_cmd_run's authorization check needs a
# real company row to resolve company_id -> registered contacts against) —
# no reimplementation, this is the same push path a real `human <oracle>`
# gate node uses.

import "std.io" as io

import "std.str" as str

import "std.env" as env

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/transport" as tr

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

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := get_env("DB_PATH", "demo/attention-governance-demo.db")
  let company_id := get_env("COMPANY_ID", "acme-gov")
  let oracle := get_env("ORACLE", "founder")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[attention-demo] FATAL: ", e)),
    Ok(db) => match company.save_company(db, { id: company_id, goal: "sell the product", model: "m", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
      Err(e) => io.print(str.concat("[attention-demo] FATAL save_company: ", e)),
      Ok(_) => match tr.push_attention(db, str.join([company_id, "/iter-1"], ""), "monetization_handoff", "human founder", oracle, "hash-demo-1") {
        Err(e) => io.print(str.concat("[attention-demo] FATAL push_attention: ", e)),
        Ok(id) => io.print(str.join(["[attention-demo] pushed id=", id, " company=", company_id, " oracle=", oracle], "")),
      },
    },
  }
}

