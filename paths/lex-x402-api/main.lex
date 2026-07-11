# Application entry point — the golden-path skeleton for `lex-x402-api`.
#
# Pick this path when the mission is a metered API that charges per call via
# the x402 protocol (Coinbase/x402 Foundation micropayments on Solana) —
# the ONLY real, tested payment-receiving rail loom has today (see
# ./payments.lex, which wraps lex-x402's real client/server modules rather
# than reimplementing the handshake). Pick `python-fastapi`/`python-flask`
# for a free/unpriced API.
#
# Reads PORT from the environment so the loom `launch` node can boot it on
# any port. Build agents EXTEND this file (add real routes + call
# payments.gate on the priced one) rather than inventing a fresh layout.

import "std.net" as net

import "std.env" as env

import "std.str" as str

import "std.int" as int

import "std.map" as map

import "./payments" as pay

type Request = { body :: Str, method :: Str, path :: Str, query :: Str, headers :: Map[Str, Str] }

type Response = { body :: Str, status :: Int, headers :: Map[Str, Str] }

fn json_response(status :: Int, body :: Str) -> Response {
  { status: status, body: body, headers: map.from_list([("content-type", "application/json")]) }
}

# EXTEND this: replace with the real priced endpoint's business logic. This
# stub only proves the gate wiring — a build agent's job is to put the
# actual feature behind `pay.gate`, matching this shape.
fn handle_priced_endpoint(req :: Request) -> [net, env] Response {
  let requirement := pay.requirement_env(str.concat(req.path, ""))
  let fac := pay.facilitator_env()
  match pay.gate(req.headers, requirement, fac) {
    Denied(resp) => { status: resp.status, body: resp.body, headers: resp.headers },
    Paid(_settlement, payment_response_header) => {
      let base := json_response(200, "{\"result\":\"replace me with the real feature\"}")
      { status: base.status, body: base.body, headers: map.set(base.headers, "PAYMENT-RESPONSE", payment_response_header) }
    },
  }
}

fn handle(req :: Request) -> [net, env] Response {
  match req.path {
    "/health" => json_response(200, "{\"ok\":true}"),
    _ => handle_priced_endpoint(req),
  }
}

fn port() -> [env] Int {
  match env.get("PORT") {
    Some(p) => match str.to_int(p) {
      Some(n) => n,
      None => 8080,
    },
    None => 8080,
  }
}

fn main() -> [net, env] Unit {
  net.serve_fn(port(), handle)
}

