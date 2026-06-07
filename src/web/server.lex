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
fn open_loom_db(url_or_path :: Str) -> [sql, fs_write] Result[Db, Str] {
  match conn.open(url_or_path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c.handle),
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

fn load_transitions_json(db :: Db, sprint_id :: Str) -> [sql, fs_read] Str {
  let q := str.join(["SELECT from_phase, to_phase, evidence, ts FROM phase_transitions WHERE sprint_id='", sq(sprint_id), "' ORDER BY ts"], "")
  let rows :: Result[List[TransRow], SqlError] := sql.query(db, q, [])
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
        let rows :: Result[List[GraphRow], SqlError] := sql.query(db, q, [])
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
          let rows :: Result[List[ArtifactContentRow], SqlError] := sql.query(db, q, [])
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

fn seed_flag(db :: Db, sprint_id :: Str) -> [sql, fs_read] Str {
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
        resp.json(str.join(["{\"sprint_id\":", esc(sprint_id), ",\"specs\":", specs_json, ",\"has_seed_graph\":", has_seed, "}"], ""))
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
          "gemma4:latest"
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
      let rows :: Result[List[AgentPoolRow], SqlError] := sql.query(db, q, [])
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
        let rows :: Result[List[AgentDetailRow], SqlError] := sql.query(db, q, [])
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
  let r9 := router.route_effectful(r8, "GET", "/api/attention", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_list_attention(db_path, c)
  })
  let r10 := router.route_effectful(r9, "POST", "/api/attention/:id/approve", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_approve_attention(db_path, c)
  })
  router.route_effectful(r10, "POST", "/api/attention/:id/reject", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
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
      let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
      let rsp := router.dispatch(r, raw)
      { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
    }
  })
}

