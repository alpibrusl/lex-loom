# test_await_supervises_workers.lex — the thing waiting on a wedged worker is
# the thing that can rescue it, and no node runs forever.
#
# lex-loom#474, found live: formcolocal sat inside build-core for two hours at
# 0% CPU with status `running` and a live process, and nothing was coming.
# jobs.reclaim_stale -- the function that returns a job orphaned by a dead
# worker to the queue -- runs inside the worker's own poll loop, in the branch
# taken when the worker has NOTHING to do. With WORKER_COUNT=1, the default
# and what every cloud company runs, the only process that could reclaim the
# job was the one that was stuck.
#
# And nothing bounded a node that kept talking: the stall timer resets on
# every trail row, so a build logging 549 steps was never stalled. The only
# absolute bound was `stall_ms * 10` -- a derived five hours nobody chose.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-jobs/src/jobs" as jobs

import "../src/transport" as tr

import "../src/migrate" as migrate

fn db_path() -> Str {
  "/tmp/loom-await-supervise-test.db"
}

fn fresh() -> [sql, fs_write, proc] Result[conn.ConnDb, Str] {
  let __ := proc_rm()
  match conn.open(db_path()) {
    Err(_) => Err("could not open the test database"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

import "std.process" as proc

fn proc_rm() -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.concat("rm -f ", str.concat(db_path(), "*"))])
  ()
}

# A job claimed by a worker that then died: status running, leased long ago.
fn wedge_a_job(db :: conn.ConnDb, sprint :: Str, node :: Str) -> [sql, time] Result[Int, Str] {
  match jobs.enqueue(db.handle, tr.node_queue(), "invoke", str.join(["{\"sprint_id\":\"", sprint, "\",\"node_id\":\"", node, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(id) => match sql.exec(db.handle, "UPDATE lex_jobs SET status = 'running', updated_at = 0 WHERE id = ?", [PInt(id)]) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(id),
    },
  }
}

type StatusRow = { status :: Str }

fn status_of(db :: conn.ConnDb, id :: Int) -> [sql] Str {
  let rs :: Result[List[StatusRow], SqlError] := sql.query(db.handle, "SELECT status FROM lex_jobs WHERE id = ?", [PInt(id)])
  match rs {
    Err(_) => "",
    Ok(rows) => match list.head(rows) {
      None => "",
      Some(r) => r.status,
    },
  }
}

# The await is awake every poll and is not the thing that can wedge, so it is
# what reclaims.
fn test_the_await_reclaims_what_the_worker_cannot() -> [sql, fs_read, fs_write, time, io, crypto, random, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => match wedge_a_job(db, "sup/iter-1", "build-1") {
      Err(e) => {
        let __c := conn.close(db)
        Err(e)
      },
      Ok(id) => {
        let before := status_of(db, id)
        let __aw := tr.await_node_results_supervised(db, "sup/iter-1", "Implementation", ["build-1"], 100, 100000, 100000, 60, 10, 20)
        let after := status_of(db, id)
        let __c := conn.close(db)
        if before == "running" {
          if after == "pending" {
            Ok(())
          } else {
            Err(str.concat("the orphaned job was not returned to the queue; status is ", after))
          }
        } else {
          Err(str.concat("the fixture did not wedge the job; status is ", before))
        }
      },
    },
  }
}

# A node that keeps the trail busy is never "stalled", so the cap is the only
# thing that ends it.
fn test_a_noisy_node_still_hits_the_cap() -> [sql, fs_read, fs_write, time, io, crypto, random, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => match wedge_a_job(db, "sup/iter-2", "build-2") {
      Err(e) => {
        let __c := conn.close(db)
        Err(e)
      },
      Ok(_) => {
        let started := time.now_ms()
        let aw := tr.await_node_results_supervised(db, "sup/iter-2", "Implementation", ["build-2"], 100000, 100000, 300, 0, 0, 20)
        let took := time.now_ms() - started
        let __c := conn.close(db)
        if aw.timed_out {
          if took < 5000 {
            Ok(())
          } else {
            Err(str.concat("the cap did not end the await promptly; it took ms: ", int_str(took)))
          }
        } else {
          Err("an await with an in-flight job and a 300ms cap did not time out")
        }
      },
    },
  }
}

import "std.int" as int

fn int_str(n :: Int) -> Str {
  int.to_str(n)
}

# The unsupervised entry point keeps its old behaviour exactly: no reclaim.
fn test_the_plain_await_reclaims_nothing() -> [sql, fs_read, fs_write, time, io, crypto, random, proc] Result[Unit, Str] {
  match fresh() {
    Err(e) => Err(e),
    Ok(db) => match wedge_a_job(db, "sup/iter-3", "build-3") {
      Err(e) => {
        let __c := conn.close(db)
        Err(e)
      },
      Ok(id) => {
        let __aw := tr.await_node_results_partial(db, "sup/iter-3", "Implementation", ["build-3"], 100, 200, 20)
        let after := status_of(db, id)
        let __c := conn.close(db)
        if after == "running" {
          Ok(())
        } else {
          Err(str.concat("the plain await changed a job it should not touch: ", after))
        }
      },
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, io, crypto, random, proc] Int {
  let results := [("the await reclaims what the worker cannot", test_the_await_reclaims_what_the_worker_cannot()), ("a noisy node still hits the cap", test_a_noisy_node_still_hits_the_cap()), ("the plain await reclaims nothing", test_the_plain_await_reclaims_nothing())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

