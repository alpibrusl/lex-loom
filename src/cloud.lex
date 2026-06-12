# cloud.lex — Cloud polling mode for lex-loom runner.
#
# Protocol:
#   1. POST <server>/api/runners/poll  { runner_token } → { sprint_id, request, model } | { sprint_id: null }
#   2. Execute sprint locally (full orchestrator pipeline)
#   3. POST <server>/api/sprints/:id/events  { runner_token, events: [...] }
#
# Run via: loom cloud_poll
# Env: LOOM_SERVER, LOOM_RUNNER_TOKEN, DB_PATH, MAX_API_CALLS

import "std.str" as str

import "std.io" as io

import "std.env" as env

import "std.http" as http

import "std.bytes" as bytes

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-schema/json_value" as jv

import "./digest" as dg

import "./orchestrator" as orch

import "./cast" as cast

import "./pool_seed" as pool_seed

# ── HTTP helpers ───────────────────────────────────────────────────────────────
fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn post_json(url :: Str, body :: Str) -> [net] Result[Str, Str] {
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(e) => Err(http_err(e)),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err("response body decode failed"),
      Ok(s) => Ok(s),
    },
  }
}

# ── Poll for next sprint ───────────────────────────────────────────────────────
# GotSprint carries the agents JSON (the cloud agent_pool for this user) so the
# runner can run with cloud-defined agents — the cloud is the source of truth.
type PollResult = GotSprint(Str, Str, Str, Str) | NothingQueued | PollError(Str)

fn poll(server :: Str, token :: Str) -> [net] PollResult {
  let url := str.concat(server, "/api/runners/poll")
  let body := str.concat("{\"runner_token\":\"", str.concat(token, "\"}"))
  match post_json(url, body) {
    Err(e) => PollError(e),
    Ok(s) => match jv.parse(s) {
      Err(_) => PollError(str.concat("poll parse error: ", s)),
      Ok(j) => match jv.get_field(j, "sprint_id") {
        None => NothingQueued,
        Some(JNull) => NothingQueued,
        Some(JStr(sid)) => if str.is_empty(sid) {
          NothingQueued
        } else {
          let request := match jv.get_field(j, "request") {
            Some(JStr(r)) => r,
            _ => "",
          }
          let model := match jv.get_field(j, "model") {
            Some(JStr(m)) => m,
            _ => "gpt-4o",
          }
          let agents := match jv.get_field(j, "agents") {
            Some(a) => jv.stringify(a),
            None => "[]",
          }
          GotSprint(sid, request, model, agents)
        },
        Some(_) => NothingQueued,
      },
    },
  }
}

# ── Seed the local agent pool from cloud-supplied agent definitions ─────────────
fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn jstr(o :: jv.Json, k :: Str, dflt :: Str) -> Str {
  match jv.get_field(o, k) { Some(JStr(v)) => v, _ => dflt }
}

fn jint(o :: jv.Json, k :: Str, dflt :: Int) -> Int {
  match jv.get_field(o, k) { Some(JInt(v)) => v, _ => dflt }
}

fn insert_cloud_agent(db :: conn.ConnDb, now :: Str, o :: jv.Json) -> [sql, fs_write] Unit {
  let id := jstr(o, "id", "")
  if str.is_empty(id) {
    ()
  } else {
    let role := jstr(o, "role", "")
    let prompt := jstr(o, "system_prompt", "")
    let model_name := jstr(o, "model_name", "")
    let tags := jstr(o, "domain_tags_json", "[]")
    let att := jint(o, "attestation_count", 0)
    let q := str.join(["INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at) VALUES ('", sq(id), "','", sq(role), "','", sq(prompt), "','", sq(model_name), "','", sq(tags), "',", int.to_str(att), ",'", sq(now), "')"], "")
    let __r := sql.exec(db.handle, q, [])
    ()
  }
}

# Returns the number of agents seeded from the cloud (0 if none / parse error).
fn seed_agents_from_cloud(db :: conn.ConnDb, agents_json :: Str) -> [sql, fs_write, time] Int {
  match jv.parse(agents_json) {
    Err(_) => 0,
    Ok(j) => match j {
      JList(items) => {
        let now := time.now_str()
        let __m := list.map(items, fn (o :: jv.Json) -> [sql, fs_write] Unit {
          insert_cloud_agent(db, now, o)
        })
        list.len(items)
      },
      _ => 0,
    },
  }
}

