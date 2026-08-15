# server/content_a2a.lex — content_creator's publish_content, exposed as a
# real A2A skill, gated behind a shared-secret bearer token (lex-loom#187,
# split out of SA4/#181 — soft-os-aware-agents.md).
#
# Unlike cx (SA2)/research (SA4), publish_content is a real write: it POSTs
# a blog post to the product's live site. soft_register.lex's own POST
# /peers self-registration is unauthenticated by default, and
# lex-agent/src/mount.lex's `mount()` never threads HTTP headers down into
# a Skill.handle — only the parsed A2A message body reaches it — so the
# gate can't live inside the skill itself; it has to sit one layer up, in
# a custom POST / route that checks `Authorization: Bearer <token>` BEFORE
# ever calling `srv.dispatch_request`. `crypto.constant_time_eq` is the
# same compare `lex-web`'s own `auth_basic.lex`/`auth_apikey.lex` already
# use for exactly this — avoids a timing side-channel a plain `==` string
# compare wouldn't.
#
# CONTENT_PUBLISH_TOKEN unset means this agent refuses to serve at all —
# never fail-open into an effectively-unauthenticated write.
#
# publish_content_core (src/roles.lex) is the exact same, already-tested
# logic the in-sprint LLM tool calls — this wraps it, it never
# reimplements it (the same discipline SA2/SA4 used for
# fetch_support_items/fetch_web_search).

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

import "../events" as events

# HB2 (#214): when configured with a company event ledger (LOOM_EVENTS_DB +
# LOOM_EVENTS_COMPANY), each inbound publish request appends one
# `content_request` event — the arrival is the event; the post's text stays
# out of the ledger (events are data, never instruction).
fn record_request_event(ev_db :: Str, ev_cid :: Str) -> [io, sql, fs_write, time, random, crypto] Unit {
  if str.is_empty(ev_db) or str.is_empty(ev_cid) {
    ()
  } else {
    match events.record_inbound(ev_db, ev_cid, "content_request", "content_a2a", "{}") {
      Err(e) => io.print(str.concat("[content-a2a] event ledger write failed: ", e)),
      Ok(_) => (),
    }
  }
}

# ── Skill: publish_content ────────────────────────────────────────────────────
fn skill_publish_content(ev_db :: Str, ev_cid :: Str) -> srv.Skill {
  let params := { title: "PublishContent", description: "Publish a blog post to the live product's own /loom/content endpoint", fields: [s.required_str("url", []), s.required_str("title", []), s.required_str("body", [])] }
  { capability: cap.inbound("content.publish", "POST {title, body} to `url` + \"/loom/content\". A real write — this endpoint requires Authorization: Bearer <CONTENT_PUBLISH_TOKEN>.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] srv.HandlerOutcome {
    let j := msg_to_json(m)
    let url := str_field(j, "url")
    let title := str_field(j, "title")
    let body := str_field(j, "body")
    if str.is_empty(url) or str.is_empty(title) or str.is_empty(body) {
      error_outcome("url, title, and body are all required")
    } else {
      let __ev := record_request_event(ev_db, ev_cid)
      ok_outcome(jv.stringify(roles.publish_content_core(url, title, body)))
    }
  } }
}

# ── AgentDef factory ──────────────────────────────────────────────────────────
fn make_content_agent(base_url :: Str, ev_db :: Str, ev_cid :: Str) -> srv.AgentDef {
  let sk := skill_publish_content(ev_db, ev_cid)
  let agent_card := card.make("loom-content", "Token-gated blog publishing for one company's own content_creator role. A real write — see CONTENT_PUBLISH_TOKEN.", "0.1.0", base_url, [sk.capability])
  srv.make_agent_def(agent_card, [sk])
}

# ── Helpers (mirrors server/cx_a2a.lex / server/research_a2a.lex) ────────────
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

# ── Token gate ─────────────────────────────────────────────────────────────────
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
# never reaches the skill, never reaches `publish_content_core`, never
# reaches the live site. Mirrors mount.lex's own `rpc_route` exactly for
# the `tasks/sendSubscribe` branch (same `is_subscribe_body` check, same
# SSE headers) so this agent is AG-UI-streamable the same way
# cx_a2a.lex/research_a2a.lex already are — an earlier version of this
# route only ever called `dispatch_request`, silently dropping
# sendSubscribe support relative to the two other A2A servers in this
# repo; publish_content's own turn is single-shot (no reason a caller
# would need to stream it), but there's no reason the gate itself should
# be the thing that breaks parity.
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
# through gated_rpc_route instead of the ungated rpc_route — the
# discovery card (GET /.well-known/agent.json) stays open, same as any
# other agent's public metadata; only the write path is gated.
fn mount_gated(r :: router.Router, agent :: srv.AgentDef, expected_token :: Str) -> router.Router {
  let with_card := router.route(r, "GET", "/.well-known/agent.json", card_route(agent))
  router.route_effectful(with_card, "POST", "/", gated_rpc_route(agent, expected_token))
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Run it:
#   CONTENT_PUBLISH_TOKEN=<a real secret> \
#   lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc,vcs,approval \
#     src/server/content_a2a.lex serve_content_a2a
#
# Env:
#   PORT                   HTTP listen port                 (default: 9301)
#   BASE_URL               this agent's own public base URL  (default: http://localhost:<PORT>)
#   CONTENT_PUBLISH_TOKEN   required — no default, no fallback. Unset refuses
#                           to start rather than silently serving unauthenticated.
#   LOOM_EVENTS_DB          optional — company DB whose `events` ledger records
#                           inbound requests (HB2). LOOM_EVENTS_COMPANY names
#                           the company; both must be set for ledger writes.
fn serve_content_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  let token := env_or("CONTENT_PUBLISH_TOKEN", "")
  if str.is_empty(token) {
    io.print("[content-a2a] FATAL: CONTENT_PUBLISH_TOKEN is required — refusing to serve an unauthenticated publish_content endpoint")
  } else {
    let port := match str.to_int(env_or("PORT", "9301")) {
      Some(n) => n,
      None => 9301,
    }
    let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
    let agent := make_content_agent(base_url, env_or("LOOM_EVENTS_DB", ""), env_or("LOOM_EVENTS_COMPANY", ""))
    let r := mount_gated(router.new(), agent, token)
    let __p1 := io.print("=== lex-loom content A2A server (token-gated) ===")
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

