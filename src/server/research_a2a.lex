# server/research_a2a.lex — the research role's web_search, exposed as a
# real A2A skill (SA4, lex-loom#181 — soft-os-aware-agents.md).
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

# ── Skill: web_search ─────────────────────────────────────────────────────────
fn skill_web_search() -> srv.Skill {
  let params := { title: "WebSearch", description: "Search the public web (DuckDuckGo) and return result titles + snippets", fields: [s.required_str("query", [])] }
  { capability: cap.inbound("research.web_search", "Search the web for `query`. Returns {results} or {error}. Read-only — keyless DuckDuckGo lookup, no write path.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
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
  let agent_card := card.make("loom-research", "Keyless competitive/market web search for one company's own research role.", "0.1.0", base_url, [sk.capability])
  srv.make_agent_def(agent_card, [sk])
}

# ── Helpers (mirrors server/cx_a2a.lex's own) ───────────────────────────────────
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
#     src/server/research_a2a.lex serve_research_a2a
#
# Env:
#   PORT       HTTP listen port                 (default: 9300)
#   BASE_URL   this agent's own public base URL  (default: http://localhost:<PORT>)
fn serve_research_a2a() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc] Unit {
  let port := match str.to_int(env_or("PORT", "9300")) {
    Some(n) => n,
    None => 9300,
  }
  let base_url := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
  let agent := make_research_agent(base_url)
  let r := agent_mount.mount(router.new(), agent)
  let __p1 := io.print("=== lex-loom research A2A server ===")
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

