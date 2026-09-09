# test_economy_binding.lex -- a company's treasury lives on loom's own DB
# handle (#398). Proves the handle compatibility with lex-economy and the
# idempotence a resumed company relies on.

import "std.str" as str

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-economy/src/treasury" as treasury

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/economy_binding" as eb

import "../src/budget" as budget

fn with_db(f :: (conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str]) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => f(db),
    },
  }
}

fn test_a_company_gets_a_treasury_on_looms_own_handle() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match eb.ensure_treasury(db, "softwareco", "EUR", 200000) {
      Err(e) => Err(str.concat("could not open a treasury on loom's db handle: ", e)),
      Ok(t) => if t.balance_cents == 200000 and t.committed_cents == 0 and t.company == "softwareco" {
        Ok(())
      } else {
        Err("the opened treasury does not carry the opening balance")
      },
    }
  })
}

fn test_ensure_treasury_is_idempotent() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match eb.ensure_treasury(db, "co", "EUR", 100000) {
      Err(e) => Err(e),
      Ok(_) => match eb.ensure_treasury(db, "co", "EUR", 999999) {
        Err(e) => Err(e),
        Ok(t) => if t.balance_cents == 100000 {
          Ok(())
        } else {
          Err("a resumed company was re-funded: ensure_treasury is not idempotent")
        },
      },
    }
  })
}

fn test_a_commitment_reserves_and_an_overcommit_is_refused() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match tlog.open_memory() {
      Err(e) => Err(str.concat("trail: ", e)),
      Ok(log) => match eb.ensure_treasury(db, "buyer", "EUR", 100000) {
        Err(e) => Err(e),
        Ok(_) => match eb.commit_for_contract(db, log, "buyer", "contract-1", "commit-1", 60000, "EUR") {
          Err(e) => Err(str.concat("a commitment within balance was refused: ", e)),
          Ok(_) => match treasury.get_treasury(db.handle, "buyer") {
            Ok(Some(t)) => if treasury.available_cents(t) == 40000 {
              match eb.commit_for_contract(db, log, "buyer", "contract-2", "commit-2", 50000, "EUR") {
                Ok(_) => Err("a commitment beyond the available balance was accepted"),
                Err(_) => Ok(()),
              }
            } else {
              Err("the commitment did not reserve the funds")
            },
            _ => Err("treasury vanished after the commitment"),
          },
        },
      },
    }
  })
}

fn test_company_start_funds_the_treasury_from_the_total_envelope() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match budget.set_envelope(db, "funded", "total", 30000, "test") {
      Err(e) => Err(str.concat("set_envelope: ", e)),
      Ok(_) => match eb.fund_from_total_envelope(db, "funded") {
        Err(e) => Err(e),
        Ok(None) => Err("a company with a total envelope got no treasury"),
        Ok(Some(t)) => if t.balance_cents == 30000 {
          match eb.fund_from_total_envelope(db, "unfunded") {
            Ok(None) => Ok(()),
            Ok(Some(_)) => Err("a company with no budget envelope was given a treasury out of nothing"),
            Err(e) => Err(e),
          }
        } else {
          Err("the treasury's opening balance is not the total envelope's cap")
        },
      },
    }
  })
}

fn suite() -> [sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_a_company_gets_a_treasury_on_looms_own_handle(), test_ensure_treasury_is_idempotent(), test_a_commitment_reserves_and_an_overcommit_is_refused(), test_company_start_funds_the_treasury_from_the_total_envelope()]
}

fn run_all() -> [sql, fs_read, fs_write, time, random, crypto] Unit {
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

