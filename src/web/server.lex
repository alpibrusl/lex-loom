# server.lex — lex-loom web dashboard.
#
# Endpoints:
#   GET  /                        — dashboard HTML (src/web/dashboard.html)
#   POST /api/sprints             — launch sprint, returns {sprint_id,success,summary}
#   GET  /api/sprints/:id/status  — phase transitions + trail count
#   GET  /api/sprints/:id/trail   — trail events as JSON
#   GET  /api/sprints/:id/digest  — tightened specs + seed-graph flag
#
# Run:
#   lex run --allow-effects env,net,io,llm,proc,sql,fs_read,fs_write,time,crypto,random,concurrent \
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

import "lex-web/src/router" as router

import "lex-web/src/ctx" as ctx

import "lex-web/src/response" as resp

import "lex-web/src/static_files" as sf

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "../migrate" as migrate

import "../orchestrator" as orch

import "../transport" as tr

import "../digest" as dg

import "../cast" as cast

import "../pool_seed" as pool_seed

import "../series" as ser

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

# ── /api/sprints/:id/status ───────────────────────────────────────────────────
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

# ── /api/sprints/:id/trail ────────────────────────────────────────────────────
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

# ── /api/sprints/:id/graph ───────────────────────────────────────────────────
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

# ── /api/sprints/:id/artifact/:hash ──────────────────────────────────────────
type ArtifactContentRow = { content :: Str }

fn handle_artifact(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing sprint id"),
    Some(_sprint_id) => match ctx.path_param(c, "hash") {
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
    },
  }
}

# ── /api/sprints/:id/digest ───────────────────────────────────────────────────
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
fn handle_launch_body(body :: Str, db_path :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
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
        let cfg := { id: sid, request: req, model: mdl, db: db, api_calls_max: mac, roster: cast.empty_roster() }
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

fn handle_approve_attention(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing attention item id"),
    Some(item_id) => match open_loom_db(db_path) {
      Err(_) => resp.internal_error(),
      Ok(db) => match tr.resolve_attention(db, item_id, "approved", "") {
        Err(e) => resp.bad_request(e),
        Ok(_) => resp.json(str.join(["{\"id\":", esc(item_id), ",\"verdict\":\"approved\"}"], "")),
      },
    },
  }
}

fn handle_reject_attention(db_path :: Str, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing attention item id"),
    Some(item_id) => {
      let reason := get_jv_str(match jv.parse(c.body) {
        Ok(j) => j,
        Err(_) => JObj([]),
      }, "reason")
      match open_loom_db(db_path) {
        Err(_) => resp.internal_error(),
        Ok(db) => match tr.resolve_attention(db, item_id, "rejected", reason) {
          Err(e) => resp.bad_request(e),
          Ok(_) => resp.json(str.join(["{\"id\":", esc(item_id), ",\"verdict\":\"rejected\",\"reason\":", esc(reason), "}"], "")),
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

# ── Router (static + read-only JSON routes) ───────────────────────────────────
fn build_loom_router(web_dir :: Str, db_path :: Str) -> router.Router {
  let r0 := router.new()
  let r1 := router.route_effectful(r0, "GET", "/", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match io.read(str.concat(web_dir, "/dashboard.html")) {
      Ok(html) => resp.html(html),
      Err(_) => resp.not_found(),
    }
  })
  let r2 := router.route_effectful(r1, "GET", "/api/sprints/:id/status", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_status(db_path, c)
  })
  let r3 := router.route_effectful(r2, "GET", "/api/sprints/:id/trail", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_trail(db_path, c)
  })
  let r4 := router.route_effectful(r3, "GET", "/api/sprints/:id/digest", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_digest(db_path, c)
  })
  let r5 := router.route_effectful(r4, "GET", "/api/sprints/:id/graph", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_graph(db_path, c)
  })
  let r6 := router.route_effectful(r5, "GET", "/api/sprints/:id/artifact/:hash", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
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
  router.route_effectful(r11, "POST", "/api/attention/:id/reject", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_reject_attention(db_path, c)
  })
}

# ── Entry point ───────────────────────────────────────────────────────────────
fn serve_loom() -> [env, net, io, llm, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Unit {
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
  net.serve_fn(port, fn (req :: Request) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Response {
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
          let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
          let rsp := router.dispatch(r, raw)
          { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
        }
      }
    }
  })
}

