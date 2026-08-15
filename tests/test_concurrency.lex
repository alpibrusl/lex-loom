# test_concurrency.lex — HB3 (lex-loom#215): money and claims under contention.
#
# All offline. The two invariants that make multi-worker + parallel company
# runs safe on loom's SQLite-only backend:
#
#   1. LEDGER — budget.charge and add_company_cost_cents are single-statement
#      relative UPDATEs; hammered from parallel par_map workers, the final
#      totals are EXACT (no lost update; money stays integer cents).
#   2. CLAIM — jobs.try_claim is a single UPDATE ... WHERE id=(SELECT ...)
#      RETURNING; N parallel claimers against one queue each get a DISTINCT
#      job (or none), never the same job twice.
#   3. BUDGET STOP — an envelope charged concurrently past its cap still
#      trips Exhausted exactly (spent is the true sum, so the stop condition
#      cannot be dodged by racing writers).

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.int" as int

import "std.sql" as sql

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-jobs/src/jobs" as jobs

import "../src/migrate" as migrate

import "../src/budget" as budget

import "../src/company" as company

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-hb3-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn range(n :: Int) -> List[Int] {
  if n <= 0 {
    []
  } else {
    list.concat(range(n - 1), [n])
  }
}

# ── 1. No lost update on the cost ledger under parallel writers ──────────────
fn test_ledger_contention() -> [io, sql, fs_read, fs_write, time, random, crypto, concurrent] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb3-ledger-", crypto.random_str_hex(6))
      let cfg :: company.CompanyCfg := { id: cid, goal: "g", model: "m", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
      let __c := company.save_company(db, cfg)
      let workers := 8
      let per_worker := 25
      let results := list.par_map(range(workers), fn (_w :: Int) -> [sql, fs_read, fs_write, concurrent] Int {
        list.fold(range(per_worker), 0, fn (acc :: Int, _i :: Int) -> [sql, fs_write] Int {
          match company.add_company_cost_cents(db, cid, 3) {
            Err(_) => acc,
            Ok(_) => acc + 1,
          }
        })
      })
      let ok_writes := list.fold(results, 0, fn (a :: Int, n :: Int) -> Int {
        a + n
      })
      let total := company.get_company_cost_cents(db, cid)
      match check("every parallel write landed (no refused writes)", ok_writes == workers * per_worker) {
        Err(e) => Err(e),
        Ok(_) => check(str.join(["ledger total exact under contention (", int.to_str(total), " == ", int.to_str(workers * per_worker * 3), ")"], ""), total == workers * per_worker * 3),
      }
    },
  }
}

# ── 2. Parallel claimers never get the same job ──────────────────────────────
fn test_claim_contention() -> [io, sql, fs_read, fs_write, time, random, crypto, concurrent] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let queue := str.concat("hb3-q-", crypto.random_str_hex(6))
      let jobs_n := 6
      let __enq := list.map(range(jobs_n), fn (i :: Int) -> [sql, fs_write, time] Unit {
        let __e := jobs.enqueue(db.handle, queue, "node", str.concat("payload-", int.to_str(i)))
        ()
      })
      let claimers := 12
      let claimed := list.par_map(range(claimers), fn (_c :: Int) -> [sql, fs_read, fs_write, time, concurrent] Str {
        match jobs.try_claim(db.handle, queue) {
          Err(e) => str.concat("ERR:", e),
          Ok(None) => "",
          Ok(Some(j)) => int.to_str(j.id),
        }
      })
      let errors := list.filter(claimed, fn (s :: Str) -> Bool {
        str.starts_with(s, "ERR:")
      })
      let ids := list.filter(claimed, fn (s :: Str) -> Bool {
        not str.is_empty(s) and not str.starts_with(s, "ERR:")
      })
      let distinct := list.fold(ids, [], fn (acc :: List[Str], id :: Str) -> List[Str] {
        if list.fold(acc, false, fn (seen :: Bool, x :: Str) -> Bool {
          seen or x == id
        }) {
          acc
        } else {
          list.concat(acc, [id])
        }
      })
      match check(str.join(["no claim errors under contention (", str.join(errors, "; "), ")"], ""), list.is_empty(errors)) {
        Err(e) => Err(e),
        Ok(_) => match check("every job claimed exactly once (no double-claim)", list.len(distinct) == list.len(ids)) {
          Err(e) => Err(e),
          Ok(_) => check("all jobs were handed out across the claimers", list.len(ids) == jobs_n),
        },
      }
    },
  }
}

# ── 3. Budget stop still trips exactly under concurrent charges ──────────────
fn test_budget_stop_under_contention() -> [io, sql, fs_read, fs_write, time, random, crypto, concurrent] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("hb3-budget-", crypto.random_str_hex(6))
      let __e := budget.set_envelope(db, cid, "total", 100, "founder")
      let workers := 10
      let __charges := list.par_map(range(workers), fn (_w :: Int) -> [sql, fs_read, fs_write, time, concurrent] Unit {
        let __r := budget.charge(db, cid, "docs", 20)
        ()
      })
      let st := budget.check_scope(db, cid, "total")
      let spent_ok := match budget.envelope_for(db, cid, "total") {
        None => false,
        Some(env0) => env0.spent_cents == workers * 20,
      }
      match check("spent is the exact sum of concurrent charges (integer cents)", spent_ok) {
        Err(e) => Err(e),
        Ok(_) => check("cap breach trips Exhausted under contention", match st {
          Exhausted => true,
          _ => false,
        }),
      }
    },
  }
}

fn suite() -> [io, sql, fs_read, fs_write, time, random, crypto, concurrent] List[Result[Unit, Str]] {
  [test_ledger_contention(), test_claim_contention(), test_budget_stop_under_contention()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, random, crypto, concurrent] Unit {
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

