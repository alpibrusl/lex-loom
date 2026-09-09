# test_consortium.lex -- run 1 of the consortium, end to end on a temp db,
# with the report gate's output supplied as text (no model, no search).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "lex-economy/src/treasury" as treasury

import "lex-economy/src/contract" as contract

import "../src/migrate" as migrate

import "../src/consortium" as cs

import "../src/economy_contract" as ec

import "lex-economy/src/evidence" as evidence

fn with_db(f :: (conn.ConnDb, tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str]) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-cs-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => match tlog.open_memory() {
        Err(e) => Err(str.concat("trail open failed: ", e)),
        Ok(log) => f(db, log),
      },
    },
  }
}

fn all_ok() -> Str {
  "check_research_report: fine\nRESEARCH_REPORT_OK checkable:problem-statement checkable:target-user checkable:three-alternatives checkable:implementation-estimate checkable:dependencies checkable:two-sources checkable:sources-grounded checkable:confidence checkable:recommendation\n"
}

fn missing_sources() -> Str {
  "RESEARCH_REPORT_OK checkable:problem-statement checkable:target-user checkable:three-alternatives checkable:implementation-estimate checkable:dependencies checkable:confidence checkable:recommendation\n"
}

fn denied() -> Str {
  "check_research_report: the report does not meet these checkable criteria:\n\n  checkable:three-alternatives  (## Alternatives): needs a markdown table with at least 3 alternatives (found 1)\n"
}

fn problem() -> Str {
  "paid micro-APIs for solo developers who need to validate and normalise user-submitted data"
}

fn buyer(db :: conn.ConnDb) -> [sql] treasury.Treasury {
  match treasury.get_treasury(db.handle, cs.softwareco()) {
    Ok(Some(t)) => t,
    _ => { company: "", currency: "", balance_cents: -1, committed_cents: -1 },
  }
}

fn open_ok(db :: conn.ConnDb, log :: tlog.Log) -> [sql, time, fs_read, fs_write] Result[cs.Opened, Str] {
  cs.open_run(db, log, problem(), 1000)
}

fn test_open_reserves_the_price_on_the_buyer() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(o) => {
        let b := buyer(db)
        if o.contract.state == contract.Awarded and o.contract.buyer == cs.softwareco() and o.contract.supplier == cs.researchco() and o.contract.price.cents == 40000 and b.committed_cents == 40000 and b.balance_cents == 200000 {
          if str.contains(o.goal, "[answered by a human, not by you] human:would-fund") and str.contains(o.goal, "checkable:sources-grounded") and str.contains(o.goal, problem()) {
            Ok(())
          } else {
            Err(str.concat("the goal does not carry the criteria with the human one marked: ", str.slice(o.goal, 0, 300)))
          }
        } else {
          Err(str.join(["open did not award and reserve 40000c on softwareco: state=", cs.state_str(o.contract.state), " committed=", int.to_str(b.committed_cents), " balance=", int.to_str(b.balance_cents)], ""))
        }
      },
    }
  })
}

fn test_open_twice_is_refused() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match open_ok(db, log) {
        Ok(_) => Err("a second open reserved the price twice"),
        Err(_) => if buyer(db).committed_cents == 40000 {
          Ok(())
        } else {
          Err("the refused second open still changed the commitment")
        },
      },
    }
  })
}

fn test_delivery_is_held_ambiguous_until_the_human_answers() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), all_ok(), 2000) {
        Err(e) => Err(e),
        Ok(o) => match o.verdict {
          Ambiguous(names) => if names == [cs.human_attr()] and buyer(db).committed_cents == 40000 and buyer(db).balance_cents == 200000 {
            Ok(())
          } else {
            Err(str.join(["ambiguous, but on the wrong names or the money moved: ", str.join(names, ","), " committed=", int.to_str(buyer(db).committed_cents)], ""))
          },
          _ => Err(str.concat("a delivery with the human criterion unanswered was not held Ambiguous: ", cs.state_str(o.final.state))),
        },
      },
    }
  })
}