# ── Serialize trail event to JSON ──────────────────────────────────────────────
fn event_json(e :: dg.TrailRow, seq :: Int) -> Str {
  let k := jv.stringify(JStr(e.event_kind))
  let ts := jv.stringify(JStr(e.ts))
  let data := if str.is_empty(e.data_json) {
    "{}"
  } else {
    e.data_json
  }
  let hash := str.join([int.to_str(seq), "-", e.event_kind, "-", e.ts], "")
  str.join(["{\"kind\":", k, ",\"data\":", data, ",\"ts\":", ts, ",\"seq\":", int.to_str(seq), ",\"hash\":", jv.stringify(JStr(hash)), "}"], "")
}

fn events_to_json(events :: List[dg.TrailRow]) -> Str {
  let result := list.fold(events, { items: "", idx: 0, first: true }, fn (acc :: { items :: Str, idx :: Int, first :: Bool }, e :: dg.TrailRow) -> { items :: Str, idx :: Int, first :: Bool } {
    let sep := if acc.first {
      ""
    } else {
      ","
    }
    { items: str.concat(acc.items, str.concat(sep, event_json(e, acc.idx))), idx: acc.idx + 1, first: false }
  })
  str.join(["[", result.items, "]"], "")
}

# ── Upload trail to server ─────────────────────────────────────────────────────
fn upload_trail(server :: Str, token :: Str, sprint_id :: Str, events :: List[dg.TrailRow]) -> [net] Unit {
  let url := str.join([server, "/api/sprints/", sprint_id, "/events"], "")
  let arr := events_to_json(events)
  let body := str.join(["{\"runner_token\":", jv.stringify(JStr(token)), ",\"events\":", arr, "}"], "")
  let __r := post_json(url, body)
  ()
}

# ── Execute one cloud sprint ───────────────────────────────────────────────────
fn run_cloud_sprint(db :: conn.ConnDb, sprint_id :: Str, request :: Str, model :: Str, agents_json :: Str, server :: Str, token :: Str, max_calls :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  # Cloud is the source of truth for agents. Seed the local pool from the
  # cloud-supplied definitions; fall back to built-in defaults only when the
  # cloud has none (fresh account / offline).
  let n_cloud := seed_agents_from_cloud(db, agents_json)
  let __seed := if n_cloud > 0 {
    let __l := io.print(str.join(["[cloud] seeded ", int.to_str(n_cloud), " agent(s) from cloud"], ""))
    ()
  } else {
    let __l := io.print("[cloud] no cloud agents; using built-in defaults")
    pool_seed.seed(db)
  }
  let cfg := {
    id: sprint_id,
    request: request,
    model: model,
    db: db,
    api_calls_max: max_calls,
    roster: cast.empty_roster()
  }
  let result := orch.run_sprint(cfg)
  let ok_str := if result.success {
    "true"
  } else {
    "false"
  }
  let __log := io.print(str.join(["[cloud] sprint=", sprint_id, " success=", ok_str], ""))
  # Always append an explicit sprint_complete event carrying the verdict +
  # digest summary. The cloud /events ingest updates status/success/summary
  # on this kind, so the dashboard reflects completion even when the local
  # trail is empty (see #11 — load_trail can return [] in cloud mode).
  let complete := {
    event_kind: "sprint_complete",
    data_json: str.join(["{\"success\":", ok_str, ",\"summary\":", jv.stringify(JStr(result.summary)), "}"], ""),
    ts: time.now_str()
  }
  let trail := dg.load_trail(db, sprint_id)
  let full_trail := list.concat(trail, [complete])
  let __up := upload_trail(server, token, sprint_id, full_trail)
  let __log2 := io.print(str.join(["[cloud] uploaded ", int.to_str(list.len(full_trail)), " trail events (incl. sprint_complete)"], ""))
  ()
}

# ── One poll cycle (call repeatedly from a loop or cron) ──────────────────────
fn poll_once(db :: conn.ConnDb, server :: Str, token :: Str, max_calls :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  match poll(server, token) {
    PollError(e) => io.print(str.join(["[cloud] poll error: ", e], "")),
    NothingQueued => io.print("[cloud] nothing queued"),
    GotSprint(sprint_id, request, model, agents_json) => {
      let __log := io.print(str.join(["[cloud] claimed sprint=", sprint_id], ""))
      run_cloud_sprint(db, sprint_id, request, model, agents_json, server, token, max_calls)
    },
  }
}
