# server/research_a2a.lex — the research role's web_search, exposed as a
# real A2A skill (SA4, lex-loom#181 — soft-os-aware-agents.md), gated
# behind a shared-secret bearer token (lex-loom#193).
#
# `roles.research_agent`'s only tool (`roles.make_web_search_tool`) is
# already real and tested (`tests/test_cx_tool.lex`'s
# test_missing_query_returns_clean_error) — a keyless DuckDuckGo lookup, no
# write path anywhere. This wraps the exact same `roles.fetch_web_search`
# call as an A2A `Skill`, mirroring `server/cx_a2a.lex` field for field: SA4
# is rollout of SA2's pattern to the rest of Distribution's read-only
# roles, not new mechanism. `content_creator`'s `publish_content` is
# deliberately NOT wrapped here — it's a real write to the product's live
# site, and exposing that to any mesh peer without an authorization design
# is exactly the "stop and reconsider" signal SA4's own issue calls out for
# a role that doesn't generalize cleanly; tracked separately, not silently
# skipped.
#
# Read-only isn't the same as harmless-to-expose: this was left
# unauthenticated when first built (below is bounded — the query is just
# search text against a fixed DuckDuckGo endpoint, unlike cx_a2a.lex's
# caller-controlled fetch target), but there's still no reason a caller
# with no mesh-relationship credentials should be able to invoke it at all
# — so RESEARCH_API_TOKEN gates every POST / the same way
# content_a2a.lex's CONTENT_PUBLISH_TOKEN already gates publish_content
# (#187). RESEARCH_API_TOKEN unset means this agent refuses to serve at
# all — never fail-open into an effectively-unauthenticated endpoint.

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

# ── Skill: web_search ─────────────────────────────────────────────────────────
fn skill_web_search() -> srv.Skill {
  let params := { title: "WebSearch", description: "Search the public web (DuckDuckGo) and return result titles + snippets", fields: [s.required_str("query", [])] }
  { capability: cap.inbound("research.web_search", "Search the web for `query`. Returns {results} or {error}. Read-only — keyless DuckDuckGo lookup, no write path. Requires Authorization: Bearer <RESEARCH_API_TOKEN>.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] srv.HandlerOutcome {
    let query := str_field(msg_to_json(m), "query")
    if str.is_empty(query) {
      error_outcome("query is required")
    } else {
      ok_outcome(jv.stringify(roles.fetch_web_search(query)))
    }
  } }
}

# ── AgentDef factory ──────────────────────────────────────────────────────────
fn make_research_agent(base_url :: Str) -> srv.AgentDef {
  let sk := skill_web_search()
  let agent_card := card.make("loom-research", "Token-gated, keyless competitive/market web search for one company's own research role. See RESEARCH_API_TOKEN.", "0.1.0", base_url, [sk.capability])
  srv.make_agent_def(agent_card, [sk])
}

# ── Helpers (mirrors server/content_a2a.lex / server/cx_a2a.lex) ─────────────
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
# never reaches the skill, never reaches `fetch_web_search`. Mirrors
# content_a2a.lex's `gated_rpc_route` exactly, including sendSubscribe
# support (this agent was already AG-UI-streamable via the plain
# `agent_mount.mount()`'s auto-detection; gating must not regress that).
fn gated_rpc_route(agent :: srv.AgentDef, expected_token :: Str) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
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
#   RESEARCH_API_TOKEN=<a real secret> \
#   lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc,approval \
#     src/server/research_a2a.lex serve_research_a2a
#
# Env:
#   PORT                HTTP listen port                 (default: 9300)
#   BASE_URL             this agent's own public base URL  (default: http://localhost:<PORT>)
#   RESEARCH_API_TOKEN   required — no default, no fallback. Unset refuses
#                        to start rather than silently serving unauthenticated.
fn serve_research_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  let token := env_or("RESEARCH_API_TOKEN", "")
  if str.is_empty(token) {
    io.print("[research-a2a] FATAL: RESEARCH_API_TOKEN is required — refusing to serve an unauthenticated web_search endpoint")
  } else {
    let port := match str.to_int(env_or("PORT", "9300")) {
      Some(n) => n,
      None => 9300,
    }
    let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
    let agent := make_research_agent(base_url)
    let r := mount_gated(router.new(), agent, token)
    let __p1 := io.print("=== lex-loom research A2A server (token-gated) ===")
    let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
    let __p3 := io.print(str.concat("  base: ", base_url))
    net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Response {
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

