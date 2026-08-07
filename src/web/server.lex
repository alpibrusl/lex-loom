# server.lex — lex-loom web dashboard.
#
# Endpoints:
#   GET  /                        — dashboard HTML (src/web/dashboard.html)
#   POST /api/sprints             — launch sprint, returns {sprint_id,success,summary}
#   GET  /api/sprint-status/*id   — phase transitions + trail count
#   GET  /api/sprint-trail/*id    — trail events as JSON
#   GET  /api/sprint-digest/*id   — tightened specs + seed-graph flag
#   GET  /api/sprint-graph/*id    — the sprint's node/edge graph
#   GET  /api/artifact/:hash      — a content-addressed artifact by hash
#   GET  /api/companies           — company list (id, stage, iteration count, incidents, spend)
#   GET  /api/companies/:id       — company detail: mission, stage, iterations, product
#                                    status, operate metrics, escalations, decisions
#
# *id routes are wildcards, not a single :id segment (#153): company
# iteration sprint ids are always "<company_id>/iter-N", which a plain
# :id segment can never match (the router requires wildcards to be the
# LAST pattern segment, so the action verb moved before the id instead of
# after it, e.g. /api/sprints/:id/status -> /api/sprint-status/*id).
# Run:
#   lex run --allow-effects env,net,io,llm,proc,sql,fs_read,fs_write,time,crypto,random,concurrent,vcs \
#     src/web/server.lex serve_loom
#
# Environment:
#   PORT    — HTTP port  (default: 8880)
#   DB_PATH — SQLite DB  (default: loom.db)
#   WEB_DIR — HTML dir   (default: src/web)

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "std.time" as time

import "std.sql" as sql

import "std.crypto" as crypto

import "std.bytes" as bytes

import "std.map" as map

import "lex-web/src/router" as router

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/static_files" as sf

import "lex-web/src/stream" as stream

import "std.iter" as iter

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "../migrate" as migrate

import "../orchestrator" as orch

import "../transport" as tr

import "../digest" as dg

import "../cast" as cast

import "../pool_seed" as pool_seed

import "../series" as ser

import "../company" as company

import "../operate_ledger" as oledger

import "../agui_store" as agui_store

import "lex-trail/src/log" as tlog

# ── Env / parse helpers ───────────────────────────────────────────────────────
fn get_env_l(key :: Str, fallback :: Str) -> [env] Str {
  match env.get(key) {
    None => fallback,
    Some(v) => if str.is_empty(v) {
      fallback
    } else {
      v
    },
  }
}

fn parse_int_or_l(s :: Str, fallback :: Int) -> Int {
  match str.to_int(s) {
    Some(n) => n,
    None => fallback,
  }
}

# ── DB helper ─────────────────────────────────────────────────────────────────
fn open_loom_db(url_or_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(url_or_path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c),
    },
  }
}

# ── JSON helpers ──────────────────────────────────────────────────────────────
fn esc(s :: Str) -> Str {
  jv.stringify(JStr(s))
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn get_jv_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    Some(JInt(n)) => int.to_str(n),
    _ => "",
  }
}

# ── /api/sprint-status/*id ──────────────────────────────────────────────────
type TransRow = { from_phase :: Str, to_phase :: Str, evidence :: Str, ts :: Str }

fn trans_to_json(r :: TransRow) -> Str {
  str.join(["{\"from\":", esc(r.from_phase), ",\"to\":", esc(r.to_phase), ",\"evidence\":", esc(r.evidence), ",\"ts\":", esc(r.ts), "}"], "")
}

fn load_transitions_json(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Str {
  let q := str.join(["SELECT from_phase, to_phase, evidence, ts FROM phase_transitions WHERE sprint_id='", sq(sprint_id), "' ORDER BY ts"], "")
  let rows :: Result[List[TransRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => "[]",
    Ok(rs) => str.concat("[", str.concat(str.join(list.map(rs, trans_to_json), ","), "]")),
  }
}

fn handle_status(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing sprint id"),
    Some(sprint_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let trans_json := load_transitions_json(db, sprint_id)
        let trail_rows := dg.load_trail(db, sprint_id)
        let trail_count := list.len(trail_rows)
        resp.json(str.join(["{\"sprint_id\":", esc(sprint_id), ",\"transitions\":", trans_json, ",\"trail_count\":", int.to_str(trail_count), "}"], ""))
      },
    },
  }
}

