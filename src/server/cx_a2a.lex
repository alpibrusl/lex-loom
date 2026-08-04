# server/cx_a2a.lex — CX's read-only support-item fetch, exposed as a real
# A2A skill (SA2, lex-loom#179 — soft-os-aware-agents.md).
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
# Mount with lex-agent/src/mount.lex onto a lex-web router (see serve_cx_a2a
# below for the runnable entry point). Single-process mode: call
# dispatch_request(agent_def, body) directly.

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "std.net" as net

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-spec/capability" as cap

import "lex-web/router" as router

import "lex-agent/src/mount" as agent_mount

import "../roles" as roles

# ── Skill: fetch_support_items ────────────────────────────────────────────────
fn skill_fetch_support_items() -> srv.Skill {
  let params := { title: "FetchSupportItems", description: "Read items needing a human response from a company's live /loom/support endpoint", fields: [s.required_str("url", [])] }
  { capability: cap.inbound("support.fetch_items", "GET `url` + \"/loom/support\" and return {items:[{id,text,status}]} or {error}. Read-only.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
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
  let agent_card := card.make("loom-cx", "Read-only customer-support triage: fetches open support items for a company's own /loom/support endpoint.", "0.1.0", base_url, [sk.capability])
  srv.make_agent_def(agent_card, [sk])
}

# ── Helpers (mirrors server/a2a.lex's own) ─────────────────────────────────────
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

# ── Entry point ───────────────────────────────────────────────────────────────
# Run it:
#   lex run --allow-effects env,net,io,time,crypto,random,sql,fs_read,fs_write,concurrent,llm,proc \
#     src/server/cx_a2a.lex serve_cx_a2a
#
# Env:
#   PORT       HTTP listen port                 (default: 9200)
#   BASE_URL   this agent's own public base URL  (default: http://localhost:<PORT>)
fn serve_cx_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc] Unit {
  let port := match str.to_int(env_or("PORT", "9200")) {
    Some(n) => n,
    None => 9200,
  }
  let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
  let agent := make_cx_agent(base_url)
  let r := agent_mount.mount(router.new(), agent)
  let __p1 := io.print("=== lex-loom CX A2A server ===")
  let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
  let __p3 := io.print(str.concat("  base: ", base_url))
  net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let rsp := router.dispatch(r, raw)
    { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
  })
}

fn env_or(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => default,
  }
}

