# server/a2a.lex — A2A HTTP front door for loom (§14).
#
# Exposes sprint controls as A2A capabilities so external agents
# (Claude Code, other lex-agent instances, LangGraph, CrewAI, …)
# can start, inspect, and advance sprints over standard JSON-RPC.
#
# Capabilities:
#   start    — start a new sprint given a request + model
#   status   — return current sprint phase, outcomes, success flag
#   trail    — return the last N trail events for a sprint
#   digest   — return lessons + tightened spec count from the Digest
#
# Mount with lex-agent/src/mount.lex onto a lex-web router.
# Single-process mode: call dispatch_request(agent_def, body) directly.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-spec/capability" as cap

import "../agent/trace" as trace

import "../graph" as graph

import "../migrate" as migrate

import "../digest" as dg

import "../tenant" as tenant

# ── Skill: start ──────────────────────────────────────────────────────────────
fn skill_start(db :: Db, model_default :: Str) -> srv.Skill {
  let params := { title: "StartSprint", description: "Start a new sprint", fields: [s.required_str("sprint_id", []), s.required_str("request", []), s.optional(s.required_str("model", []))] }
  { capability: cap.inbound("start", "Start a new loom sprint given a project request.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let args := msg_to_json(m)
    let sprint_id := str_field(args, "sprint_id")
    let request := str_field(args, "request")
    let model := str_field_or(args, "model", model_default)
    if str.is_empty(sprint_id) {
      error_outcome("sprint_id and request are required")
    } else {
      if str.is_empty(request) {
        error_outcome("sprint_id and request are required")
      } else {
        match migrate.run(db) {
          Err(e) => error_outcome(str.concat("migrate failed: ", e)),
          Ok(_) => {
            let __reg := tenant.register(db, sprint_id, request, "")
            ok_outcome(jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("status", JStr("started"))])))
          },
        }
      }
    }
  } }
}

# ── Skill: status ─────────────────────────────────────────────────────────────
fn skill_status(db :: Db) -> srv.Skill {
  let params := { title: "SprintStatus", description: "Get sprint status", fields: [s.required_str("sprint_id", [])] }
  { capability: cap.inbound("status", "Return the current state of a sprint.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let args := msg_to_json(m)
    let sprint_id := str_field(args, "sprint_id")
    if str.is_empty(sprint_id) {
      error_outcome("sprint_id is required")
    } else {
      match tenant.find(db, sprint_id) {
        None => error_outcome(str.concat("sprint not found: ", sprint_id)),
        Some(r) => ok_outcome(jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("status", JStr(r.status))]))),
      }
    }
  } }
}

# ── Skill: trail ──────────────────────────────────────────────────────────────
fn skill_trail(db :: Db) -> srv.Skill {
  let params := { title: "SprintTrail", description: "Fetch sprint trail events", fields: [s.required_str("sprint_id", []), s.optional(s.required_int("limit", []))] }
  { capability: cap.inbound("trail", "Return the last N trail events for a sprint.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let args := msg_to_json(m)
    let sprint_id := str_field(args, "sprint_id")
    if str.is_empty(sprint_id) {
      error_outcome("sprint_id is required")
    } else {
      let rows := dg.load_trail(db, sprint_id)
      let items := list.map(rows, fn (r :: dg.TrailRow) -> jv.Json {
        JObj([("kind", JStr(r.event_kind)), ("data", JStr(r.data_json)), ("ts", JStr(r.ts))])
      })
      ok_outcome(jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("events", JList(items)), ("count", JInt(list.len(items)))])))
    }
  } }
}

# ── Skill: digest ─────────────────────────────────────────────────────────────
fn skill_digest(db :: Db) -> srv.Skill {
  let params := { title: "SprintDigest", description: "Fetch Digest artifacts", fields: [s.required_str("sprint_id", [])] }
  { capability: cap.inbound("digest", "Return Digest lessons and tightened spec count.", params), handle: fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let args := msg_to_json(m)
    let sprint_id := str_field(args, "sprint_id")
    if str.is_empty(sprint_id) {
      error_outcome("sprint_id is required")
    } else {
      let specs := dg.load_tightened_specs(db, sprint_id)
      let seed := dg.load_seed_graph(db, sprint_id)
      let seed_json := match seed {
        None => JNull,
        Some(g) => graph.to_json(g),
      }
      ok_outcome(jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("tightened_specs", JInt(list.len(specs))), ("seed_graph", seed_json)])))
    }
  } }
}

# ── AgentDef factory ──────────────────────────────────────────────────────────
fn make_agent(db :: Db, model_default :: Str, base_url :: Str) -> srv.AgentDef {
  let skills := [skill_start(db, model_default), skill_status(db), skill_trail(db), skill_digest(db)]
  let skill_caps := list.map(skills, fn (sk :: srv.Skill) -> cap.Capability {
    sk.capability
  })
  let agent_card := card.make("loom", "Multi-agent sprint cycle orchestrator", "0.5.0", base_url, skill_caps)
  srv.make_agent_def(agent_card, skills)
}

# ── Helpers ───────────────────────────────────────────────────────────────────
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

fn str_field_or(j :: jv.Json, key :: Str, default :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => if str.is_empty(s) {
      default
    } else {
      s
    },
    _ => default,
  }
}

fn ok_outcome(body :: Str) -> srv.HandlerOutcome {
  { next_state: TSCompleted, reply: Some(msg.agent_text(body)), artifacts: [] }
}

fn error_outcome(reason :: Str) -> srv.HandlerOutcome {
  { next_state: TSFailed, reply: Some(msg.agent_text(str.concat("{\"error\":\"", str.concat(reason, "\"}")))), artifacts: [] }
}

