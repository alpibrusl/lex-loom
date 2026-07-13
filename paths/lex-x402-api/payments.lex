# payments.lex — pre-written x402 payment gate for a priced endpoint.
#
# Build agents EXTEND main.lex but should call this AS-IS rather than
# reimplement the protocol handshake — the same "pre-supplied Dockerfile"
# philosophy as the rest of this golden path: protocol/crypto-correctness
# code is too easy for an LLM to get subtly wrong (wrong header name, wrong
# base64 layer, wrong verify-before-settle order), so it's provided as a
# tested library call instead of left to invention.
#
# Usage in a route handler:
#
#   import "./payments" as pay
#
#   fn convert(req :: Request) -> [net] Response {
#     match pay.gate(req, pay.requirement_env()) {
#       Denied(resp) => resp,
#       Paid(settlement, do_work) => do_work(),
#     }
#   }
#
# (`do_work` is a thunk so the real handler logic only runs once payment is
# confirmed -- this module never runs YOUR business logic, only the gate.)

import "std.str" as str

import "std.map" as map

import "std.env" as env

import "std.int" as int

import "lex-x402/src/types" as types

import "lex-x402/src/server" as x402srv

import "lex-x402/src/facilitator" as facilitator

# Header name lex-x402 expects the payer's signed retry on.
fn signature_header() -> Str {
  "PAYMENT-SIGNATURE"
}

# Read the priced-endpoint config from the environment, so a deployed
# instance is configured without editing code:
#   X402_PRICE_ATOMIC   -- price in the asset's smallest unit (e.g. USDC has
#                           6 decimals: "10000" = $0.01)
#   X402_PAY_TO         -- your Solana receiving address
#   X402_ASSET          -- the SPL token mint (e.g. USDC's mint address)
#   X402_NETWORK        -- default "solana-devnet" (safe -- can't receive
#                           real money); set to a mainnet CAIP-2 id
#                           (e.g. "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp")
#                           to go live
#   X402_FACILITATOR    -- base URL of the facilitator that verifies/settles
#                           (e.g. https://x402.org/facilitator)
#   X402_DESCRIPTION    -- human-readable line shown in the 402 challenge
fn requirement_env(resource_url :: Str) -> [env] types.Requirements {
  let price := match env.get("X402_PRICE_ATOMIC") {
    Some(v) => v,
    None => "10000",
  }
  let pay_to := match env.get("X402_PAY_TO") {
    Some(v) => v,
    None => "",
  }
  let asset := match env.get("X402_ASSET") {
    Some(v) => v,
    None => "",
  }
  let network := match env.get("X402_NETWORK") {
    Some(v) => v,
    None => "solana-devnet",
  }
  let description := match env.get("X402_DESCRIPTION") {
    Some(v) => v,
    None => "API call",
  }
  x402srv.build_requirement(price, resource_url, description, pay_to, network, asset, 60)
}

fn facilitator_env() -> [env] facilitator.Facilitator {
  let base := match env.get("X402_FACILITATOR") {
    Some(v) => v,
    None => "https://x402.org/facilitator",
  }
  facilitator.make(base)
}

# Case-insensitive header lookup -- servers/runtimes vary on header casing,
# same reasoning lex-x402's own client uses for response headers.
fn get_header_ci(headers :: Map[Str, Str], name :: Str) -> Option[Str] {
  match map.get(headers, name) {
    Some(v) => Some(v),
    None => match map.get(headers, str.to_lower(name)) {
      Some(v) => Some(v),
      None => map.get(headers, str.to_upper(name)),
    },
  }
}

type GateResult = Denied({ status :: Int, body :: Str, headers :: Map[Str, Str] }) | Paid((types.Settlement, Str))

fn gate(headers :: Map[Str, Str], requirement :: types.Requirements, fac :: facilitator.Facilitator) -> [net] GateResult {
  match get_header_ci(headers, signature_header()) {
    None => {
      let pr := x402srv.challenge([requirement])
      Denied({ status: 402, body: "{\"error\":\"payment required\"}", headers: map.from_list([("PAYMENT-REQUIRED", x402srv.challenge_header(pr)), ("content-type", "application/json")]) })
    },
    Some(sig) => match x402srv.charge(fac, sig, requirement) {
      Err(e) => Denied({ status: 402, body: str.join(["{\"error\":\"", e, "\"}"], ""), headers: map.from_list([("content-type", "application/json")]) }),
      Ok(settlement) => Paid(settlement, x402srv.encode_response_header(settlement)),
    },
  }
}