# ── /api/sprint-trail/*id ───────────────────────────────────────────────────
fn trail_row_to_json(r :: dg.TrailRow) -> Str {
  str.join(["{\"ts\":", esc(r.ts), ",\"event_kind\":", esc(r.event_kind), ",\"data_json\":", esc(r.data_json), "}"], "")
}

fn handle_trail(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing sprint id"),
    Some(sprint_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let rows := dg.load_trail(db, sprint_id)
        let events_json := str.concat("[", str.concat(str.join(list.map(rows, trail_row_to_json), ","), "]"))
        resp.json(str.join(["{\"sprint_id\":", esc(sprint_id), ",\"events\":", events_json, "}"], ""))
      },
    },
  }
}

# ── /api/sprint-agui/*id ─────────────────────────────────────────────────────
# Replay AG-UI events for a sprint's most recently finished node turn, as
# one SSE burst delivered right after that turn completes — not live
# mid-generation streaming; see src/agui_store.lex's header comment for
# why that's not achievable from lex-loom alone (the real blocker is
# upstream, in lex-llm's eager per-round drain). Each stored event is
# re-emitted as its own SSE `data:` frame, matching what a genuinely-live
# stream's wire shape would have looked like.
# `stream.event_stream` wraps every item with the SSE `data: ... \n\n`
# frame itself — callers pass raw payload strings, never pre-wrap them
# (an earlier version of this code double-wrapped via `sse_event`, caught
# live by demo/agui-replay-roundtrip.sh emitting literal "data: data: ").
fn agui_error_stream(msg :: Str) -> stream.StreamResponse {
  stream.event_stream(iter.from_list([str.join(["{\"error\":\"", msg, "\"}"], "")]))
}

fn handle_sprint_agui(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] stream.StreamResponse {
  match ctx.path_param(c, "id") {
    None => agui_error_stream("missing sprint id"),
    Some(sprint_id) => match open_loom_db(db_path) {
      Err(_) => agui_error_stream("could not open db"),
      Ok(db) => match agui_store.load_latest_agui_events(db, sprint_id) {
        None => agui_error_stream("no agui events recorded yet for this sprint"),
        Some(replay) => match jv.parse(replay.events_json) {
          Ok(JList(items)) => stream.event_stream(iter.from_list(list.map(items, jv.stringify))),
          _ => agui_error_stream("corrupt stored events"),
        },
      },
    },
  }
}

# ── /api/sprint-graph/*id ───────────────────────────────────────────────────
type GraphRow = { graph_json :: Str }

fn handle_graph(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing sprint id"),
    Some(sprint_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let q := str.join(["SELECT graph_json FROM sprint_graphs WHERE sprint_id='", sq(sprint_id), "' ORDER BY created_at DESC LIMIT 1"], "")
        let rows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, q, [])
        match rows {
          Err(_) => resp.json("{\"graph\":null}"),
          Ok(rs) => match list.head(rs) {
            None => resp.json("{\"graph\":null}"),
            Some(r) => resp.json(str.join(["{\"graph\":", r.graph_json, "}"], "")),
          },
        }
      },
    },
  }
}

# ── /api/artifact/:hash ───────────────────────────────────────────────────────
# Content-addressed: hash alone is the real key (this query never filtered by
# sprint id even before #153), so it doesn't need the sprint-id-in-the-path
# problem every other sprint route below has.
type ArtifactContentRow = { content :: Str }

fn handle_artifact(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "hash") {
    None => resp.bad_request("missing hash"),
    Some(hash) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
        let rows :: Result[List[ArtifactContentRow], SqlError] := sql.query(db.handle, q, [])
        match rows {
          Err(_) => resp.not_found(),
          Ok(rs) => match list.head(rs) {
            None => resp.not_found(),
            Some(r) => resp.json(str.join(["{\"hash\":", esc(hash), ",\"content\":", esc(r.content), "}"], "")),
          },
        }
      },
    },
  }
}

# ── /api/sprint-digest/*id ──────────────────────────────────────────────────
fn spec_to_json(s :: dg.TightenedSpec) -> Str {
  str.join(["{\"node_role\":", esc(s.node_role), ",\"spec_src\":", esc(s.spec_src), ",\"reason\":", esc(s.reason), "}"], "")
}

