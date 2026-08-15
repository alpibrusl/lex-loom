# delegation.lex — ORG2 (lex-loom#217): agent→agent delegation.
#
# One role hands a TYPED subtask to a direct report. Three hard rules:
#
#   1. STRUCTURAL GATE. Writing an assignment requires the ORG1 `may_assign`
#      edge (org.lex: a manager may assign to its direct reports) — checked
#      against the DB org chart at write time, never against anything the
#      LLM said. No edge, no delegation; the refusal lands on the trail
#      (`delegation_refused`).
#   2. CLOSED VOCABULARY. A task spec is a `kind` from `known_kinds()` plus
#      a goal string rendered through that kind's FIXED prompt template —
#      no free-form command synthesis (#118 §2.7 posture).
#   3. NORMAL EXECUTION. An accepted assignment materializes as an ordinary
#      sprint node (company_runner.drain_assignments) — casting, grants,
#      gates, attestations and the trail all apply unchanged. The artifact
#      lands back on the assignment; a failed one is `returned` and the
#      return escalates up the ORG1 reporting lines.
#
# The `delegate` tool follows runner.lex's op-call pattern: a tool's effect
# row is [net, io, proc] (no sql), so the tool only APPENDS a request line to
# a per-run file; after the agent loop, runner.step flushes the file through
# `offer` — which is where the structural gate lives. An LLM can emit any
# delegation request it likes; only org-authorized ones become assignments.

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "std.io" as io

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "./graph" as graph

import "./org" as org

import "./transport" as tr

# ── Closed task-spec vocabulary ──────────────────────────────────────────────
fn known_kinds() -> List[Str] {
  ["build_feature", "write_tests", "write_docs", "review_artifact"]
}

fn is_known_kind(kind :: Str) -> Bool {
  list.fold(known_kinds(), false, fn (found :: Bool, k :: Str) -> Bool {
    found or k == kind
  })
}

# The FIXED prompt template per kind — the only place a spec becomes agent
# input. The goal is interpolated as data into a constant frame; a spec can
# never smuggle in its own instructions structure.
fn prompt_for(kind :: Str, goal :: Str) -> Str {
  if kind == "build_feature" {
    str.concat("Delegated task — implement the following feature end to end, producing working code: ", goal)
  } else {
    if kind == "write_tests" {
      str.concat("Delegated task — write tests covering exactly this behaviour: ", goal)
    } else {
      if kind == "write_docs" {
        str.concat("Delegated task — write documentation for: ", goal)
      } else {
        str.concat("Delegated task — review the following work and list concrete defects, if any: ", goal)
      }
    }
  }
}

# ── Model ────────────────────────────────────────────────────────────────────
type Assignment = { id :: Str, company_id :: Str, from_role :: Str, to_role :: Str, kind :: Str, goal :: Str, status :: Str, artifact_ref :: Str, reason :: Str }

type AssignmentRow = { id :: Str, company_id :: Str, from_role :: Str, to_role :: Str, kind :: Str, params_json :: Str, status :: Str, artifact_ref :: Str, reason :: Str }

fn goal_of(params_json :: Str) -> Str {
  match jv.parse(params_json) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "goal") {
      Some(JStr(g)) => g,
      _ => "",
    },
  }
}

fn row_to_assignment(r :: AssignmentRow) -> Assignment {
  { id: r.id, company_id: r.company_id, from_role: r.from_role, to_role: r.to_role, kind: r.kind, goal: goal_of(r.params_json), status: r.status, artifact_ref: r.artifact_ref, reason: r.reason }
}

# ── The structural gate ──────────────────────────────────────────────────────
# `from_role` may assign to `to_role` iff the org chart says to_role reports
# directly to from_role. Derived from ORG1's edges, read from the DB — the
# LLM's output has no say in this.
fn may_assign(db :: conn.ConnDb, company_id :: Str, from_role :: Str, to_role :: Str) -> [sql, fs_read] Bool {
  match org.manager_of(org.load_org(db, company_id), to_role) {
    None => false,
    Some(m) => m == from_role,
  }
}

