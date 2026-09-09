# economy_procurement.lex -- build, buy or defer (#398, piece 5).
#
# The strategy calls build-vs-buy "the central intelligence test". The first
# version is a deterministic rule with its reasons written down, so a company's
# choice is reproducible from the trail and never an LLM's mood:
#
#   1. The company sells the capability itself and its internal estimate fits
#      the available funds            -> Build.
#   2. Otherwise the cheapest bid whose supplier meets min_trust and whose price
#      fits the available funds -- and, when the company could build, is below
#      the internal estimate         -> Buy(bid).
#   3. Nothing eligible               -> Defer, saying why.
#
# Pure. The caller records the decision as a trail event and, on Buy, awards
# the bid through lex-economy.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-economy/src/capability" as capability

import "lex-economy/src/request_bid" as request_bid

type Decision = Build | Buy(request_bid.Bid) | Defer

type Reasoned = { decision :: Decision, reason :: Str }

fn sells(own :: List[capability.Offer], cap :: Str) -> Bool {
  list.fold(own, false, fn (f :: Bool, o :: capability.Offer) -> Bool {
    f or o.capability == cap
  })
}

fn cheapest(bids :: List[request_bid.Bid]) -> Option[request_bid.Bid] {
  list.fold(bids, None, fn (best :: Option[request_bid.Bid], b :: request_bid.Bid) -> Option[request_bid.Bid] {
    match best {
      None => Some(b),
      Some(x) => if b.price.cents < x.price.cents {
        Some(b)
      } else {
        best
      },
    }
  })
}

fn decide(cap :: Str, own :: List[capability.Offer], bids :: List[request_bid.Bid], internal_estimate_cents :: Int, available_cents :: Int, min_trust_bp :: Int, supplier_trust_bp :: (Str) -> Int) -> Reasoned {
  let can_build := sells(own, cap)
  if can_build and internal_estimate_cents <= available_cents {
    { decision: Build, reason: str.join(["internal capability ", cap, "; estimate ", int.to_str(internal_estimate_cents), "c within ", int.to_str(available_cents), "c available"], "") }
  } else {
    let eligible := list.filter(bids, fn (b :: request_bid.Bid) -> Bool {
      b.state == request_bid.BidSubmitted and b.price.cents <= available_cents and supplier_trust_bp(b.supplier) >= min_trust_bp and (not can_build or b.price.cents < internal_estimate_cents)
    })
    match cheapest(eligible) {
      Some(b) => { decision: Buy(b), reason: str.join(["buy from ", b.supplier, " at ", int.to_str(b.price.cents), "c (", if can_build {
        str.join(["below the internal estimate of ", int.to_str(internal_estimate_cents), "c"], "")
      } else {
        "no internal capability"
      }, "; trust >= ", int.to_str(min_trust_bp), "bp)"], "") },
      None => { decision: Defer, reason: str.join(["defer ", cap, ": ", if can_build {
        str.join(["internal estimate ", int.to_str(internal_estimate_cents), "c exceeds ", int.to_str(available_cents), "c available"], "")
      } else {
        "no internal capability"
      }, " and no eligible bid (", int.to_str(list.len(bids)), " bid(s): none within funds, trusted and cheaper)"], "") },
    }
  }
}

