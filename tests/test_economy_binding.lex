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

import "lex-economy/src/capability" as capability

import "lex-economy/src/contract" as contract

import "lex-economy/src/request_bid" as request_bid

import "lex-economy/src/settlement" as settlement

import "../src/economy_contract" as ec

import "std.int" as int

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

fn has_capability(offers :: List[capability.Offer], name :: Str) -> Bool {
  list.fold(offers, false, fn (f :: Bool, o :: capability.Offer) -> Bool {
    f or o.capability == name
  })
}

fn test_offers_follow_packs_and_path() -> Result[Unit, Str] {
  let py := eb.offers_for(["core"], "python-fastapi")
  let lx := eb.offers_for(["core", "content", "finance"], "lex-x402-api")
  let none := eb.offers_for(["core"], "")
  if has_capability(py, "software-delivery/v1") and list.len(py) == 1 and has_capability(lx, "software-delivery/v1") and has_capability(lx, "content-drafting/v1") and has_capability(lx, "pricing-and-economics/v1") and list.is_empty(none) {
    Ok(())
  } else {
    Err(str.join(["capability mapping is off: py=", int.to_str(list.len(py)), " lex=", int.to_str(list.len(lx)), " none=", int.to_str(list.len(none))], ""))
  }
}

fn test_declared_capabilities_are_findable() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match eb.declare_capabilities(db, "softwareco", ["core"], "python-fastapi") {
      Err(e) => Err(e),
      Ok(_) => match eb.declare_capabilities(db, "softwareco", ["core"], "python-fastapi") {
        Err(e) => Err(str.concat("declaring twice failed: ", e)),
        Ok(_) => match eb.declare_capabilities(db, "researchco", ["core", "content"], "") {
          Err(e) => Err(e),
          Ok(_) => {
            let matches := capability.find(eb.company_offers(db), capability.exact_query("software-delivery/v1"))
            let names := list.map(matches, fn (m :: capability.Match) -> Str {
              m.company
            })
            if names == ["softwareco"] {
              Ok(())
            } else {
              Err(str.concat("find did not return exactly softwareco for software-delivery/v1: ", str.join(names, ",")))
            }
          },
        },
      },
    }
  })
}

# NEGATIVE CONTROL for lex-economy#3: settlement debits the buyer but credits
# nobody (no treasury credit exists at 2673b8b), so the supplier's balance
# after a fulfilled 40 000c contract is 0 today. When lex-economy conserves
# money this returns 40000 and this pin must change -- that flip is the
# point of pinning it.
fn supplier_balance_lex_economy_gives_today() -> Int {
  0
}

fn crit(attr :: Str, d :: Str) -> request_bid.Criterion {
  { attr: attr, description: d }
}

# Runs the whole loop through lex-economy: request -> bid -> award ->
# contract (commitment) -> sprint outcome -> evidence -> verdict -> settle.
fn run_contract(db :: conn.ConnDb, log :: tlog.Log, tag :: Str, criteria :: List[request_bid.Criterion], success :: Bool) -> [sql, fs_read, fs_write, time, random, crypto] Result[(contract.Contract, treasury.Treasury, treasury.Treasury), Str] {
  let buyer := str.concat("buyer-", tag)
  let supplier := str.concat("supplier-", tag)
  match eb.ensure_treasury(db, buyer, "EUR", 100000) {
    Err(e) => Err(e),
    Ok(_) => match eb.ensure_treasury(db, supplier, "EUR", 0) {
      Err(e) => Err(e),
      Ok(_) => {
        let req := request_bid.post_request(str.concat("req-", tag), buyer, "opportunity-research/v1", "Find one micro-product opportunity", { cents: 50000, currency: "EUR" }, criteria, 9999999999999)
        match request_bid.submit_bid(req, str.concat("bid-", tag), supplier, { cents: 40000, currency: "EUR" }, "report in 90 minutes", 1) {
          Err(e) => Err(str.concat("bid: ", e)),
          Ok(bid) => match request_bid.award(req, [bid], bid.id) {
            Err(e) => Err(str.concat("award: ", e)),
            Ok((req2, bids)) => match list.head(bids) {
              None => Err("no bids after award"),
              Some(won) => match settlement.open_contract(db.handle, log, req2, won, str.concat("c-", tag), str.concat("commit-", tag)) {
                Err(e) => Err(str.concat("open_contract: ", e)),
                Ok(c) => match ec.deliver_and_verify(c, criteria, success, "loom acceptance re-executed the sealed artifact") {
                  Err(e) => Err(str.concat("deliver: ", e)),
                  Ok(verified) => match ec.settle_if_decided(db, log, verified, str.concat("commit-", tag)) {
                    Err(e) => Err(str.concat("settle: ", e)),
                    Ok(final) => match treasury.get_treasury(db.handle, buyer) {
                      Ok(Some(b)) => match treasury.get_treasury(db.handle, supplier) {
                        Ok(Some(sp)) => Ok((final, b, sp)),
                        _ => Err("supplier treasury vanished"),
                      },
                      _ => Err("buyer treasury vanished"),
                    },
                  },
                },
              },
            },
          },
        }
      },
    },
  }
}