# ── Offer (gated write) ──────────────────────────────────────────────────────
fn offer(db :: conn.ConnDb, company_id :: Str, from_role :: Str, to_role :: Str, kind :: Str, goal :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Result[Str, Str] {
  if not is_known_kind(kind) {
    let __t := tr.trail(db, company_id, "delegation_refused", str.join(["{\"from\":\"", from_role, "\",\"to\":\"", to_role, "\",\"kind\":\"", kind, "\",\"reason\":\"unknown kind\"}"], ""))
    Err(str.join(["delegation refused: unknown task kind '", kind, "' (closed vocabulary: ", str.join(known_kinds(), ", "), ")"], ""))
  } else {
    if str.is_empty(str.trim(goal)) {
      let __t := tr.trail(db, company_id, "delegation_refused", str.join(["{\"from\":\"", from_role, "\",\"to\":\"", to_role, "\",\"kind\":\"", kind, "\",\"reason\":\"empty goal\"}"], ""))
      Err("delegation refused: empty goal")
    } else {
      if not may_assign(db, company_id, from_role, to_role) {
        let __t := tr.trail(db, company_id, "delegation_refused", str.join(["{\"from\":\"", from_role, "\",\"to\":\"", to_role, "\",\"kind\":\"", kind, "\",\"reason\":\"no may_assign edge\"}"], ""))
        Err(str.join(["delegation refused: '", from_role, "' has no may_assign authority over '", to_role, "' in this company's org chart"], ""))
      } else {
        let id := crypto.random_str_hex(16)
        let now := time.now_str()
        let params := jv.stringify(JObj([("goal", JStr(goal))]))
        let q := ormq.for_dialect({ sql: "INSERT INTO assignments (id, company_id, from_role, to_role, kind, params_json, status, created_at) VALUES (?, ?, ?, ?, ?, ?, 'offered', ?)", params: [PStr(id), PStr(company_id), PStr(from_role), PStr(to_role), PStr(kind), PStr(params), PStr(now)] }, db.dialect)
        match sql.exec(db.handle, q.sql, q.params) {
          Err(err) => Err(err.message),
          Ok(_) => {
            let __t := tr.trail(db, company_id, "assignment_offered", str.join(["{\"assignment\":\"", id, "\",\"from\":\"", from_role, "\",\"to\":\"", to_role, "\",\"kind\":\"", kind, "\"}"], ""))
            Ok(id)
          },
        }
      }
    }
  }
}

# ── State transitions + queries ──────────────────────────────────────────────
fn set_status(db :: conn.ConnDb, id :: Str, status :: Str, artifact_ref :: Str, reason :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "UPDATE assignments SET status=?, artifact_ref=?, reason=?, updated_at=? WHERE id=?", params: [PStr(status), PStr(artifact_ref), PStr(reason), PStr(now), PStr(id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(err) => Err(err.message),
    Ok(_) => Ok(()),
  }
}

fn load_by_status(db :: conn.ConnDb, company_id :: Str, status :: Str) -> [sql, fs_read] List[Assignment] {
  let q := ormq.for_dialect({ sql: "SELECT id, company_id, from_role, to_role, kind, params_json, status, artifact_ref, reason FROM assignments WHERE company_id=? AND status=? ORDER BY created_at ASC", params: [PStr(company_id), PStr(status)] }, db.dialect)
  let rows :: Result[List[AssignmentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, row_to_assignment),
  }
}

fn get_assignment(db :: conn.ConnDb, id :: Str) -> [sql, fs_read] Option[Assignment] {
  let q := ormq.for_dialect({ sql: "SELECT id, company_id, from_role, to_role, kind, params_json, status, artifact_ref, reason FROM assignments WHERE id=?", params: [PStr(id)] }, db.dialect)
  let rows :: Result[List[AssignmentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(row_to_assignment(r)),
    },
  }
}

# ── Materialization: an assignment as an ordinary sprint node ────────────────
fn node_id_for(a :: Assignment) -> Str {
  str.concat("assign-", str.slice(a.id, 0, 8))
}

fn node_for(a :: Assignment) -> graph.Node {
  { id: node_id_for(a), role: a.to_role, gate: "spec non-empty", expand: None, activate_when: "" }
}

# ── The delegate tool (op-call pattern: file append, gated flush) ────────────
fn delegations_file(run_id :: Str) -> Str {
  str.join(["/tmp/loom-delegations-", run_id, ".log"], "")
}

# Tool row is [net, io, proc] — it can only append a request line. The
# structural gate runs later, in flush_delegations, against the DB org chart.
fn delegate_tool(path :: Str) -> t.Tool {
  let params := { title: "Delegate", description: "Hand a typed subtask to one of your direct reports. Only roles that report to you in the company org chart can be delegated to; the request is checked against the org chart, not against this description.", fields: [s.required_str("to_role", []), s.required_str("kind", []), s.required_str("goal", [])] }
  t.define("delegate", str.join(["Delegate a subtask to a direct report. kind must be one of: ", str.join(known_kinds(), ", "), ". The goal is a plain-language statement of what the report should produce."], ""), params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let to_role := match jv.get_field(args, "to_role") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let kind := match jv.get_field(args, "kind") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let goal := match jv.get_field(args, "goal") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let prior := match io.read(path) {
      Ok(c) => c,
      Err(_) => "",
    }
    let line := jv.stringify(JObj([("to_role", JStr(to_role)), ("kind", JStr(kind)), ("goal", JStr(goal))]))
    let __w := io.write(path, str.join([prior, line, "\n"], ""))
    Ok(JObj([("ok", JBool(true)), ("note", JStr("delegation requested — it becomes an assignment only if the org chart authorizes it"))]))
  })
}

# Replay the per-run delegation requests through the gated `offer`, then
# clear the file. Returns how many became real assignments; refusals are
# already on the trail.
fn flush_delegations(db :: conn.ConnDb, company_id :: Str, from_role :: Str, path :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Int {
  let content := match io.read(path) {
    Ok(c) => c,
    Err(_) => "",
  }
  let __clear := if str.is_empty(content) {
    ()
  } else {
    let __w := io.write(path, "")
    ()
  }
  list.fold(str.split(content, "\n"), 0, fn (n :: Int, line :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Int {
    let l := str.trim(line)
    if str.is_empty(l) {
      n
    } else {
      match jv.parse(l) {
        Err(_) => n,
        Ok(j) => {
          let field := fn (k :: Str) -> Str {
            match jv.get_field(j, k) {
              Some(JStr(v)) => v,
              _ => "",
            }
          }
          match offer(db, company_id, from_role, field("to_role"), field("kind"), field("goal")) {
            Ok(_) => n + 1,
            Err(m) => {
              let __p := io.print(str.join(["[delegation] ", m], ""))
              n
            },
          }
        },
      }
    }
  })
}

