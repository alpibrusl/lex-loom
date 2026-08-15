# test_node_results_race.lex — regression coverage for the sprint-completion
# race found live running a real company (tzconvert, queue mode): dynamic-
# extension rounds (run_extensions) reuse the SAME phase name
# ("Implementation") and the SAME node ids (e.g. "py_build-api",
# "py_qa-tests") every round. `read_node_results`/`await_node_results` key
# their "is this node done yet" check on (sprint_id, phase, node_id) alone —
# no per-round/per-enqueue generation marker — so a STALE accepted row left
# over from an EARLIER round satisfied a LATER round's await instantly,
# letting the orchestrator race ahead to Demo/Digest/sprint_complete while
# the real job for that round was still running on a worker, which then
# wrote its own late node_started/node_accepted trace events well after the
# sprint had already "completed" (fully_sealed:false despite the real result
# eventually coming back PASS).
#
# The fix: transport.clear_node_result deletes any existing row for
# (sprint_id, phase, node_id) right before a fresh job is enqueued for it, so
# await_node_results can only observe a row written by THIS enqueue.

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

# Each open is a fresh per-run file DB (#242); random suffixes keep
# sprint/node ids unique within a connection.
fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn find_result(rows :: List[tr.NodeResultRow], node_id :: Str) -> Option[tr.NodeResultRow] {
  list.fold(rows, None, fn (acc :: Option[tr.NodeResultRow], r :: tr.NodeResultRow) -> Option[tr.NodeResultRow] {
    match acc {
      Some(_) => acc,
      None => if r.node_id == node_id {
        Some(r)
      } else {
        None
      },
    }
  })
}

# The exact bug: round 1 accepts "py_qa-tests", writing a row. Round 2
# re-enqueues the SAME node id under the SAME phase before its real result is
# in. Without the fix, await_node_results would see round 1's stale ACCEPTED
# row and report done immediately -- the assertion pins that this no longer
# happens once the stale row is cleared first.
fn test_clear_node_result_removes_stale_prior_round_row() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      let phase := "Implementation"
      let node_id := "py_qa-tests"
      match tr.write_node_result(db, sprint_id, node_id, phase, true, "round1-artifact", "round 1 passed") {
        Err(m) => Err(str.concat("seed write_node_result failed: ", m)),
        Ok(_) => match tr.clear_node_result(db, sprint_id, phase, node_id) {
          Err(m) => Err(str.concat("clear_node_result failed: ", m)),
          Ok(_) => {
            let rows := tr.read_node_results(db, sprint_id, phase)
            if list.is_empty(rows) {
              Ok(())
            } else {
              Err("expected the stale round-1 row to be gone after clear_node_result")
            }
          },
        },
      }
    },
  }
}

# clear_node_result must only remove rows for the exact (sprint_id, phase,
# node_id) triple -- a sibling node's row in the same phase must survive.
fn test_clear_node_result_only_clears_the_named_node() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      let phase := "Implementation"
      match tr.write_node_result(db, sprint_id, "py_build-api", phase, true, "b-artifact", "build ok") {
        Err(m) => Err(m),
        Ok(_) => match tr.write_node_result(db, sprint_id, "py_qa-tests", phase, true, "q-artifact", "qa ok") {
          Err(m) => Err(m),
          Ok(_) => match tr.clear_node_result(db, sprint_id, phase, "py_qa-tests") {
            Err(m) => Err(m),
            Ok(_) => {
              let rows := tr.read_node_results(db, sprint_id, phase)
              if list.len(rows) == 1 {
                match find_result(rows, "py_build-api") {
                  Some(_) => Ok(()),
                  None => Err("the surviving row should be the build node's, not the cleared qa node's"),
                }
              } else {
                Err("expected exactly 1 surviving row (the build one)")
              }
            },
          },
        },
      }
    },
  }
}

# End-to-end shape of the real bug: after a stale round-1 row is cleared and
# a fresh round-2 row is written, await_node_results (given a short timeout
# so this test doesn't hang) must return the FRESH row's content, not report
# done based on data from before the clear.
fn test_await_after_clear_sees_only_the_fresh_row() -> [random, sql, fs_read, fs_write, time, crypto, io] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint_id := uniq("s")
      let phase := "Implementation"
      let node_id := "py_qa-tests"
      match tr.write_node_result(db, sprint_id, node_id, phase, true, "round1-artifact", "round 1 passed") {
        Err(m) => Err(m),
        Ok(_) => match tr.clear_node_result(db, sprint_id, phase, node_id) {
          Err(m) => Err(m),
          Ok(_) => match tr.write_node_result(db, sprint_id, node_id, phase, false, "", "round 2 still failing") {
            Err(m) => Err(m),
            Ok(_) => match tr.await_node_results(db, sprint_id, phase, [node_id], 1000, 10) {
              Err(m) => Err(str.concat("await_node_results errored: ", m)),
              Ok(rows) => match find_result(rows, node_id) {
                None => Err("expected a result row for the node"),
                Some(r) => if r.accepted == 0 {
                  Ok(())
                } else {
                  Err("expected the FRESH round-2 (denied) result, got the stale round-1 (accepted) one")
                },
              },
            },
          },
        },
      }
    },
  }
}

fn suite() -> [random, sql, fs_read, fs_write, time, crypto, io] List[Result[Unit, Str]] {
  [test_clear_node_result_removes_stale_prior_round_row(), test_clear_node_result_only_clears_the_named_node(), test_await_after_clear_sees_only_the_fresh_row()]
}

fn run_all() -> [random, sql, fs_read, fs_write, time, crypto, io] Unit {
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