fn seed_flag(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Str {
  match dg.load_seed_graph(db, sprint_id) {
    None => "false",
    Some(_) => "true",
  }
}

fn handle_digest(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing sprint id"),
    Some(sprint_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let specs := dg.load_tightened_specs(db, sprint_id)
        let specs_json := str.concat("[", str.concat(str.join(list.map(specs, spec_to_json), ","), "]"))
        let has_seed := seed_flag(db, sprint_id)
        let summary := dg.load_summary(db, sprint_id)
        resp.json(str.join(["{\"sprint_id\":", esc(sprint_id), ",\"summary\":", esc(summary), ",\"specs\":", specs_json, ",\"has_seed_graph\":", has_seed, "}"], ""))
      },
    },
  }
}

# ── POST /api/sprints (carries [env]) ─────────────────────────────────────────
fn handle_launch_body(body :: Str, db_path :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] resp.Response {
  match jv.parse(body) {
    Err(_) => resp.bad_request("invalid JSON"),
    Ok(j) => match open_loom_db(db_path) {
      Err(e) => resp.internal_error(),
      Ok(db) => {
        let sprint_id := get_jv_str(j, "sprint_id")
        let request := get_jv_str(j, "request")
        let model := get_jv_str(j, "model")
        let sid := if str.is_empty(sprint_id) {
          str.concat("sprint-", crypto.random_str_hex(8))
        } else {
          sprint_id
        }
        let req := if str.is_empty(request) {
          "Write a hello world program."
        } else {
          request
        }
        let mdl := if str.is_empty(model) {
          "gemini-2.5-flash"
        } else {
          model
        }
        let mac := parse_int_or_l(get_jv_str(j, "max_api_calls"), 200)
        let trail_log_none :: Option[tlog.Log] := None
        let cfg := { id: sid, request: req, model: mdl, db: db, api_calls_max: mac, roster: cast.empty_roster(), trail_log: trail_log_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
        let result := orch.run_sprint(cfg)
        resp.json(str.join(["{\"sprint_id\":", esc(sid), ",\"success\":", if result.success {
          "true"
        } else {
          "false"
        }, ",\"summary\":", esc(result.summary), "}"], ""))
      },
    },
  }
}

# ── /api/agents ───────────────────────────────────────────────────────────────
type AgentPoolRow = { id :: Str, role :: Str, model_name :: Str, domain_tags_json :: Str, attestation_count :: Int, created_at :: Str }

fn agent_row_to_json(r :: AgentPoolRow) -> Str {
  str.join(["{\"id\":", esc(r.id), ",\"role\":", esc(r.role), ",\"model_name\":", esc(r.model_name), ",\"domain_tags\":", r.domain_tags_json, ",\"attestation_count\":", int.to_str(r.attestation_count), ",\"created_at\":", esc(r.created_at), "}"], "")
}

fn handle_list_agents(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match open_loom_db(db_path) {
    Err(_) => resp.internal_error(),
    Ok(db) => {
      let q := "SELECT id, role, model_name, domain_tags_json, attestation_count, created_at FROM agent_pool ORDER BY role ASC, attestation_count DESC"
      let rows :: Result[List[AgentPoolRow], SqlError] := sql.query(db.handle, q, [])
      match rows {
        Err(_) => resp.json("{\"agents\":[]}"),
        Ok(rs) => resp.json(str.concat("{\"agents\":[", str.concat(str.join(list.map(rs, agent_row_to_json), ","), "]}"))),
      }
    },
  }
}

# ── /api/agents/:id ───────────────────────────────────────────────────────────
type AgentDetailRow = { id :: Str, role :: Str, model_name :: Str, domain_tags_json :: Str, attestation_count :: Int, system_prompt :: Str, created_at :: Str }

fn handle_get_agent(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "agent_id") {
    None => resp.bad_request("missing agent id"),
    Some(agent_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => {
        let q := str.join(["SELECT id, role, model_name, domain_tags_json, attestation_count, system_prompt, created_at FROM agent_pool WHERE id='", sq(agent_id), "'"], "")
        let rows :: Result[List[AgentDetailRow], SqlError] := sql.query(db.handle, q, [])
        match rows {
          Err(_) => resp.not_found(),
          Ok(rs) => match list.head(rs) {
            None => resp.not_found(),
            Some(r) => resp.json(str.join(["{\"id\":", esc(r.id), ",\"role\":", esc(r.role), ",\"model_name\":", esc(r.model_name), ",\"domain_tags\":", r.domain_tags_json, ",\"attestation_count\":", int.to_str(r.attestation_count), ",\"system_prompt\":", esc(r.system_prompt), ",\"created_at\":", esc(r.created_at), "}"], "")),
          },
        }
      },
    },
  }
}

