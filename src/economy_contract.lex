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

# Evidence from a checker's own output: bin/check_research_report.py and
# bin/check_software_delivery.py print `<NAME>_VERIFIED <attr> ...` naming
# every criterion they verified (on a refusal too), so a checkable criterion
# is satisfied exactly when its attr is on such a line; `<NAME>_OK ...` on a
# full pass counts the same way. No line means nothing verified. Human
# criteria get nothing here.
# A checker's verified line: its first token ends in _VERIFIED or _OK
# (RESEARCH_REPORT_VERIFIED, SOFTWARE_DELIVERY_OK, ...).
fn is_checker_line(line :: Str) -> Bool {
  match list.head(str.split(line, " ")) {
    None => false,
    Some(tok) => str.ends_with(tok, "_VERIFIED") or str.ends_with(tok, "_OK"),
  }
}

fn evidence_from_checker(criteria :: List[request_bid.Criterion], checker_output :: Str) -> List[evidence.EvidenceItem] {
  let verified := list.fold(str.split(checker_output, "\n"), [], fn (acc :: List[Str], line :: Str) -> List[Str] {
    if is_checker_line(str.trim(line)) {
      list.concat(acc, str.split(str.trim(line), " "))
    } else {
      acc
    }
  })
  list.fold(criteria, [], fn (acc :: List[evidence.EvidenceItem], c :: request_bid.Criterion) -> List[evidence.EvidenceItem] {
    if is_human(c.attr) {
      acc
    } else {
      let hit := not list.is_empty(list.filter(verified, fn (v :: Str) -> Bool {
        v == c.attr
      }))
      list.concat(acc, [{ attr: c.attr, satisfied: hit, note: if hit {
        "on the buyer's checker line (re-derived, not the supplier's word)"
      } else {
        str.concat("not on the checker's verified line: ", str.slice(str.trim(checker_output), 0, 300))
      } }])
    }
  })
}

# The founder's answer to a human criterion, as one evidence item.
fn human_answer_item(attr :: Str, yes :: Bool, note :: Str) -> evidence.EvidenceItem {
  { attr: attr, satisfied: yes, note: note }
}

# Awarded -> InProgress -> Delivered -> Verified(verdict) from explicit
# evidence items (the checker's, plus any human answers already given).
fn verify_with_evidence(c :: contract.Contract, criteria :: List[request_bid.Criterion], items :: List[evidence.EvidenceItem]) -> Result[contract.Contract, Str] {
  match contract.transition(c, contract.WasStarted) {
    Err(e) => Err(e),
    Ok(started) => match contract.transition(started, contract.WasDelivered) {
      Err(e) => Err(e),
      Ok(delivered) => contract.transition(delivered, contract.WasVerified(evidence.evaluate(criteria, items))),
    },
  }
}

# Awarded -> InProgress -> Delivered -> Verified(v) with a verdict already
# decided from the evidence (a delivery meeting no checkable criterion is
# Rejected on that half alone; the human criterion stays unassessed).
fn verify_with_verdict(c :: contract.Contract, v :: contract.Verdict) -> Result[contract.Contract, Str] {
  match contract.transition(c, contract.WasStarted) {
    Err(e) => Err(e),
    Ok(started) => match contract.transition(started, contract.WasDelivered) {
      Err(e) => Err(e),
      Ok(delivered) => contract.transition(delivered, contract.WasVerified(v)),
    },
  }
}

# A contract held Verified(Ambiguous) is re-verified once the human has
# answered: back to Delivered (the delivery stands), then WasVerified with
# the fuller evidence. Any other state is refused -- a settled or disputed
# contract is not reopened by a late answer.
fn reverify_after_answer(c :: contract.Contract, criteria :: List[request_bid.Criterion], items :: List[evidence.EvidenceItem]) -> Result[contract.Contract, Str] {
  match c.state {
    Verified(Ambiguous(_)) => contract.transition(contract.with_state(c, contract.Delivered), contract.WasVerified(evidence.evaluate(criteria, items))),
    _ => Err("only a contract held Ambiguous takes a human answer"),
  }
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

