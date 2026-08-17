# test_support_scope.lex — #194: the CX A2A fetch is bound to the company's
# OWN registered URL.
#
# The properties under test: (1) resolution precedence — an operator pin
# wins, else the company DB's registered Launch/Deploy URL, else a refusal
# (never an unscoped fetch); (2) the registry is the SAME state the operate
# loop's liveness checks trust (a launch node's {ok:true,url} artifact),
# with the newest registered URL winning and deploy preferred over launch;
# (3) the scope decision itself — omitted url means "the registered one",
# a mismatch is refused, an empty allowlist matches nothing.

import "std.crypto" as crypto

import "std.io" as io

import "std.list" as list

import "std.sql" as sql

import "std.str" as str

import "lex-orm/src/connection" as conn

import "../src/company" as company

import "../src/migrate" as migrate

import "../src/support_scope" as scope

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn fresh_db_path() -> [random, crypto] Str {
  str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")
}

fn open_db_at(path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(path) {
    Err(_) => Err("open failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn exec(db :: conn.ConnDb, s :: Str) -> [sql, fs_write] Unit {
  let __r := sql.exec(db.handle, s, [])
  ()
}

fn seed_iteration(db :: conn.ConnDb, company_id :: Str, idx :: Int) -> [sql, fs_write, time] Unit {
  let sprint_id := company.iteration_sprint_id(company_id, idx)
  let __r := company.record_iteration(db, { company_id: company_id, idx: idx, sprint_id: sprint_id, parent_sprint_id: "", status: "success", goal: "g" })
  ()
}

fn seed_node_artifact(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, fs_write] Unit {
  exec(db, str.join(["INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('h-", node_id, "-", sprint_id, "', '", sprint_id, "', '", node_id, "', '", content, "', 't1')"], ""))
}

# Precedence 1: an operator pin resolves without touching any DB.
fn test_override_wins_without_db() -> [sql, fs_read, fs_write, io] Result[Unit, Str] {
  match scope.resolve_allowed("http://pinned:9999/", "", "") {
    Err(e) => Err(str.concat("override should resolve: ", e)),
    Ok(u) => check("override is used and normalized", u == "http://pinned:9999"),
  }
}

# Precedence 3: nothing configured is an error naming the fix, never an
# unscoped fetch.
fn test_unconfigured_refuses() -> [sql, fs_read, fs_write, io] Result[Unit, Str] {
  match scope.resolve_allowed("", "", "") {
    Ok(_) => Err("no scope source configured must refuse, not fail open"),
    Err(e) => check(str.concat("refusal names the env vars: ", e), str.contains(e, "CX_ALLOWED_URL") and str.contains(e, "LOOM_EVENTS_DB")),
  }
}

# Precedence 2: the registered URL comes from the same launch-node
# artifact the liveness checks trust, and the NEWEST iteration with one
# wins over an older registration.
fn test_derives_newest_registered_url() -> [sql, io, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_db_at(path) {
    Err(e) => Err(e),
    Ok(db) => {
      let __i1 := seed_iteration(db, "scopeco", 1)
      let __i2 := seed_iteration(db, "scopeco", 2)
      let __a1 := seed_node_artifact(db, company.iteration_sprint_id("scopeco", 1), "launch-1", "{\"ok\":true,\"url\":\"http://127.0.0.1:8081\"}")
      let __a2 := seed_node_artifact(db, company.iteration_sprint_id("scopeco", 2), "launch-1", "{\"ok\":true,\"url\":\"http://127.0.0.1:8082/\"}")
      match scope.resolve_allowed("", path, "scopeco") {
        Err(e) => Err(str.concat("registered URL should resolve: ", e)),
        Ok(u) => check(str.concat("newest registration wins, normalized; got ", u), u == "http://127.0.0.1:8082"),
      }
    },
  }
}

# A company that never launched/deployed has no scope — refused, with the
# reason naming what has to happen first.
fn test_no_registered_url_refuses() -> [sql, io, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  let path := fresh_db_path()
  match open_db_at(path) {
    Err(e) => Err(e),
    Ok(db) => {
      let __i1 := seed_iteration(db, "bareco", 1)
      match scope.resolve_allowed("", path, "bareco") {
        Ok(u) => Err(str.concat("company with no registered URL must be refused, got ", u)),
        Err(e) => check(str.concat("refusal names the company and the cause: ", e), str.contains(e, "bareco") and str.contains(e, "Launch or Deploy")),
      }
    },
  }
}

# The scope decision: omitted url = the registered one; equal-after-
# normalization passes; anything else refused; empty allowlist matches
# nothing (the examples{} blocks pin the same properties — this test keeps
# them honest against a refactor that swaps the fn out).
fn test_scope_decision() -> Result[Unit, Str] {
  let omitted := scope.url_in_scope("", "http://127.0.0.1:8081")
  let exact := scope.url_in_scope("http://127.0.0.1:8081/", "http://127.0.0.1:8081")
  let other_host := scope.url_in_scope("http://internal-db:5432", "http://127.0.0.1:8081") == false
  let other_port := scope.url_in_scope("http://127.0.0.1:8082", "http://127.0.0.1:8081") == false
  let empty_allow := scope.url_in_scope("", "") == false
  check("omitted/exact in scope; other host/port and empty allowlist refused", omitted and exact and other_host and other_port and empty_allow)
}

fn suite() -> [sql, io, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_override_wins_without_db(), test_unconfigured_refuses(), test_derives_newest_registered_url(), test_no_registered_url_refuses(), test_scope_decision()]
}

fn run_all() -> [sql, io, fs_read, fs_write, time, random, crypto] Unit {
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

