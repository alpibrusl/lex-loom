# Application entry point -- the golden-path skeleton for `lex-web-api`.
#
# Pick this path for a Lex HTTP API that is NOT priced per call: lex-web is
# the FastAPI of Lex -- declarative routes, typed path/query params, form and
# JSON bodies, body limits, CORS, OpenAPI export, and an effect-aware testing
# surface (see tests/). Pick `lex-x402-api` when the API charges per call via
# x402; pick `python-fastapi` only when a Python dependency is the point.
#
# Reads PORT from the environment so the loom `launch` node can boot it on
# any port. Build agents EXTEND this file (add routes to app(), add std.sql
# persistence, add middleware) rather than inventing a fresh layout.
#
# Run:  PORT=8080 lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc,approval main.lex main
# Try:  curl -i localhost:8080/health
#       curl -i -d 'name=Ada&email=ada@example.eu' localhost:8080/submit

import "std.net" as net

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.map" as map

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/router" as router

import "lex-web/src/body" as body

import "lex-web/src/middleware" as mw

# The largest request body this API accepts, enforced by middleware before
# any handler runs. A public POST endpoint without a cap is the first thing
# an abuse checker refuses.
fn max_body_bytes() -> Int {
  65536
}

fn health(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"ok\":true}")
}

# EXTEND this: the example public POST route. Accepts a urlencoded form
# (what a static site's <form action> sends) or JSON, requires the fields
# it declares, and answers a browser with a redirect and an API client with
# JSON. A build agent replaces the echo with real persistence and keeps the
# shape: validate, then store, then redirect or respond.
fn submit(c :: ctx.Ctx) -> resp.Response {
  let fields := if body.is_form(c) {
    body.form_body_raw(c)
  } else {
    map.new()
  }
  match map.get(fields, "email") {
    None => resp.bad_request("email is required"),
    Some(email) => {
      let name := match map.get(fields, "name") {
        Some(n) => n,
        None => "",
      }
      match ctx.query_param(c, "next") {
        Some(next) => resp.redirect(next),
        None => resp.json(str.join(["{\"ok\":true,\"email\":\"", json_escape(email), "\",\"name\":\"", json_escape(name), "\"}"], "")),
      }
    },
  }
}

fn json_escape(s :: Str) -> Str
  examples {
    json_escape("plain") => "plain",
    json_escape("a\"b") => "a'b"
  }
{
  str.replace(str.replace(str.replace(s, "\\", "/"), "\"", "'"), "\n", " ")
}

# The router is the app: every route, every middleware, in one place, so a
# test can dispatch against exactly what production serves.
fn app() -> router.Router {
  let r := router.use_mw(router.new(), mw.body_limit(max_body_bytes()))
  let r2 := router.route(r, "GET", "/health", health)
  router.route(r2, "POST", "/submit", submit)
}

fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
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

fn main() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  let p := port()
  let __banner := io.print(str.concat("lex-web-api listening on :", int.to_str(p)))
  net.serve_fn(p, handle)
}

