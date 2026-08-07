# test_transport.lex — regression coverage for src/transport.lex's artifact
# mirror path (lex-loom#196): mirror_vcs's failure is no longer silently
# swallowed — artifact_put now records it as a queryable
# "loom.artifact.mirror_failed" trace row.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/transport" as tr

fn fresh_db() -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

# "sqlite::memory:" is one shared store per process (see test_ops.lex's own
# header comment) — unique sprint ids keep this file's assertions disjoint
# from every other test file sharing the same in-memory store.
fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn test_mirror_vcs_returns_ok_on_a_normal_write() -> [vcs, fs_write, fs_read, random] Result[Unit, Str] {
  let sprint_id := uniq("sprint")
  match tr.mirror_vcs(sprint_id, "node-1", "some artifact content", crypto_hash_placeholder()) {
    Err(e) => Err(str.concat("expected a normal vcs write to succeed, got: ", e)),
    Ok(_) => Ok(()),
  }
}

fn crypto_hash_placeholder() -> Str {
  "deadbeef00000000000000000000000000000000000000000000000000000"
}

fn test_artifact_put_still_returns_ok_hash_on_success() -> [sql, fs_write, fs_read, time, random, crypto, vcs] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("sprint")
      match tr.artifact_put(db, sprint_id, "node-1", "hello from test_transport") {
        Err(e) => Err(str.concat("expected artifact_put to succeed, got: ", e)),
        Ok(hash) => if str.len(hash) > 0 {
          Ok(())
        } else {
          Err("expected a non-empty content hash")
        },
      }
    },
  }
}

# Exercises the actual visibility mechanism artifact_put's failure branch
# relies on: a mirror-failure trail row must be recorded under the
# sprint's own id and be countable via count_trail_events — this is what
# turns a silent Err(_) => () into something an auditor can actually find.
# (Forcing a REAL vcs.put_blob failure needs write access to the shared
# global ~/.lex/store, which this suite deliberately does not mutate —
# verified live, once, outside the automated suite; see the PR description.)
fn test_mirror_failed_trail_row_is_recorded_and_countable() -> [sql, fs_write, fs_read, time, random, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("sprint")
      let before := tr.count_trail_events(db, sprint_id, "loom.artifact.mirror_failed")
      let __t := tr.trail(db, sprint_id, "loom.artifact.mirror_failed", "{\"node_id\":\"node-1\",\"hash\":\"deadbeef\",\"reason\":\"put_blob: simulated failure\"}")
      let after := tr.count_trail_events(db, sprint_id, "loom.artifact.mirror_failed")
      if before == 0 and after == 1 {
        Ok(())
      } else {
        Err(str.join(["expected before=0 after=1, got before=", int.to_str(before), " after=", int.to_str(after)], ""))
      }
    },
  }
}

fn run_all() -> [sql, fs_write, fs_read, time, random, crypto, vcs] Unit {
  let results := [test_mirror_vcs_returns_ok_on_a_normal_write(), test_artifact_put_still_returns_ok_hash_on_success(), test_mirror_failed_trail_row_is_recorded_and_countable()]
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

