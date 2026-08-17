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
# effectively-unauthenticated endpoint.
#
# URL scoping (#194): the skill no longer trusts a caller-supplied `url`.
# Every fetch is bound to the ONE base URL this deployment is scoped to —
# either the operator-pinned CX_ALLOWED_URL, or the company's own
# registered Launch/Deploy URL derived from the company DB (the same
# derivation the operate loop's liveness checks trust). A caller may omit
# `url` entirely (the registered URL is used) or pass exactly that URL;
# anything else is refused. Deliberately NOT a private-IP/loopback
# blocklist — the legitimate use is exactly http://127.0.0.1:<port> in
# this project's single-host deployment model. See src/support_scope.lex.
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

import "../events" as events

import "../support_scope" as scope

# ── HB2 (#214): inbound support items are wake events ─────────────────────────
# When this server is configured with a company event ledger (LOOM_EVENTS_DB +
# LOOM_EVENTS_COMPANY), every open support item a fetch observes is projected
# into that company's append-only `events` table as a `support_item` event —
# deduped by the item's id, so polling the same items twice writes nothing new.
# The event stores the item's ID, never the customer's text: events are data
# for the scheduler's wake decision, not instruction for any prompt. A company
# whose wake_when doesn't declare `support_item` records the event and sleeps on.
fn record_support_events(ev_db :: Str, ev_cid :: Str, result :: jv.Json) -> [io, sql, fs_write, time] Unit {
  if str.is_empty(ev_db) or str.is_empty(ev_cid) {
    ()
  } else {
    match jv.get_field(result, "items") {
      Some(JList(items)) => {
        let __each := list.map(items, fn (item :: jv.Json) -> [io, sql, fs_write, time] Unit {
          let item_id := str_field(item, "id")
          if str.is_empty(item_id) {
            ()
          } else {
            match events.record_inbound_once(ev_db, str.join(["ev-support-", ev_cid, "-", item_id], ""), ev_cid, "support_item", "cx_a2a", str.join(["{\"item\":\"", item_id, "\"}"], "")) {
              Err(e) => io.print(str.concat("[cx-a2a] event ledger write failed: ", e)),
              Ok(_) => (),
            }
          }
        })
        ()
      },
      _ => (),
    }
  }
}

# ── Skill: fetch_support_items ────────────────────────────────────────────────
# `url` is now optional and scope-checked (#194): omitted means "the
# company's own registered URL"; present, it must equal that URL. The
# refusal message never echoes the allowed URL back to the caller — an
# out-of-scope probe learns only that it was out of scope.
fn skill_fetch_support_items(ev_db :: Str, ev_cid :: Str, allowed_override :: Str) -> srv.Skill {
  let params := { title: "FetchSupportItems", description: "Read items needing a human response from this company's own live /loom/support endpoint. `url` may be omitted (the company's registered URL is used); if present it must match that URL.", fields: [s.optional(s.required_str("url", []))] }
  { capability: cap.inbound("support.fetch_items", "GET the company's own registered base URL + \"/loom/support\" and return {items:[{id,text,status}]} or {error}. Read-only, scoped to this company's registered Launch/Deploy URL (#194). Requires Authorization: Bearer <CX_API_TOKEN>.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] srv.HandlerOutcome {
    let requested := str_field(msg_to_json(m), "url")
    match scope.resolve_allowed(allowed_override, ev_db, ev_cid) {
      Err(reason) => error_outcome(reason),
      Ok(allowed) => if scope.url_in_scope(requested, allowed) {
        let result := roles.fetch_support_items(allowed)
        let __ev := record_support_events(ev_db, ev_cid, result)
        ok_outcome(jv.stringify(result))
      } else {
        error_outcome("url is out of scope: this agent only fetches from the calling company's own registered product URL")
      },
    }
  } }
}

# ── AgentDef factory ──────────────────────────────────────────────────────────
fn make_cx_agent(base_url :: Str, ev_db :: Str, ev_cid :: Str, allowed_override :: Str) -> srv.AgentDef {
  let sk := skill_fetch_support_items(ev_db, ev_cid, allowed_override)
  let agent_card := card.make("loom-cx", "Token-gated, read-only customer-support triage: fetches open support items from a company's own registered /loom/support endpoint (URL-scoped, #194). See CX_API_TOKEN.", "0.1.0", base_url, [sk.capability])
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
#   CX_API_TOKEN=<a real secret> \
#   lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc,vcs,approval \
#     src/server/cx_a2a.lex serve_cx_a2a
#
# Env:
#   PORT          HTTP listen port                 (default: 9200)
#   BASE_URL      this agent's own public base URL  (default: http://localhost:<PORT>)
#   CX_API_TOKEN  required — no default, no fallback. Unset refuses to
#                 start rather than silently serving unauthenticated.
#   CX_ALLOWED_URL        optional — operator-pinned base URL the fetch is
#                         scoped to (#194). When unset, the scope is derived
#                         from the company DB below; when NEITHER is
#                         configured the server refuses to start.
#   LOOM_EVENTS_DB        path to a company DB. Two duties: the append-only
#                         `events` ledger records inbound support items
#                         (HB2), and the company's registered Launch/Deploy
#                         URL defines the fetch scope (#194).
#   LOOM_EVENTS_COMPANY   the company id for both of the above.
fn serve_cx_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval] Unit {
  let token := env_or("CX_API_TOKEN", "")
  let allowed_override := env_or("CX_ALLOWED_URL", "")
  let ev_db := env_or("LOOM_EVENTS_DB", "")
  let ev_cid := env_or("LOOM_EVENTS_COMPANY", "")
  if str.is_empty(token) {
    io.print("[cx-a2a] FATAL: CX_API_TOKEN is required — refusing to serve an unauthenticated fetch_support_items endpoint")
  } else {
    if str.is_empty(allowed_override) and (str.is_empty(ev_db) or str.is_empty(ev_cid)) {
      io.print("[cx-a2a] FATAL: no URL scope configured — set CX_ALLOWED_URL, or LOOM_EVENTS_DB + LOOM_EVENTS_COMPANY, so fetches are bound to the company's own product URL (#194); refusing to serve an unscoped fetch endpoint")
    } else {
      let port := match str.to_int(env_or("PORT", "9200")) {
        Some(n) => n,
        None => 9200,
      }
      let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
      let agent := make_cx_agent(base_url, ev_db, ev_cid, allowed_override)
      let r := mount_gated(router.new(), agent, token)
      let __p1 := io.print("=== lex-loom CX A2A server (token-gated) ===")
      let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
      let __p3 := io.print(str.concat("  base: ", base_url))
      net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Response {
        let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
        let rsp := router.dispatch(r, raw)
        { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
      })
    }
  }
}

fn env_or(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => default,
  }
}

