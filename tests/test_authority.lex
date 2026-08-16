# test_authority.lex — #248: delegated authority stamped onto the node trail.
#
# The property: a node_authority event captures the envelope state and the
# resolved isolation preset AS OF DISPATCH, so the trail alone answers
# "under what authority did this node run" even after the company DB moves
# on. Verified by mutating the envelope AFTER the stamp and checking the
# trail still holds the dispatch-time values.

import "std.crypto" as crypto

import "std.io" as io

import "std.list" as list

import "std.str" as str

import "lex-orm/src/connection" as conn

import "../src/authority" as authority

import "../src/budget" as budget

import "../src/migrate" as migrate

import "../src/transport" as tr

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

fn test_stamp_survives_later_mutation() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := "authco"
      let sid := "authco/iter-1"
      let __e := budget.set_envelope(db, cid, "role:docs", 100, "founder")
      let __a := authority.record_node_authority(db, cid, sid, "write_docs", "docs", "proc:cat", 10, "", "worker-1")
      let __c := budget.charge(db, cid, "docs", 40)
      let stamped_zero := tr.trail_contains(db, sid, "node_authority", "\"role_envelope\":{\"cap_cents\":100,\"spent_cents\":0}")
      let live_now := match budget.envelope_for(db, cid, "role:docs") {
        None => false,
        Some(env) => env.spent_cents == 40,
      }
      check("trail holds dispatch-time envelope while live state moved on", stamped_zero and live_now)
    },
  }
}

fn test_stamp_resolves_isolation_override() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := "authco2"
      let sid := "authco2/iter-1"
      let __a1 := authority.record_node_authority(db, cid, sid, "check_docs", "qa", "proc:cat", 10, "qa:Demo", "inline")
      let __a2 := authority.record_node_authority(db, cid, sid, "build_it", "build", "proc:cat", 10, "qa:Demo", "inline")
      let qa_demo := tr.trail_contains(db, sid, "node_authority", "\"node\":\"check_docs\",\"role\":\"qa\",\"preset\":\"Demo\"")
      let build_default := tr.trail_contains(db, sid, "node_authority", "\"node\":\"build_it\",\"role\":\"build\",\"preset\":\"Implementation\"")
      check("override resolved for qa, default kept for build", qa_demo and build_default)
    },
  }
}

fn test_missing_envelopes_stamp_null() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let sid := "authco3/iter-1"
      let __a := authority.record_node_authority(db, "authco3", sid, "n1", "docs", "proc:cat", 5, "", "inline")
      check("absent envelopes recorded as null, not invented", tr.trail_contains(db, sid, "node_authority", "\"role_envelope\":null,\"total_envelope\":null"))
    },
  }
}

fn suite() -> [io, sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_stamp_survives_later_mutation(), test_stamp_resolves_isolation_override(), test_missing_envelopes_stamp_null()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
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

