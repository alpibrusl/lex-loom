# server/cx_a2a.lex — CX's read-only support-item fetch, exposed as a real
# A2A skill (SA2, lex-loom#179 — soft-os-aware-agents.md), gated behind a
# shared-secret bearer token (lex-loom#193).
#
# `roles.cx_agent`'s only tool (`roles.make_fetch_support_tool`) is already
# real and tested (`tests/test_cx_tool.lex`) — a GET against a company's own
# `/loom/support` endpoint, no write path anywhere. This wraps the exact same
# `roles.fetch_support_items` call as an A2A `Skill`, so a remote mesh peer
# can ask "what support items are open for this company" the same way an
# in-sprint CX agent would — deliberately the SAME capability, not a smarter
# one: SA2 is about the mesh-registration/discovery/reachability plumbing,
# not about growing what CX can do.
#
# Read-only isn't the same as harmless-to-expose: this was left
# unauthenticated when first built, but there's no reason a caller with no
# mesh-relationship credentials should be able to invoke it at all — so
# CX_API_TOKEN gates every POST / the same way content_a2a.lex's
# CONTENT_PUBLISH_TOKEN already gates publish_content (#187). CX_API_TOKEN
# unset means this agent refuses to serve at all — never fail-open into an
# effectively-unauthenticated endpoint. (fetch_support_items also takes a
# fully caller-supplied `url` with no scoping to the calling company's own
# product — tracked separately as lex-loom#194, since a naive
# host/IP restriction would break the legitimate localhost/private-network
# deployment case this project's demos rely on.)
#
# Mount with lex-agent/src/mount.lex onto a lex-web router (see serve_cx_a2a
# below for the runnable entry point). Single-process mode: call
# dispatch_request(agent_def, body) directly.

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "std.net" as net

import "std.list" as list

import "std.crypto" as crypto

import "std.bytes" as bytes

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-spec/capability" as cap

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-web/body" as wbody

import "../roles" as roles

# ── Skill: fetch_support_items ────────────────────────────────────────────────
fn skill_fetch_support_items() -> srv.Skill {
  let params := { title: "FetchSupportItems", description: "Read items needing a human response from a company's live /loom/support endpoint", fields: [s.required_str("url", [])] }
  { capability: cap.inbound("support.fetch_items", "GET `url` + \"/loom/support\" and return {items:[{id,text,status}]} or {error}. Read-only. Requires Authorization: Bearer <CX_API_TOKEN>.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let url := str_field(msg_to_json(m), "url")
    if str.is_empty(url) {
      error_outcome("url is required")
    } else {
      ok_outcome(jv.stringify(roles.fetch_support_items(url)))
    }
  } }
}

# ── AgentDef factory ──────────────────────────────────────────────────────────
fn make_cx_agent(base_url :: Str) -> srv.AgentDef {
  let sk := skill_fetch_support_items()
  let agent_card := card.make("loom-cx", "Token-gated, read-only customer-support triage: fetches open support items for a company's own /loom/support endpoint. See CX_API_TOKEN.", "0.1.0", base_url, [sk.capability])
  srv.make_agent_def(agent_card, [sk])
}

# ── Helpers (mirrors server/content_a2a.lex / server/research_a2a.lex) ───────
fn msg_to_json(m :: msg.Message) -> jv.Json {
  let text := match list.head(m.parts) {
    None => "{}",
    Some(TextPart(s)) => s,
    Some(DataPart(j)) => jv.stringify(j),
    Some(_) => "{}",
  }
  match jv.parse(text) {
    Ok(j) => j,
    Err(_) => JObj([]),
  }
}

fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn ok_outcome(body :: Str) -> srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(body)), artifacts: [] }
}

fn error_outcome(reason :: Str) -> srv.HandlerOutcome {
  { next_state: TSFailed, reply: Some(msg.agent_text(str.concat("{\"error\":\"", str.concat(reason, "\"}")))), artifacts: [] }
}

# ── Token gate (mirrors server/content_a2a.lex exactly) ──────────────────────
# Constant-time compare — never a plain `==` on caller-controlled input.
fn token_matches(presented :: Str, expected :: Str) -> Bool {
  if str.is_empty(presented) or str.is_empty(expected) {
    false
  } else {
    crypto.constant_time_eq(bytes.from_str(presented), bytes.from_str(expected))
  }
}

fn is_authorized(c :: ctx.Ctx, expected_token :: Str) -> Bool {
  match ctx.bearer_token(c) {
    None => false,
    Some(presented) => token_matches(presented, expected_token),
  }
}

# The gated POST / route: checks the bearer token before ever touching
# `srv.dispatch_request`/`dispatch_subscribe_str` — an unauthorized caller
# never reaches the skill, never reaches `fetch_support_items`. Mirrors
# content_a2a.lex's `gated_rpc_route` exactly, including sendSubscribe
# support (this agent was already AG-UI-streamable via the plain
# `agent_mount.mount()`'s auto-detection; gating must not regress that).
fn gated_rpc_route(agent :: srv.AgentDef, expected_token :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    if is_authorized(c, expected_token) {
      let body_str := wbody.raw_body(c)
      if srv.is_subscribe_body(body_str) {
        let sse_body := srv.dispatch_subscribe_str(agent, body_str)
        { status: 200, body: sse_body, headers: map.from_list([("content-type", "text/event-stream"), ("cache-control", "no-cache"), ("connection", "keep-alive")]) }
      } else {
        resp.json(srv.dispatch_request(agent, body_str))
      }
    } else {
      resp.unauthorized("missing or invalid Authorization: Bearer <token>")
    }
  }
}

fn card_route(agent :: srv.AgentDef) -> (ctx.Ctx) -> resp.Response {
  fn (_c :: ctx.Ctx) -> resp.Response {
    resp.json(srv.agent_card_response(agent))
  }
}

# Mirrors lex-agent/src/mount.lex's mount() exactly, except POST / goes
# through gated_rpc_route instead of the ungated rpc_route — the discovery
# card (GET /.well-known/agent.json) stays open, same as any other agent's
# public metadata; only the actual skill invocation is gated.
fn mount_gated(r :: router.Router, agent :: srv.AgentDef, expected_token :: Str) -> router.Router {
  let with_card := router.route(r, "GET", "/.well-known/agent.json", card_route(agent))
  router.route_effectful(with_card, "POST", "/", gated_rpc_route(agent, expected_token))
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Run it:
#   CX_API_TOKEN=<a real secret> \
#   lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc \
#     src/server/cx_a2a.lex serve_cx_a2a
#
# Env:
#   PORT          HTTP listen port                 (default: 9200)
#   BASE_URL      this agent's own public base URL  (default: http://localhost:<PORT>)
#   CX_API_TOKEN  required — no default, no fallback. Unset refuses to
#                 start rather than silently serving unauthenticated.
fn serve_cx_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc] Unit {
  let token := env_or("CX_API_TOKEN", "")
  if str.is_empty(token) {
    io.print("[cx-a2a] FATAL: CX_API_TOKEN is required — refusing to serve an unauthenticated fetch_support_items endpoint")
  } else {
    let port := match str.to_int(env_or("PORT", "9200")) {
      Some(n) => n,
      None => 9200,
    }
    let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
    let agent := make_cx_agent(base_url)
    let r := mount_gated(router.new(), agent, token)
    let __p1 := io.print("=== lex-loom CX A2A server (token-gated) ===")
    let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
    let __p3 := io.print(str.concat("  base: ", base_url))
    net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
      let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
      let rsp := router.dispatch(r, raw)
      { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
    })
  }
}

fn env_or(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => default,
  }
}

