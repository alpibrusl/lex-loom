# digest.lex — Digest phase: trail → tightened specs + seed graph (§12).
#
# The Scribe role reads the finished sprint's trail events and produces:
#   1. Tightened specs  — a QA miss this sprint becomes a gate precondition
#                         for nodes in the next sprint.
#   2. Updated prompts  — capability descriptions refined from observed failures.
#   3. A seed SprintGraph — starting topology for the next sprint cycle.
#
# The crucial property: learning is encoded into the substrate's constraints,
# not stuffed into a prompt. Trust accrues mechanically across cycles.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.int" as int

import "lex-orm/src/connection" as conn

import "std.time" as time

import "std.crypto" as crypto

import "std.io" as io

import "lex-schema/json_value" as jv

import "./agent/runner" as runner

import "./agent/trace" as trace

import "./graph" as graph

import "./transport" as tr

import "./roles" as roles

import "./cast" as cast

import "lex-orm/src/query" as ormq

# ── Types ─────────────────────────────────────────────────────────────────────
# A spec gate tightened based on this sprint's outcomes.
type TightenedSpec = { node_role :: Str, spec_src :: Str, reason :: Str }

# The full Digest artifact produced by the Scribe at end of sprint.
# summary: stakeholder-facing prose retrospective (replaces the separate Retro phase)
type DigestArtifacts = { sprint_id :: Str, next_sprint_id :: Str, summary :: Str, lessons :: Str, tightened_specs :: List[TightenedSpec], seed_graph :: graph.SprintGraph }

type DigestResult = DigestOk(DigestArtifacts) | DigestFailed(Str)

type TrailRow = { id :: Str, event_kind :: Str, data_json :: Str, ts :: Str }

# The shape the `traces` SELECT returns (no content id column).
type TraceQ = { event_kind :: Str, data_json :: Str, ts :: Str }

fn load_trail(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] List[TrailRow] {
  let qd := ormq.for_dialect({ sql: "SELECT event_kind, data_json, ts FROM traces WHERE agent_id=? ORDER BY ts", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[TraceQ], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: TraceQ) -> TrailRow {
      { id: "", event_kind: r.event_kind, data_json: r.data_json, ts: r.ts }
    }),
  }
}

fn format_trail(rows :: List[TrailRow]) -> Str {
  list.fold(rows, "", fn (acc :: Str, r :: TrailRow) -> Str {
    str.join([acc, "[", r.ts, "] ", r.event_kind, " ", r.data_json, "\n"], "")
  })
}

# ── Storage ───────────────────────────────────────────────────────────────────
fn save_tightened_spec(db :: conn.ConnDb, sprint_id :: Str, ts :: TightenedSpec) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "INSERT INTO tightened_specs (id, sprint_id, node_role, spec_src, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(sprint_id), PStr(ts.node_role), PStr(ts.spec_src), PStr(ts.reason), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, qd.sql, qd.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn save_digest(db :: conn.ConnDb, d :: DigestArtifacts) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let seed_j := graph.to_json_str(d.seed_graph)
  let qd := ormq.for_dialect({ sql: "INSERT INTO digests (id, sprint_id, summary_text, lessons, seed_graph_json, created_at) VALUES (?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(d.sprint_id), PStr(d.summary), PStr(d.lessons), PStr(seed_j), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, qd.sql, qd.params) {
    Err(e) => Err(e.message),
    Ok(_) => {
      let spec_results := list.map(d.tightened_specs, fn (ts :: TightenedSpec) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
        save_tightened_spec(db, d.next_sprint_id, ts)
      })
      let first_err := list.fold(spec_results, None, fn (acc :: Option[Str], r :: Result[Unit, Str]) -> Option[Str] {
        match acc {
          Some(_) => acc,
          None => match r {
            Err(e) => Some(e),
            Ok(_) => None,
          },
        }
      })
      match first_err {
        Some(e) => Err(e),
        None => Ok(()),
      }
    },
  }
}

# Load tightened specs for a sprint — used by next sprint's Architect
# to incorporate prior learning into gate definitions.
type SpecRow = { node_role :: Str, spec_src :: Str, reason :: Str }

