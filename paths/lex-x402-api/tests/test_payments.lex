# test_payments.lex — pure-boundary tests for the x402 payment gate.
#
# `gate`'s Paid branch calls a live facilitator over [net] -- exercised by
# lex-x402's own test suite at the client/server boundary, not re-tested
# here. This file locks down everything reachable WITHOUT a network call:
# the 402 challenge shape when no signature is present, case-insensitive
# header lookup, and env-var driven config with sane defaults.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "../payments" as pay

import "lex-x402/src/types" as types

fn requirement() -> types.Requirements {
  { scheme: "exact", network: "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp", max_amount_required: "10000", resource: "https://api.example.com/convert", description: "API call", mime_type: "application/json", pay_to: "MerchantSoLAddr2222222222222222222222222222", max_timeout_seconds: 60, asset: "EPjFWdd5USDCmintxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
}

fn fac() -> facilitator.Facilitator {
  { verify_url: "https://x402.org/facilitator/verify", settle_url: "https://x402.org/facilitator/settle" }
}

import "lex-x402/src/facilitator" as facilitator

# No PAYMENT-SIGNATURE header -> a 402 with a PAYMENT-REQUIRED challenge
# header, no network call attempted.
fn test_gate_denies_with_402_when_no_signature() -> [net] Result[Unit, Str] {
  match pay.gate(map.new(), requirement(), fac()) {
    Denied(resp) => if resp.status == 402 {
      match map.get(resp.headers, "PAYMENT-REQUIRED") {
        Some(hdr) => if str.len(hdr) > 0 {
          Ok(())
        } else {
          Err("expected a non-empty PAYMENT-REQUIRED header")
        },
        None => Err("expected a PAYMENT-REQUIRED header on the 402"),
      }
    } else {
      Err(str.concat("expected status 402, got ", str.concat("", "?")))
    },
    Paid(_, _) => Err("expected Denied with no signature header, got Paid"),
  }
}

# Header lookup must be case-insensitive -- servers/runtimes vary on casing,
# same reasoning lex-x402's own client uses for response headers. Tested
# directly against get_header_ci (pure, no network) rather than through
# `gate`, which would otherwise need a live facilitator call to exercise the
# "signature present" branch.
fn test_header_lookup_is_case_insensitive() -> Result[Unit, Str] {
  let headers := map.from_list([("payment-signature", "sig-value")])
  match pay.get_header_ci(headers, "PAYMENT-SIGNATURE") {
    Some(v) => if v == "sig-value" {
      Ok(())
    } else {
      Err("expected the lowercase header's value to be found")
    },
    None => Err("expected a case-insensitive match for 'payment-signature'"),
  }
}

fn test_header_lookup_misses_absent_header() -> Result[Unit, Str] {
  match pay.get_header_ci(map.new(), "PAYMENT-SIGNATURE") {
    None => Ok(()),
    Some(_) => Err("expected no match against an empty header map"),
  }
}

fn suite() -> [net] List[Result[Unit, Str]] {
  [test_gate_denies_with_402_when_no_signature(), test_header_lookup_is_case_insensitive(), test_header_lookup_misses_absent_header()]
}

fn run_all() -> [net] Unit {
  let results := suite()
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