# ── POST /api/agents ──────────────────────────────────────────────────────────
fn handle_create_agent(body :: Str, db_path :: Str) -> [io, time, sql, fs_read, fs_write] resp.Response {
  match jv.parse(body) {
    Err(_) => resp.bad_request("invalid JSON"),
    Ok(j) => {
      let id := get_jv_str(j, "id")
      let role := get_jv_str(j, "role")
      let system_prompt := get_jv_str(j, "system_prompt")
      let model_name := get_jv_str(j, "model_name")
      let tags_json := get_jv_str(j, "tags_json")
      let att_str := get_jv_str(j, "attestation_count")
      if str.is_empty(id) {
        resp.bad_request("id is required")
      } else {
        if str.is_empty(role) {
          resp.bad_request("role is required")
        } else {
          if str.is_empty(system_prompt) {
            resp.bad_request("system_prompt is required")
          } else {
            match open_loom_db(db_path) {
              Err(_) => resp.internal_error(),
              Ok(db) => {
                let now := time.now_str()
                let model := if str.is_empty(model_name) {
                  "gemini-2.5-flash"
                } else {
                  model_name
                }
                let tags := if str.is_empty(tags_json) {
                  str.join(["[\"", sq(role), "\"]"], "")
                } else {
                  tags_json
                }
                let att := match str.to_int(att_str) {
                  Some(n) => n,
                  None => 1,
                }
                let q := str.join(["INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES ('", sq(id), "','", sq(role), "','", sq(system_prompt), "','", sq(model), "','", sq(tags), "',", int.to_str(att), ",'", sq(now), "')"], "")
                let __r := sql.exec(db.handle, q, [])
                resp.json(str.join(["{\"id\":", esc(id), ",\"role\":", esc(role), ",\"attestation_count\":", int.to_str(att), ",\"created\":true}"], ""))
              },
            }
          }
        }
      }
    },
  }
}

# ── /api/attention ────────────────────────────────────────────────────────────
#
# GET  /api/attention               — list all pending items across all oracles
# POST /api/attention/:id/approve   — mark as approved (sprint can proceed)
# POST /api/attention/:id/reject    — mark as rejected with reason (learning loop)
fn attention_row_to_json(r :: tr.AttentionRow) -> Str {
  str.join(["{\"id\":", esc(r.id), ",\"sprint_id\":", esc(r.sprint_id), ",\"node_id\":", esc(r.node_id), ",\"gate\":", esc(r.gate), ",\"oracle\":", esc(r.oracle), ",\"artifact_hash\":", esc(r.artifact_hash), ",\"verdict\":", esc(r.verdict), ",\"created_at\":", esc(r.created_at), "}"], "")
}

fn handle_list_attention(db_path :: Str, _c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match open_loom_db(db_path) {
    Err(_) => resp.internal_error(),
    Ok(db) => {
      let rows := tr.list_attention_pending(db)
      let items_json := str.concat("[", str.concat(str.join(list.map(rows, attention_row_to_json), ","), "]"))
      resp.json(str.join(["{\"pending\":", items_json, ",\"count\":", int.to_str(list.len(rows)), "}"], ""))
    },
  }
}

# resolve_attention_authorized mirrors main.lex's resolve_attention_cmd_run
# exactly (lex-loom#165): resolver_id is required and always recorded; if
# the company registered a relationships.lex contact for this item's
# oracle, only that contact's id is authorized (an unconfigured oracle
# stays open — same safe-default-when-unconfigured rule as everywhere
# else this pattern is used).
fn resolve_attention_authorized(db :: conn.ConnDb, item_id :: Str, verdict :: Str, reason :: Str, resolver_id :: Str) -> [sql, fs_write, fs_read, time] Result[Unit, Str] {
  if str.is_empty(resolver_id) {
    Err("resolver_id is required — who is resolving this must always be on the record")
  } else {
    match tr.get_attention(db, item_id) {
      None => Err(str.concat("no such attention item: ", item_id)),
      Some(item) => {
        let company_id := company.company_id_of_sprint(item.sprint_id)
        if company.is_authorized_resolver(db, company_id, item.oracle, resolver_id) {
          tr.resolve_attention(db, item_id, verdict, reason, resolver_id)
        } else {
          Err(str.join(["DENIED: ", resolver_id, " is not a registered contact for oracle '", item.oracle, "' on company '", company_id, "'"], ""))
        }
      },
    }
  }
}

