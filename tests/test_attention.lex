# test_attention.lex — regression coverage for the human-attestation queue
# (#89: the `human <oracle>` gate lane, e.g. monetization_handoff).
#
# push_attention/list_attention_pending/resolve_attention had zero existing
# test coverage — this pins down the round-trip a human actually depends on:
# a node pushed to the queue shows up as pending, and resolving it (approved
# or rejected) removes it from the pending list.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "std.fs" as fs

import "../src/migrate" as migrate

import "../src/transport" as tr

fn fresh_db() -> [sql, fs_write, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

# Each open is a fresh per-run file DB (#242); random suffixes still keep
# ids unique when several rows share one connection within a test.
fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn find_by_id(rows :: List[tr.AttentionRow], id :: Str) -> Option[tr.AttentionRow] {
  list.fold(rows, None, fn (acc :: Option[tr.AttentionRow], r :: tr.AttentionRow) -> Option[tr.AttentionRow] {
    match acc {
      Some(_) => acc,
      None => if r.id == id {
        Some(r)
      } else {
        None
      },
    }
  })
}

fn test_pushed_item_appears_as_pending() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      match tr.push_attention(db, sprint_id, "mh", "human founder", "founder", "hash123") {
        Err(m) => Err(str.concat("push_attention failed: ", m)),
        Ok(id) => {
          let pending := tr.list_attention_pending(db)
          match find_by_id(pending, id) {
            None => Err("expected the pushed item to appear in list_attention_pending"),
            Some(row) => if row.oracle == "founder" {
              if row.verdict == "pending" {
                Ok(())
              } else {
                Err(str.concat("expected verdict='pending', got ", row.verdict))
              }
            } else {
              Err(str.concat("expected oracle='founder', got ", row.oracle))
            },
          }
        },
      }
    },
  }
}

fn test_resolving_approved_removes_it_from_pending() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      match tr.push_attention(db, sprint_id, "mh", "human founder", "founder", "hash123") {
        Err(m) => Err(str.concat("push_attention failed: ", m)),
        Ok(id) => match tr.resolve_attention(db, id, "approved", "", "jane-doe") {
          Err(m) => Err(str.concat("resolve_attention failed: ", m)),
          Ok(_) => {
            let pending := tr.list_attention_pending(db)
            match find_by_id(pending, id) {
              None => Ok(()),
              Some(_) => Err("expected the resolved item to no longer be pending"),
            }
          },
        },
      }
    },
  }
}

fn test_resolving_rejected_records_the_reason() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      match tr.push_attention(db, sprint_id, "mh", "human founder", "founder", "hash123") {
        Err(m) => Err(str.concat("push_attention failed: ", m)),
        Ok(id) => match tr.resolve_attention(db, id, "rejected", "price is too low", "jane-doe") {
          Err(m) => Err(str.concat("resolve_attention failed: ", m)),
          Ok(_) => {
            let pending := tr.list_attention_pending(db)
            match find_by_id(pending, id) {
              None => Ok(()),
              Some(_) => Err("expected the rejected item to no longer be pending"),
            }
          },
        },
      }
    },
  }
}

fn test_resolve_records_who_resolved_it() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      match tr.push_attention(db, sprint_id, "mh", "human founder", "founder", "hash123") {
        Err(m) => Err(str.concat("push_attention failed: ", m)),
        Ok(id) => match tr.resolve_attention(db, id, "approved", "", "jane-doe") {
          Err(m) => Err(str.concat("resolve_attention failed: ", m)),
          Ok(_) => match tr.get_attention(db, id) {
            None => Err("expected get_attention to find the resolved row"),
            Some(row) => if row.resolved_by == "jane-doe" {
              Ok(())
            } else {
              Err(str.concat("expected resolved_by='jane-doe', got ", row.resolved_by))
            },
          },
        },
      }
    },
  }
}

fn test_two_pending_items_from_different_sprints_both_listed() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sid_a := uniq("s-a")
      let sid_b := uniq("s-b")
      match tr.push_attention(db, sid_a, "mh", "human founder", "founder", "hashA") {
        Err(m) => Err(m),
        Ok(id_a) => match tr.push_attention(db, sid_b, "mh", "human founder", "founder", "hashB") {
          Err(m) => Err(m),
          Ok(id_b) => {
            let pending := tr.list_attention_pending(db)
            match find_by_id(pending, id_a) {
              None => Err("expected first pushed item to be pending"),
              Some(_) => match find_by_id(pending, id_b) {
                None => Err("expected second pushed item to be pending"),
                Some(_) => Ok(()),
              },
            }
          },
        },
      }
    },
  }
}

fn suite() -> [random, sql, fs_read, fs_write, time, crypto] List[Result[Unit, Str]] {
  [test_pushed_item_appears_as_pending(), test_resolving_approved_removes_it_from_pending(), test_resolving_rejected_records_the_reason(), test_resolve_records_who_resolved_it(), test_two_pending_items_from_different_sprints_both_listed()]
}

fn run_all() -> [io, random, sql, fs_read, fs_write, time, crypto] Unit {
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

