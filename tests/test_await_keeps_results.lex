# test_await_keeps_results.lex — a layer await must keep what arrived, wait
# while work is in flight, and leave nothing behind when a sprint ends (#328).
#
# Company tzc8, iteration 3, from the trail: the Implementation layer was
# enqueued at 11:58:55; py-build was ACCEPTED at 12:00:28; the test author was
# still running; at 12:08:58 — ten minutes and three seconds later — the await
# timed out, returned Err for the whole layer, and every node in it was marked
# unattested, the finished build included. QA truthfully reported no attested
# producer, the sprint bounced, and iteration 2 had already started at 11:06
# while iteration 1's jobs were still executing. Nothing was trailed. Five
# company runs failed this way; in isolation every role measured 5/5.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-jobs/src/jobs" as jobs

import "../src/migrate" as migrate

import "../src/transport" as tr

import "../src/orchestrator" as orch

fn fresh_db() -> [sql, fs_write, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(m) => Err(str.concat("migrate failed: ", m)),
      Ok(_) => Ok(db),
    },
  }
}

fn uniq(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

fn enqueue(db :: conn.ConnDb, sprint :: Str, node :: Str) -> [sql, time, random, crypto, fs_write] Unit {
  let __ := tr.enqueue_node(db, sprint, node, "Implementation", "", "m", "r", 10)
  ()
}

# Claim the most recent pending job so it is `running`, as a worker would.
fn claim_one(db :: conn.ConnDb) -> [sql, time] Option[Int] {
  match jobs.try_claim(db.handle, tr.node_queue()) {
    Ok(Some(j)) => Some(j.id),
    _ => None,
  }
}

# --- 1. the whole bug: a result that arrived must survive a timeout ---------
fn test_arrived_result_survives_a_timeout() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint := uniq("s")
      let __w := tr.write_node_result(db, sprint, "py-build", "Implementation", true, "art-1", "accepted")
      let aw := tr.await_node_results_partial(db, sprint, "Implementation", ["py-build", "py-test-author"], 100, 5000, 20)
      if not aw.timed_out {
        Err("with one node absent and nothing in flight, the await should have timed out on idle")
      } else {
        let build := orch.outcome_from_await("py-build", aw)
        if build.attested {
          if tr.has(aw.missing, "py-test-author") and not tr.has(aw.missing, "py-build") {
            Ok(())
          } else {
            Err("the missing list is wrong: it must name exactly the node without a result")
          }
        } else {
          Err("an ACCEPTED build was reported unattested because its neighbour timed out — this is the tzc8 failure")
        }
      }
    },
  }
}

# --- 2. a running job is the node doing its work, not a fault ---------------
# The idle bound is 100ms but the job is running, so the await must NOT give
# up at 100ms; the 600ms cap is what ends the wait.
fn test_await_waits_while_a_job_is_running() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint := uniq("s")
      let __e := enqueue(db, sprint, "py-test-author")
      match claim_one(db) {
        None => Err("could not claim the job to make it running"),
        Some(_) => {
          let aw := tr.await_node_results_partial(db, sprint, "Implementation", ["py-test-author"], 100, 600, 20)
          if aw.waited_ms < 500 {
            Err(str.join(["gave up after ", int.to_str(aw.waited_ms), "ms while the job was running — a 25-minute build would be abandoned at 10"], ""))
          } else {
            if tr.has(aw.in_flight, "py-test-author") {
              let o := orch.outcome_from_await("py-test-author", aw)
              if str.contains(o.reason, "STILL RUNNING") {
                Ok(())
              } else {
                Err(str.concat("the reason does not say the job was still running: ", o.reason))
              }
            } else {
              Err("a running job was not reported as in flight")
            }
          }
        },
      }
    },
  }
}

# --- 3. nothing in flight and nothing arriving: give up at the idle bound ---
fn test_a_lost_job_gives_up_at_the_idle_bound() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let aw := tr.await_node_results_partial(db, uniq("s"), "Implementation", ["ghost"], 100, 5000, 20)
      if aw.timed_out and aw.waited_ms < 1000 and list.is_empty(aw.in_flight) {
        let o := orch.outcome_from_await("ghost", aw)
        if str.contains(o.reason, "job lost") {
          Ok(())
        } else {
          Err(str.concat("a lost job should be named as such: ", o.reason))
        }
      } else {
        Err("with no job in flight the await should stop at the idle bound, not the cap")
      }
    },
  }
}

# --- 4. everything present: no waiting, no timeout ---------------------------
fn test_complete_layer_returns_at_once() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let sprint := uniq("s")
      let __a := tr.write_node_result(db, sprint, "a", "Implementation", true, "x", "")
      let __b := tr.write_node_result(db, sprint, "b", "Implementation", false, "", "gate failed")
      let aw := tr.await_node_results_partial(db, sprint, "Implementation", ["a", "b"], 100, 5000, 20)
      if aw.timed_out or not list.is_empty(aw.missing) {
        Err("a complete layer was reported as timed out or missing nodes")
      } else {
        let b := orch.outcome_from_await("b", aw)
        if b.attested {
          Err("a DENIED result was reported attested — keeping arrived rows must not mean accepting them")
        } else {
          Ok(())
        }
      }
    },
  }
}

# --- 5. a finished sprint leaves nothing in the queue ------------------------
fn test_drain_fails_only_this_sprints_unfinished_jobs() -> [random, sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match fresh_db() {
    Err(m) => Err(m),
    Ok(db) => {
      let a := uniq("a")
      let b := uniq("b")
      let __1 := enqueue(db, a, "done-one")
      let __c1 := claim_one(db)
      let __ack := match __c1 {
        Some(id) => match jobs.ack(db.handle, id) {
          _ => (),
        },
        None => (),
      }
      let __2 := enqueue(db, a, "running-one")
      let __c2 := claim_one(db)
      let __3 := enqueue(db, a, "pending-one")
      let __4 := enqueue(db, b, "other-sprint")
      let n := tr.drain_sprint_jobs(db, a)
      if n != 2 {
        Err(str.join(["expected to fail exactly the running and pending jobs of sprint a (2), failed ", int.to_str(n)], ""))
      } else {
        if not list.is_empty(tr.jobs_in_flight(db, a, ["running-one", "pending-one", "done-one"])) {
          Err("sprint a still has work in flight after the drain")
        } else {
          if list.is_empty(tr.jobs_in_flight(db, b, ["other-sprint"])) {
            Err("the drain touched ANOTHER sprint's job — the next iteration's work was failed")
          } else {
            Ok(())
          }
        }
      }
    },
  }
}

fn suite() -> [random, sql, fs_read, fs_write, time, crypto] List[Result[Unit, Str]] {
  [test_arrived_result_survives_a_timeout(), test_await_waits_while_a_job_is_running(), test_a_lost_job_gives_up_at_the_idle_bound(), test_complete_layer_returns_at_once(), test_drain_fails_only_this_sprints_unfinished_jobs()]
}

fn run_all() -> [random, sql, fs_read, fs_write, time, crypto] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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