fn handle_approve_attention(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing attention item id"),
    Some(item_id) => {
      let resolver_id := get_jv_str(match jv.parse(c.body) {
        Ok(j) => j,
        Err(_) => JObj([]),
      }, "resolver_id")
      match open_loom_db(db_path) {
        Err(_) => resp.internal_error(),
        Ok(db) => match resolve_attention_authorized(db, item_id, "approved", "", resolver_id) {
          Err(e) => resp.bad_request(e),
          Ok(_) => resp.json(str.join(["{\"id\":", esc(item_id), ",\"verdict\":\"approved\",\"resolved_by\":", esc(resolver_id), "}"], "")),
        },
      }
    },
  }
}

fn handle_reject_attention(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing attention item id"),
    Some(item_id) => {
      let body_j := match jv.parse(c.body) {
        Ok(j) => j,
        Err(_) => JObj([]),
      }
      let reason := get_jv_str(body_j, "reason")
      let resolver_id := get_jv_str(body_j, "resolver_id")
      match open_loom_db(db_path) {
        Err(_) => resp.internal_error(),
        Ok(db) => match resolve_attention_authorized(db, item_id, "rejected", reason, resolver_id) {
          Err(e) => resp.bad_request(e),
          Ok(_) => resp.json(str.join(["{\"id\":", esc(item_id), ",\"verdict\":\"rejected\",\"reason\":", esc(reason), ",\"resolved_by\":", esc(resolver_id), "}"], "")),
        },
      }
    },
  }
}

# ── GET /api/providers ────────────────────────────────────────────────────────
fn env_key_set(var_name :: Str) -> [env] Bool {
  match env.get(var_name) {
    None => false,
    Some(k) => str.len(k) > 0,
  }
}

fn handle_providers() -> [env] resp.Response {
  let has_vertex := if env_key_set("VERTEX_ACCESS_TOKEN") {
    env_key_set("VERTEX_PROJECT")
  } else {
    false
  }
  let has_anthropic := env_key_set("ANTHROPIC_API_KEY")
  let has_openai := env_key_set("OPENAI_API_KEY")
  let has_google := env_key_set("GOOGLE_API_KEY")
  let has_mistral := env_key_set("MISTRAL_API_KEY")
  let active := if has_vertex {
    "vertex"
  } else {
    if has_anthropic {
      "anthropic"
    } else {
      if has_openai {
        "openai"
      } else {
        if has_google {
          "google"
        } else {
          if has_mistral {
            "mistral"
          } else {
            "ollama"
          }
        }
      }
    }
  }
  let default_model := if has_vertex {
    "gemini-2.5-flash"
  } else {
    if has_anthropic {
      "claude-sonnet-4-6"
    } else {
      if has_openai {
        "gpt-4.5"
      } else {
        if has_google {
          "gemini-2.5-flash"
        } else {
          if has_mistral {
            "mistral-large-latest"
          } else {
            "gemma4:latest"
          }
        }
      }
    }
  }
  let cv := str.concat(if has_vertex {
    "\"vertex\","
  } else {
    ""
  }, str.concat(if has_anthropic {
    "\"anthropic\","
  } else {
    ""
  }, str.concat(if has_openai {
    "\"openai\","
  } else {
    ""
  }, str.concat(if has_google {
    "\"google\","
  } else {
    ""
  }, str.concat(if has_mistral {
    "\"mistral\","
  } else {
    ""
  }, "\"ollama\"")))))
  let configured_json := str.concat("[", str.concat(cv, "]"))
  resp.json(str.join(["{\"active\":", esc(active), ",\"default_model\":", esc(default_model), ",\"configured\":", configured_json, ",\"models\":{\"vertex\":[\"gemini-2.5-flash\",\"gemini-2.0-flash\",\"gemini-2.5-pro\"],\"anthropic\":[\"claude-opus-4-7\",\"claude-sonnet-4-6\",\"claude-haiku-4-5\"],\"openai\":[\"gpt-4.5\",\"o4-mini\",\"gpt-4o\"],\"google\":[\"gemini-2.5-flash\",\"gemini-2.0-flash\",\"gemini-1.5-pro\"],\"mistral\":[\"mistral-large-latest\",\"mistral-medium-latest\",\"mistral-small-latest\"],\"ollama\":[\"gemma4:latest\",\"llama3.2:latest\",\"qwen3:latest\"]}}"], ""))
}

