# test_dump_config.lex — #247: effective configuration with provenance.
#
# The property under test is the sharing rule: the dump's values come from
# the SAME resolution functions the runtime uses, and every line names the
# layer that decided it. Verified against a company with an isolation
# override and a spend envelope; the model line must be the company row's
# value (the layer that actually wins for company runs).

import "std.crypto" as crypto

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "lex-orm/src/connection" as conn

import "../src/budget" as budget

import "../src/company" as company

import "../src/defaults" as defaults

import "../src/dump_config" as dump_config

import "../src/migrate" as migrate

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_company(db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] company.CompanyCfg {
  let cfg :: company.CompanyCfg := { id: "dumpco", goal: "ship the widget", model: "proc:cat", max_iterations: 3, stop_when: "spend ge 500", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "qa:Demo" }
  let __c := company.save_company(db, cfg)
  let __e := budget.set_envelope(db, "dumpco", "role:docs", 100, "founder")
  cfg
}

fn test_dump_names_deciding_layers() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let __cfg := seed_company(db)
      match dump_config.dump(db, "dumpco") {
        Err(e) => Err(e),
        Ok(text) => {
          let model_row := str.contains(text, "model = proc:cat    # company row")
          let qa_override := str.contains(text, "isolation.qa = Demo    # [policy.isolation] override")
          let build_default := str.contains(text, "isolation.build = Implementation    # kind default")
          let envelope := str.contains(text, "budget.role:docs = cap 100c, spent 0c    # company DB (set_envelope)")
          let stop := str.contains(text, "stop_when = spend ge 500    # company row")
          check(str.concat("dump names deciding layers; got:\n", text), model_row and qa_override and build_default and envelope and stop)
        },
      }
    },
  }
}

# The sharing rule made concrete: the dump's exec_mode/model values are the
# very functions the runtime calls, so they cannot disagree with a run.
fn test_dump_matches_runtime_resolution() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let __cfg := seed_company(db)
      match dump_config.dump(db, "dumpco") {
        Err(e) => Err(e),
        Ok(text) => {
          let exec_line := str.join(["exec_mode = ", defaults.resolved_exec_mode()], "")
          check("dump exec_mode equals defaults.resolved_exec_mode()", str.contains(text, exec_line))
        },
      }
    },
  }
}

fn test_unknown_company_refused() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match dump_config.dump(db, "ghost") {
      Ok(_) => Err("unknown company must be an error, not an empty dump"),
      Err(e) => check(str.concat("refusal names the company: ", e), str.contains(e, "ghost")),
    },
  }
}

fn suite() -> [env, io, sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_dump_names_deciding_layers(), test_dump_matches_runtime_resolution(), test_unknown_company_refused()]
}

fn run_all() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

