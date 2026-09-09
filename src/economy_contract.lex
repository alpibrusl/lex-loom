# economy_contract.lex -- a contract becomes a sprint, and a sprint's verdict
# becomes the contract's evidence (#398, piece 4).
#
# Who assesses each criterion is decided by its attr: `human:<name>` is the
# founder's to answer and gets NO evidence from loom -- lex-economy's
# `evaluate` then returns Ambiguous, which holds the commitment until a
# person answers. Every other criterion is checkable and gets one evidence
# item carrying loom's own grounded verdict for the sprint (acceptance
# re-executed the sealed artifact, or did not) with its reason. The machine
# never fills in the human's half.
#
# Payment follows docs/consortium-freeze.md: 100% Fulfilled, 50%
# PartiallyFulfilled, 0% Rejected; Ambiguous is never settled here.

import "std.str" as str

import "std.list" as list

import "lex-orm/src/connection" as conn

import "lex-economy/src/contract" as contract

import "lex-economy/src/request_bid" as request_bid

import "lex-economy/src/evidence" as evidence

import "lex-economy/src/settlement" as settlement

import "lex-trail/src/log" as tlog

fn is_human(attr :: Str) -> Bool {
  str.starts_with(attr, "human:")
}

fn goal_from_request(req :: request_bid.WorkRequest) -> Str {
  let lines := list.map(req.criteria, fn (c :: request_bid.Criterion) -> Str {
    if is_human(c.attr) {
      str.join(["- [answered by a human, not by you] ", c.attr, ": ", c.description], "")
    } else {
      str.join(["- ", c.attr, ": ", c.description], "")
    }
  })
  str.join([req.description, "\n\nACCEPTANCE CRITERIA (from contract request ", req.id, "; the pipeline verifies these against the sealed artifact, and a human answers the ones marked so):\n", str.join(lines, "\n")], "")
}

fn evidence_from_sprint(criteria :: List[request_bid.Criterion], success :: Bool, summary :: Str) -> List[evidence.EvidenceItem] {
  list.fold(criteria, [], fn (acc :: List[evidence.EvidenceItem], c :: request_bid.Criterion) -> List[evidence.EvidenceItem] {
    if is_human(c.attr) {
      acc
    } else {
      list.concat(acc, [{ attr: c.attr, satisfied: success, note: summary }])
    }
  })
}

fn paid_cents_for(price_cents :: Int, v :: contract.Verdict) -> Int {
  match v {
    Fulfilled => price_cents,
    PartiallyFulfilled(_) => price_cents / 2,
    Rejected(_) => 0,
    Ambiguous(_) => 0,
  }
}

# Awarded -> InProgress -> Delivered -> Verified(verdict), all pure.
fn deliver_and_verify(c :: contract.Contract, criteria :: List[request_bid.Criterion], success :: Bool, summary :: Str) -> Result[contract.Contract, Str] {
  match contract.transition(c, contract.WasStarted) {
    Err(e) => Err(e),
    Ok(started) => match contract.transition(started, contract.WasDelivered) {
      Err(e) => Err(e),
      Ok(delivered) => {
        let v := evidence.evaluate(criteria, evidence_from_sprint(criteria, success, summary))
        contract.transition(delivered, contract.WasVerified(v))
      },
    },
  }
}

fn verdict_of(c :: contract.Contract) -> Option[contract.Verdict] {
  match c.state {
    Verified(v) => Some(v),
    _ => None,
  }
}

# Settle a verified contract by the freeze rule; an Ambiguous verdict is
# left exactly as it is (commitment reserved) for a human to resolve.
fn settle_if_decided(db :: conn.ConnDb, log :: tlog.Log, c :: contract.Contract, commitment_id :: Str) -> [sql, time] Result[contract.Contract, Str] {
  match verdict_of(c) {
    None => Err("not verified"),
    Some(v) => match v {
      Ambiguous(_) => Ok(c),
      _ => settlement.settle_contract(db.handle, log, c, commitment_id, paid_cents_for(c.price.cents, v)),
    },
  }
}