# ── GET /api/series ───────────────────────────────────────────────────────────
fn handle_series(db_path :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match open_loom_db(db_path) {
    Err(_) => resp.internal_error(),
    Ok(db) => {
      let stats := ser.load_series(db)
      resp.json(str.join(["{\"series\":", ser.to_json(stats), "}"], ""))
    },
  }
}

# ── /api/companies ─────────────────────────────────────────────────────────────
# The Company layer (mission, iterations, backlog, operate-loop incidents/
# escalations, #118/#145/#147/#148) had zero UI before this -- board_report_cmd
# was the only way to see any of it. `company.list_companies` is the one
# genuinely new query; every field below comes from an existing per-company
# function `board_report_cmd` already calls.
fn str_list_to_json(xs :: List[Str]) -> Str {
  str.concat("[", str.concat(str.join(list.map(xs, esc), ","), "]"))
}

fn iteration_to_json(it :: company.CompanyIteration) -> Str {
  str.join(["{\"idx\":", int.to_str(it.idx), ",\"sprint_id\":", esc(it.sprint_id), ",\"status\":", esc(it.status), ",\"goal\":", esc(it.goal), "}"], "")
}

fn metrics_to_json(m :: oledger.OperateMetrics) -> Str {
  str.join(["{\"open_incidents\":", int.to_str(m.open_incidents), ",\"resolved_count\":", int.to_str(m.resolved_count), ",\"escalated_count\":", int.to_str(m.escalated_count), ",\"verified_effects\":", int.to_str(m.verified_effects), ",\"hit_rate_pct\":", int.to_str(m.hit_rate_pct), ",\"hit_rate_trend\":", esc(m.hit_rate_trend), ",\"avg_evidence_cost_milli\":", int.to_str(m.avg_evidence_cost_milli), "}"], "")
}

fn contact_to_json(row :: company.OracleContact) -> Str {
  str.join(["{\"oracle\":", esc(row.oracle), ",\"kind\":", esc(row.contact.kind), ",\"name\":", esc(row.contact.name), ",\"contact\":", esc(row.contact.contact), ",\"note\":", esc(row.contact.note), "}"], "")
}

fn company_list_row_json(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  match company.load_company(db, company_id) {
    None => "",
    Some(cfg) => {
      let its := company.load_iterations(db, company_id)
      let stage := company.load_stage(db, company_id)
      let m := oledger.operate_metrics(db, company_id)
      let spend := company.get_company_cost_cents(db, company_id)
      str.join(["{\"id\":", esc(cfg.id), ",\"goal\":", esc(cfg.goal), ",\"stage\":", esc(company.stage_to_str(stage)), ",\"iterations\":", int.to_str(list.len(its)), ",\"open_incidents\":", int.to_str(m.open_incidents), ",\"escalated_count\":", int.to_str(m.escalated_count), ",\"spend_cents\":", int.to_str(spend), "}"], "")
    },
  }
}

fn handle_list_companies(db_path :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match open_loom_db(db_path) {
    Err(_) => resp.internal_error(),
    Ok(db) => {
      let rows := list.map(company.list_companies(db), fn (id :: Str) -> [sql] Str {
        company_list_row_json(db, id)
      })
      let non_empty := list.filter(rows, fn (r :: Str) -> Bool {
        not str.is_empty(r)
      })
      resp.json(str.concat("{\"companies\":[", str.concat(str.join(non_empty, ","), "]}")))
    },
  }
}

# The product's live URL/status -- the same `liveness_target` +
# `recent_operate_signals` data `check_and_record_liveness` already produces,
# just newly exposed. "unknown" (not "down") when no reading exists yet, so
# the UI can tell "never checked" apart from "checked and it's down".
fn live_status_of(readings :: List[Str]) -> Str {
  match list.head(readings) {
    None => "unknown",
    Some(r) => if str.contains(r, ": up") {
      "up"
    } else {
      "down"
    },
  }
}