fn load_tightened_specs(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] List[TightenedSpec] {
  let qd := ormq.for_dialect({ sql: "SELECT node_role, spec_src, reason FROM tightened_specs WHERE sprint_id=? ORDER BY created_at", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[SpecRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: SpecRow) -> TightenedSpec {
      { node_role: r.node_role, spec_src: r.spec_src, reason: r.reason }
    }),
  }
}

# Load the summary from the most recent digest for a sprint.
type SummaryRow = { summary_text :: Str }

fn load_summary(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Str {
  let qd := ormq.for_dialect({ sql: "SELECT summary_text FROM digests WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[SummaryRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) {
      None => "",
      Some(r) => r.summary_text,
    },
  }
}

# Load the seed graph from the most recent digest for a sprint series.
type SeedRow = { seed_graph_json :: Str }

fn load_seed_graph(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Option[graph.SprintGraph] {
  let qd := ormq.for_dialect({ sql: "SELECT seed_graph_json FROM digests WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[SeedRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => match graph.from_json_str(r.seed_graph_json) {
        Err(_) => None,
        Ok(g) => Some(g),
      },
    },
  }
}

# ── Digest JSON parsing ───────────────────────────────────────────────────────
#
# The Scribe emits:
# {
#   "lessons": "...",
#   "tightened_specs": [
#     { "node_role": "qa", "spec_src": "spec output contains PASS", "reason": "..." }
#   ],
#   "seed_graph": { <SprintGraph JSON> }
# }
fn parse_tightened_spec(j :: jv.Json) -> Option[TightenedSpec] {
  let role := match jv.get_field(j, "node_role") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let src := match jv.get_field(j, "spec_src") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let why := match jv.get_field(j, "reason") {
    Some(JStr(s)) => s,
    _ => "",
  }
  if str.is_empty(role) {
    None
  } else {
    if str.is_empty(src) {
      None
    } else {
      Some({ node_role: role, spec_src: src, reason: why })
    }
  }
}

fn parse_tightened_specs(j :: jv.Json) -> List[TightenedSpec] {
  match j {
    JList(items) => list.fold(items, [], fn (acc :: List[TightenedSpec], item :: jv.Json) -> List[TightenedSpec] {
      match parse_tightened_spec(item) {
        None => acc,
        Some(ts) => list.concat(acc, [ts]),
      }
    }),
    _ => [],
  }
}

fn default_seed_graph(next_sprint_id :: Str) -> graph.SprintGraph {
  { id: str.concat(next_sprint_id, "-seed"), phase: graph.Intake, nodes: [{ id: "intake", role: "architect", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "build", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "qa", role: "qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "intake", to: "build", handoff: "schema {}" }, { from: "build", to: "qa", handoff: "schema {}" }, { from: "qa", to: "demo", handoff: "schema {}" }] }
}

fn parse_digest_json(j :: jv.Json, sprint_id :: Str, next_sprint_id :: Str) -> DigestArtifacts {
  let summary := match jv.get_field(j, "summary") {
    Some(JStr(s)) => s,
    _ => "(no summary recorded)",
  }
  let lessons := match jv.get_field(j, "lessons") {
    Some(JStr(s)) => s,
    _ => "(no lessons recorded)",
  }
  let specs := match jv.get_field(j, "tightened_specs") {
    Some(v) => parse_tightened_specs(v),
    None => [],
  }
  let seed := match jv.get_field(j, "seed_graph") {
    Some(v) => match graph.from_json(v) {
      Ok(g) => g,
      Err(_) => default_seed_graph(next_sprint_id),
    },
    None => default_seed_graph(next_sprint_id),
  }
  { sprint_id: sprint_id, next_sprint_id: next_sprint_id, summary: summary, lessons: lessons, tightened_specs: specs, seed_graph: seed }
}

# ── Scribe prompt ─────────────────────────────────────────────────────────────
fn scribe_prompt(sprint_id :: Str, trail_text :: Str, next_sprint_id :: Str) -> Str {
  str.join(["You are the Scribe. Sprint `", sprint_id, "` has completed.\n\n", "Sprint trail:\n```\n", trail_text, "\n```\n\n", "Produce a JSON digest with this exact shape (no prose, no markdown fences):\n", "{\n", "  \"summary\": \"<2-3 paragraph stakeholder-facing retrospective: what was built, key outcomes, what to improve next — write for a non-technical audience>\",\n", "  \"lessons\": \"<1-3 sentences: what worked, what failed, key technical insight for the engineering team>\",\n", "  \"tightened_specs\": [\n", "    {\n", "      \"node_role\": \"<role that needs a tighter gate>\",\n", "      \"spec_src\": \"<new gate predicate, e.g. spec json-verdict-pass>\",\n", "      \"reason\": \"<why this gate was added based on sprint evidence>\"\n", "    }\n", "  ],\n", "  \"seed_graph\": {\n", "    \"id\": \"", next_sprint_id, "-seed\",\n", "    \"phase\": \"Intake\",\n", "    \"nodes\": [ { \"id\": \"...\", \"role\": \"...\", \"gate\": \"spec non-empty\" } ],\n", "    \"edges\": [ { \"from\": \"...\", \"to\": \"...\", \"handoff\": \"schema {}\" } ]\n", "  }\n", "}\n\n", "Rules for seed_graph: must be a valid SprintGraph — no cycles, every demo node must ", "have a qa ancestor, every node needs a non-empty gate. Use 'spec json-verdict-pass' for qa nodes.\n", "Add a tightened_spec entry for every node_role that produced a gate denial or empty output.\n", "Output only JSON."], "")
}

# ── Public API ────────────────────────────────────────────────────────────────
fn run_digest(sprint_id :: Str, next_sprint_id :: Str, model :: Str, db :: conn.ConnDb) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] DigestResult {
  let trail_rows := load_trail(db, sprint_id)
  let trail_text := if list.is_empty(trail_rows) {
    "(no trail events found)"
  } else {
    format_trail(trail_rows)
  }
  let __tl := io.print(str.join(["[loom/digest] sprint=", sprint_id, " trail_events=", int.to_str(list.len(trail_rows))], ""))
  let default_scribe := roles.scribe(model)
  let scribe_candidates := cast.load_pool_for_role(db, "scribe")
  let agent_cfg := match cast.best_agent(scribe_candidates, sprint_id) {
    None => default_scribe,
    Some(a) => cast.pool_agent_to_config(a, default_scribe, model),
  }
  let prompt := scribe_prompt(sprint_id, trail_text, next_sprint_id)
  let output := runner.step(db, agent_cfg, prompt, sprint_id, "")
  let __to := io.print(str.join(["[loom/digest] scribe output_len=", int.to_str(str.len(output))], ""))
  let __tt := trace.record(db, sprint_id, sprint_id, "digest_produced", str.join(["{\"output_len\":", int.to_str(str.len(output)), "}"], ""))
  let artifacts := match jv.parse(output) {
    Err(_) => parse_digest_json(JObj([]), sprint_id, next_sprint_id),
    Ok(j) => parse_digest_json(j, sprint_id, next_sprint_id),
  }
  match save_digest(db, artifacts) {
    Err(e) => {
      let __te := trace.record(db, sprint_id, sprint_id, "digest_save_failed", str.join(["{\"error\":\"", e, "\"}"], ""))
      DigestFailed(e)
    },
    Ok(_) => {
      let __tv := trace.record(db, sprint_id, sprint_id, "digest_saved", str.join(["{\"specs\":", int.to_str(list.len(artifacts.tightened_specs)), ",\"seed_nodes\":", int.to_str(list.len(artifacts.seed_graph.nodes)), "}"], ""))
      DigestOk(artifacts)
    },
  }
}

# Format tightened specs as context for the next Architect.
# Injected into the Design prompt so learning carries forward.
fn specs_context(specs :: List[TightenedSpec]) -> Str {
  if list.is_empty(specs) {
    ""
  } else {
    let lines := list.map(specs, fn (ts :: TightenedSpec) -> Str {
      str.join(["  - role=", ts.node_role, " gate: ", ts.spec_src, " (reason: ", ts.reason, ")"], "")
    })
    str.join(["\n\nTightened specs from previous sprint (apply these gates to matching roles):\n", list.fold(lines, "", fn (acc :: Str, l :: Str) -> Str {
      str.concat(acc, str.concat(l, "\n"))
    })], "")
  }
}

