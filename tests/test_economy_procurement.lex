# test_economy_procurement.lex -- build-vs-buy is a rule with reasons, not a
# mood (#398, piece 5).

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-economy/src/capability" as capability

import "lex-economy/src/request_bid" as request_bid

import "../src/economy_procurement" as proc

fn own_delivery() -> List[capability.Offer] {
  [{ capability: "software-delivery/v1", attrs: JObj([]) }]
}

fn bid(id :: Str, supplier :: Str, cents :: Int) -> request_bid.Bid {
  { id: id, request_id: "r", supplier: supplier, price: { cents: cents, currency: "EUR" }, message: "", state: request_bid.BidSubmitted }
}

fn trust_all(_s :: Str) -> Int {
  9000
}

fn trust_none(_s :: Str) -> Int {
  0
}

fn is_build(r :: proc.Reasoned) -> Bool {
  match r.decision {
    Build => true,
    _ => false,
  }
}

fn is_defer(r :: proc.Reasoned) -> Bool {
  match r.decision {
    Defer => true,
    _ => false,
  }
}

fn bought_from(r :: proc.Reasoned) -> Str {
  match r.decision {
    Buy(b) => b.supplier,
    _ => "",
  }
}

fn test_builds_when_it_can_and_can_afford_it() -> Result[Unit, Str] {
  let r := proc.decide("software-delivery/v1", own_delivery(), [bid("b1", "other", 10000)], 30000, 50000, 0, trust_all)
  if is_build(r) and str.contains(r.reason, "internal capability") {
    Ok(())
  } else {
    Err(str.concat("a company that sells the capability and can afford it did not Build: ", r.reason))
  }
}

fn test_buys_the_cheapest_trusted_bid_when_it_cannot_build() -> Result[Unit, Str] {
  let r := proc.decide("opportunity-research/v1", own_delivery(), [bid("b1", "researchco", 40000), bid("b2", "cheapco", 30000), bid("b3", "toorich", 90000)], 0, 50000, 0, trust_all)
  if bought_from(r) == "cheapco" and str.contains(r.reason, "no internal capability") {
    Ok(())
  } else {
    Err(str.concat("did not buy the cheapest affordable bid: ", r.reason))
  }
}

fn test_buys_when_a_trusted_bid_beats_an_unaffordable_internal_estimate() -> Result[Unit, Str] {
  let r := proc.decide("software-delivery/v1", own_delivery(), [bid("b1", "cheapco", 20000)], 60000, 50000, 0, trust_all)
  if bought_from(r) == "cheapco" and str.contains(r.reason, "below the internal estimate") {
    Ok(())
  } else {
    Err(str.concat("an unaffordable internal build was not replaced by a cheaper trusted bid: ", r.reason))
  }
}

fn test_defers_without_a_trusted_or_affordable_bid() -> Result[Unit, Str] {
  let untrusted := proc.decide("opportunity-research/v1", [], [bid("b1", "shady", 10000)], 0, 50000, 5000, trust_none)
  let unaffordable := proc.decide("opportunity-research/v1", [], [bid("b1", "fine", 80000)], 0, 50000, 0, trust_all)
  if is_defer(untrusted) and is_defer(unaffordable) and str.contains(unaffordable.reason, "no eligible bid") {
    Ok(())
  } else {
    Err(str.join(["did not defer: untrusted=", untrusted.reason, " | unaffordable=", unaffordable.reason], ""))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_builds_when_it_can_and_can_afford_it(), test_buys_the_cheapest_trusted_bid_when_it_cannot_build(), test_buys_when_a_trusted_bid_beats_an_unaffordable_internal_estimate(), test_defers_without_a_trusted_or_affordable_bid()]
}

fn run_all() -> Unit {
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