fn handle_company_detail(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing company id"),
    Some(company_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => match company.load_company(db, company_id) {
        None => resp.not_found(),
        Some(cfg) => {
          let its := company.load_iterations(db, company_id)
          let stage := company.load_stage(db, company_id)
          let spend := company.get_company_cost_cents(db, company_id)
          let m := oledger.operate_metrics(db, company_id)
          let latest := list.head(list.reverse(its))
          let latest_sprint_id := match latest {
            None => "",
            Some(it) => it.sprint_id,
          }
          let live := match latest {
            None => None,
            Some(it) => company.liveness_target(db, it.sprint_id),
          }
          let live_url := match live {
            None => "",
            Some(t) => t.url,
          }
          let live_status := live_status_of(company.recent_operate_signals(db, company_id, "liveness", 1))
          let iterations_json := str.concat("[", str.concat(str.join(list.map(its, iteration_to_json), ","), "]"))
          let contacts_json := str.concat("[", str.concat(str.join(list.map(company.all_contacts(db, company_id), contact_to_json), ","), "]"))
          resp.json(str.join(["{\"id\":", esc(cfg.id), ",\"goal\":", esc(cfg.goal), ",\"stage\":", esc(company.stage_to_str(stage)), ",\"max_iterations\":", int.to_str(cfg.max_iterations), ",\"stop_when\":", esc(cfg.stop_when), ",\"spend_cents\":", int.to_str(spend), ",\"latest_sprint_id\":", esc(latest_sprint_id), ",\"live_url\":", esc(live_url), ",\"live_status\":", esc(live_status), ",\"iterations\":", iterations_json, ",\"shipped_summary\":", esc(company.shipped_summary(db, company_id)), ",\"backlog_summary\":", esc(company.backlog_section(db, company_id)), ",\"operate_metrics\":", metrics_to_json(m), ",\"operate_signals\":", esc(company.operate_section(db, company_id)), ",\"escalations\":", str_list_to_json(company.escalation_dossiers_for_company(db, company_id)), ",\"contacts\":", contacts_json, ",\"decisions\":", str_list_to_json(list.map(company.recent_events(db, company_id, "goal_decision", 5), company.format_decision)), ",\"stage_transitions\":", str_list_to_json(list.map(company.recent_events(db, company_id, "stage_transition", 5), company.format_stage_transition)), "}"], ""))
        },
      },
    },
  }
}

# ── Router (static + read-only JSON routes) ───────────────────────────────────
fn build_loom_router(web_dir :: Str, db_path :: Str) -> router.Router {
  let r0 := router.new()
  let r1 := router.route_effectful(r0, "GET", "/", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match io.read(str.concat(web_dir, "/dashboard.html")) {
      Ok(html) => resp.html(html),
      Err(_) => resp.not_found(),
    }
  })
  let r2 := router.route_effectful(r1, "GET", "/api/sprint-status/*id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_status(db_path, c)
  })
  let r3 := router.route_effectful(r2, "GET", "/api/sprint-trail/*id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_trail(db_path, c)
  })
  let r4 := router.route_effectful(r3, "GET", "/api/sprint-digest/*id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_digest(db_path, c)
  })
  let r5 := router.route_effectful(r4, "GET", "/api/sprint-graph/*id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_graph(db_path, c)
  })
  let r6 := router.route_effectful(r5, "GET", "/api/artifact/:hash", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_artifact(db_path, c)
  })
  let r7 := router.route_effectful(r6, "GET", "/api/agents", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list_agents(db_path, c)
  })
  let r8 := router.route_effectful(r7, "GET", "/api/agents/:agent_id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_get_agent(db_path, c)
  })
  let r9 := router.route_effectful(r8, "GET", "/api/series", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_series(db_path)
  })
  let r10 := router.route_effectful(r9, "GET", "/api/attention", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list_attention(db_path, c)
  })
  let r11 := router.route_effectful(r10, "POST", "/api/attention/:id/approve", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_approve_attention(db_path, c)
  })
  let r12 := router.route_effectful(r11, "POST", "/api/attention/:id/reject", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_reject_attention(db_path, c)
  })
  let r13 := router.route_effectful(r12, "GET", "/api/companies", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list_companies(db_path)
  })
  let r14 := router.route_effectful(r13, "GET", "/api/companies/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_company_detail(db_path, c)
  })
  router.route_stream(r14, "GET", "/api/sprint-agui/*id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] stream.StreamResponse {
    handle_sprint_agui(db_path, c)
  })
}