fn test_a_human_criterion_holds_the_contract_ambiguous() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => match run_contract(db, log, "amb", [crit("checkable:report-present", "the report exists"), crit("human:would-fund", "would you fund it?")], true) {
        Err(e) => Err(e),
        Ok((c, buyer, supplier)) => match c.state {
          Verified(Ambiguous(names)) => if names == ["human:would-fund"] and buyer.committed_cents == 40000 and supplier.balance_cents == 0 {
            Ok(())
          } else {
            Err(str.join(["ambiguous, but the funds moved or the wrong criterion was unassessed: committed=", int.to_str(buyer.committed_cents), " supplier=", int.to_str(supplier.balance_cents)], ""))
          },
          _ => Err("a contract with an unanswered human criterion was not held Ambiguous -- the machine filled in the human's half"),
        },
      },
    }
  })
}

fn test_checkable_criteria_settle_on_looms_verdict() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  with_db(fn (db :: conn.ConnDb) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
    match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => match run_contract(db, log, "ok", [crit("checkable:report-present", "the report exists"), crit("checkable:three-alternatives", "at least three alternatives")], true) {
        Err(e) => Err(e),
        Ok((c, buyer, supplier)) => if c.state == contract.Settled and buyer.committed_cents == 0 and buyer.balance_cents == 60000 and supplier.balance_cents == supplier_balance_lex_economy_gives_today() {
          match run_contract(db, log, "rej", [crit("checkable:report-present", "the report exists")], false) {
            Err(e) => Err(str.concat("rejected flow: ", e)),
            Ok((c2, b2, s2)) => if s2.balance_cents == 0 and b2.committed_cents == 0 and b2.balance_cents == 100000 {
              Ok(())
            } else {
              Err("a rejected delivery moved money or kept the commitment")
            },
          }
        } else {
          Err(str.join(["a fulfilled contract did not settle: state ok=", if c.state == contract.Settled {
            "yes"
          } else {
            "no"
          }, " supplier=", int.to_str(supplier.balance_cents), " buyer_committed=", int.to_str(buyer.committed_cents)], ""))
        },
      },
    }
  })
}

fn test_the_goal_carries_the_criteria_and_marks_the_human_ones() -> Result[Unit, Str] {
  let req := request_bid.post_request("r", "b", "opportunity-research/v1", "Find an opportunity", { cents: 1, currency: "EUR" }, [crit("checkable:report-present", "the report exists"), crit("human:would-fund", "would you fund it?")], 1)
  let g := ec.goal_from_request(req)
  if str.starts_with(g, "Find an opportunity") and str.contains(g, "- checkable:report-present: the report exists") and str.contains(g, "[answered by a human, not by you] human:would-fund") {
    Ok(())
  } else {
    Err(str.concat("the sprint goal does not carry the contract's criteria as agreed: ", g))
  }
}

fn suite() -> [sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_a_company_gets_a_treasury_on_looms_own_handle(), test_ensure_treasury_is_idempotent(), test_a_commitment_reserves_and_an_overcommit_is_refused(), test_company_start_funds_the_treasury_from_the_total_envelope(), test_offers_follow_packs_and_path(), test_declared_capabilities_are_findable(), test_a_human_criterion_holds_the_contract_ambiguous(), test_checkable_criteria_settle_on_looms_verdict(), test_the_goal_carries_the_criteria_and_marks_the_human_ones()]
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

