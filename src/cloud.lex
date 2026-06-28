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

import "lex-trail/src/log" as tlog

import "lex-trail/src/event" as tev

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
type PollResult = GotSprint((Str, Str, Str, Str)) | NothingQueued | PollError(Str)

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
  match jv.get_field(o, k) {
    Some(JStr(v)) => v,
    _ => dflt,
  }
}

fn jint(o :: jv.Json, k :: Str, dflt :: Int) -> Int {
  match jv.get_field(o, k) {
    Some(JInt(v)) => v,
    _ => dflt,
  }
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

# ── Content-addressed event hash ───────────────────────────────────────────────
# The uploaded `hash` is a real lex-trail content id — the SAME compute_id the
# arena uses — so a loom sprint trail is content-addressed and tamper-evident,
# not the old "<seq>-<kind>-<ts>" placeholder. Events that came from a lex-trail
# log keep their original id (e.id); events from the SQL trail get one computed
# here, chained to the previous event's hash (seq is the positional component).
fn event_data(e :: dg.TrailRow) -> Str {
  if str.is_empty(e.data_json) {
    "{}"
  } else {
    e.data_json
  }
}

fn event_hash(e :: dg.TrailRow, seq :: Int, parent :: Str) -> Str {
  if str.is_empty(e.id) {
    let parent_opt := if str.is_empty(parent) {
      None
    } else {
      Some(parent)
    }
    tev.compute_id(e.event_kind, parent_opt, event_data(e), seq)
  } else {
    e.id
  }
}

# ── Serialize trail event to JSON (hash supplied by the caller) ─────────────────
fn event_json(e :: dg.TrailRow, seq :: Int, hash :: Str) -> Str {
  let k := jv.stringify(JStr(e.event_kind))
  let ts := jv.stringify(JStr(e.ts))
  str.join(["{\"kind\":", k, ",\"data\":", event_data(e), ",\"ts\":", ts, ",\"seq\":", int.to_str(seq), ",\"hash\":", jv.stringify(JStr(hash)), "}"], "")
}

fn events_to_json(events :: List[dg.TrailRow]) -> Str {
  let result := list.fold(events, { items: "", idx: 0, first: true, parent: "" }, fn (acc :: { items :: Str, idx :: Int, first :: Bool, parent :: Str }, e :: dg.TrailRow) -> { items :: Str, idx :: Int, first :: Bool, parent :: Str } {
    let h := event_hash(e, acc.idx, acc.parent)
    let sep := if acc.first {
      ""
    } else {
      ","
    }
    { items: str.concat(acc.items, str.concat(sep, event_json(e, acc.idx, h))), idx: acc.idx + 1, first: false, parent: h }
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
fn run_cloud_sprint(db :: conn.ConnDb, sprint_id :: Str, request :: Str, model :: Str, agents_json :: Str, server :: Str, token :: Str, max_calls :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  let n_cloud := seed_agents_from_cloud(db, agents_json)
  let __seed := if n_cloud > 0 {
    let __l := io.print(str.join(["[cloud] seeded ", int.to_str(n_cloud), " agent(s) from cloud"], ""))
    ()
  } else {
    let __l := io.print("[cloud] no cloud agents; using built-in defaults")
    pool_seed.seed(db)
  }
  let trail_log_none :: Option[tlog.Log] := None
  let cfg := { id: sprint_id, request: request, model: model, db: db, api_calls_max: max_calls, roster: cast.empty_roster(), trail_log: trail_log_none, review_transitions: false, depth: 0, iter_ctx: None }
  let result :: orch.SprintResult := orch.run_sprint(cfg)
  let ok_str := if result.success {
    "true"
  } else {
    "false"
  }
  let __log := io.print(str.join(["[cloud] sprint=", sprint_id, " success=", ok_str], ""))
  let complete := { id: "", event_kind: "sprint_complete", data_json: str.join(["{\"success\":", ok_str, ",\"summary\":", jv.stringify(JStr(result.summary)), "}"], ""), ts: time.now_str() }
  let detailed := dg.load_trail(db, sprint_id)
  let base_trail := if list.is_empty(detailed) {
    load_lex_trail(sprint_id)
  } else {
    detailed
  }
  let full_trail := list.concat(base_trail, [complete])
  let __up := upload_trail(server, token, sprint_id, full_trail)
  let __log2 := io.print(str.join(["[cloud] uploaded ", int.to_str(list.len(full_trail)), " trail events (incl. sprint_complete)"], ""))
  ()
}

# Load the sprint's lex-trail events (the authoritative audit record) and
# map each to a TrailRow for upload. Returns [] if the store is absent.
fn load_lex_trail(sprint_id :: Str) -> [sql, fs_write, time] List[dg.TrailRow] {
  match tlog.open(str.concat(sprint_id, "-trail.db")) {
    Err(_) => [],
    Ok(log) => match tlog.range(log, 0, 4000000000000000) {
      Err(_) => [],
      Ok(events) => {
        let now := time.now_str()
        list.map(events, fn (e :: tev.Event) -> dg.TrailRow {
          { id: e.id, event_kind: e.kind, data_json: e.payload_json, ts: now }
        })
      },
    },
  }
}

# ── One poll cycle (call repeatedly from a loop or cron) ──────────────────────
fn poll_once(db :: conn.ConnDb, server :: Str, token :: Str, max_calls :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  match poll(server, token) {
    PollError(e) => io.print(str.join(["[cloud] poll error: ", e], "")),
    NothingQueued => io.print("[cloud] nothing queued"),
    GotSprint(sprint_id, request, model, agents_json) => {
      let __log := io.print(str.join(["[cloud] claimed sprint=", sprint_id], ""))
      run_cloud_sprint(db, sprint_id, request, model, agents_json, server, token, max_calls)
    },
  }
}