fn test_yes_settles_in_full() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), all_ok(), 2000) {
        Err(e) => Err(e),
        Ok(_) => match cs.answer(db, log, cs.research_contract_id(), true, "yes, fund it", 3000) {
          Err(e) => Err(e),
          Ok(o) => if o.final.state == contract.Settled and o.verdict == contract.Fulfilled and buyer(db).committed_cents == 0 and buyer(db).balance_cents == 160000 {
            match cs.answer(db, log, cs.research_contract_id(), false, "changed my mind", 4000) {
              Ok(_) => Err("a settled contract took a second answer"),
              Err(_) => if buyer(db).balance_cents == 160000 {
                Ok(())
              } else {
                Err("the refused second answer moved money")
              },
            }
          } else {
            Err(str.join(["yes on a fully verified report did not settle 40000c: state=", cs.state_str(o.final.state), " committed=", int.to_str(buyer(db).committed_cents), " balance=", int.to_str(buyer(db).balance_cents)], ""))
          },
        },
      },
    }
  })
}

fn test_a_partly_verified_report_pays_half() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), missing_sources(), 2000) {
        Err(e) => Err(e),
        Ok(_) => match cs.answer(db, log, cs.research_contract_id(), true, "yes", 3000) {
          Err(e) => Err(e),
          Ok(o) => if o.final.state == contract.Settled and o.verdict == contract.PartiallyFulfilled(["checkable:two-sources", "checkable:sources-grounded"]) and buyer(db).balance_cents == 180000 and buyer(db).committed_cents == 0 {
            Ok(())
          } else {
            Err(str.join(["two unmet checkable criteria did not pay 50%: state=", cs.state_str(o.final.state), " balance=", int.to_str(buyer(db).balance_cents)], ""))
          },
        },
      },
    }
  })
}

fn test_a_denied_report_is_rejected_without_asking_the_human() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), denied(), 2000) {
        Err(e) => Err(e),
        Ok(o) => match o.verdict {
          Rejected(unmet) => if list.len(unmet) == 9 and o.final.state == contract.Disputed and buyer(db).balance_cents == 200000 and buyer(db).committed_cents == 0 {
            match cs.answer(db, log, cs.research_contract_id(), true, "late yes", 3000) {
              Ok(_) => Err("a rejected delivery took a human answer afterwards"),
              Err(_) => Ok(()),
            }
          } else {
            Err(str.join(["rejected, but the funds were not released: state=", cs.state_str(o.final.state), " balance=", int.to_str(buyer(db).balance_cents), " committed=", int.to_str(buyer(db).committed_cents)], ""))
          },
          _ => Err("a delivery meeting no checkable criterion was not Rejected outright -- the founder would be asked about a report that was not delivered"),
        },
      },
    }
  })
}

fn test_deliver_twice_is_refused() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), all_ok(), 2000) {
        Err(e) => Err(e),
        Ok(_) => match cs.deliver(db, log, cs.research_contract_id(), denied(), 2500) {
          Ok(_) => Err("a second delivery overwrote the first"),
          Err(_) => Ok(()),
        },
      },
    }
  })
}

fn test_status_reads_back_the_run() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb, log :: tlog.Log) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match open_ok(db, log) {
      Err(e) => Err(e),
      Ok(_) => {
        let s := cs.status_text(db, 5000)
        if str.contains(s, "softwareco: balance=200000c committed=40000c available=160000c") and str.contains(s, "c-research-1: softwareco -> researchco 40000c state=awarded") and str.contains(s, "should terminate=no") {
          Ok(())
        } else {
          Err(str.concat("status does not reconstruct the run: ", s))
        }
      },
    }
  })
}

fn test_checker_output_becomes_one_item_per_checkable_criterion() -> Result[Unit, Str] {
  let items := ec.evidence_from_checker(cs.run1_criteria(), missing_sources())
  let unmet := list.map(list.filter(items, fn (i :: evidence.EvidenceItem) -> Bool {
    not i.satisfied
  }), fn (i :: evidence.EvidenceItem) -> Str {
    i.attr
  })
  if list.len(items) == 9 and unmet == ["checkable:two-sources", "checkable:sources-grounded"] {
    Ok(())
  } else {
    Err(str.join(["expected 9 items with two unmet, got ", int.to_str(list.len(items)), " items; unmet: ", str.join(unmet, ",")], ""))
  }
}

fn suite() -> [sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_open_reserves_the_price_on_the_buyer(), test_open_twice_is_refused(), test_delivery_is_held_ambiguous_until_the_human_answers(), test_yes_settles_in_full(), test_a_partly_verified_report_pays_half(), test_a_denied_report_is_rejected_without_asking_the_human(), test_deliver_twice_is_refused(), test_status_reads_back_the_run(), test_checker_output_becomes_one_item_per_checkable_criterion()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(e) => {
        let __p := io.print(str.concat("FAIL: ", e))
        n + 1
      },
    }
  })
  if failures == 0 {
    io.print("ok   tests/test_consortium.lex (9 tests)")
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