# ── Auth gate (lex-loom#190) ──────────────────────────────────────────────────
# Every /api/* route requires LOOM_API_TOKEN — checked via
# `Authorization: Bearer <token>` OR a `?token=` query param. The query
# param exists because EventSource (the standard way a browser consumes
# SSE) cannot set custom headers at all — without it, the AG-UI replay
# endpoint would be curl/script-only. `GET /` (the dashboard shell) stays
# unauthenticated: it's static markup with no data in it, not an API
# response — every `/api/*` call the dashboard itself makes is gated
# exactly like any other caller's (dashboard.html carries its own token
# prompt + fetch wrapper). Same posture as `content_a2a.lex`'s
# `CONTENT_PUBLISH_TOKEN`: unset refuses to serve at all rather than
# silently falling back to the old fully-open behavior.
fn token_matches(presented :: Str, expected :: Str) -> Bool {
  if str.is_empty(presented) or str.is_empty(expected) {
    false
  } else {
    crypto.constant_time_eq(bytes.from_str(presented), bytes.from_str(expected))
  }
}

fn presented_token(c :: ctx.Ctx) -> Str {
  match ctx.bearer_token(c) {
    Some(t) => t,
    None => match ctx.query_param(c, "token") {
      Some(t) => t,
      None => "",
    },
  }
}

fn is_authorized(c :: ctx.Ctx, expected_token :: Str) -> Bool {
  token_matches(presented_token(c), expected_token)
}

fn unauthorized_response() -> Response {
  { status: 401, body: BodyStr("{\"error\":\"unauthorized\",\"detail\":\"missing or invalid Authorization: Bearer <token> or ?token=\"}"), headers: map.from_list([("content-type", "application/json")]) }
}

# ── Entry point ───────────────────────────────────────────────────────────────
fn serve_loom() -> [env, net, io, llm, proc, sql, fs_read, fs_write, time, crypto, random, concurrent, vcs] Unit {
  let api_token := get_env_l("LOOM_API_TOKEN", "")
  if str.is_empty(api_token) {
    io.print("[lex-loom] FATAL: LOOM_API_TOKEN is required — refusing to serve an unauthenticated web API")
  } else {
    let port := parse_int_or_l(get_env_l("PORT", "8880"), 8880)
    let db_url := get_env_l("DB_URL", "")
    let db_path := if str.is_empty(db_url) {
      get_env_l("DB_PATH", "loom.db")
    } else {
      db_url
    }
    let web_dir := get_env_l("WEB_DIR", "src/web")
    let __seed := match open_loom_db(db_path) {
      Err(_) => (),
      Ok(db) => pool_seed.seed(db),
    }
    let r := build_loom_router(web_dir, db_path)
    let __p := io.print(str.join(["[lex-loom] web on :", int.to_str(port), "  db=", db_path], ""))
    net.serve_fn(port, fn (req :: Request) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Response {
      let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
      if req.path == "/" {
        match router.dispatch_outcome(r, raw) {
          DPlain(rsp) => { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers },
          DStream(sr) => { status: sr.status, body: BodyStream(sr.body), headers: sr.headers },
        }
      } else {
        let c := ctx.from_request(raw, map.new())
        if is_authorized(c, api_token) {
          if req.method == "POST" and req.path == "/api/sprints" {
            let rsp := handle_launch_body(req.body, db_path)
            { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
          } else {
            if req.method == "POST" and req.path == "/api/agents" {
              let rsp := handle_create_agent(req.body, db_path)
              { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
            } else {
              if req.method == "GET" and req.path == "/api/providers" {
                let rsp := handle_providers()
                { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
              } else {
                match router.dispatch_outcome(r, raw) {
                  DPlain(rsp) => { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers },
                  DStream(sr) => { status: sr.status, body: BodyStream(sr.body), headers: sr.headers },
                }
              }
            }
          }
        } else {
          unauthorized_response()
        }
      }
    })
  }
}

