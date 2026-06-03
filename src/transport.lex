# transport.lex — the four communication planes (§4).
#
# Plane 1  Control/work    — in-process for M2; lex-jobs queue in M5.
# Plane 2  Inter-agent     — A2A via lex-soft/a2a (used by roles that
#                            call peer agents).
# Plane 3  Artifacts       — content-hash store in SQLite for M2;
#                            lex-vcs branch per sprint in M5.
# Plane 4  Trail/audit     — append-only via lex-soft/trace.
#
# Callers import only this module; swapping a plane in M5 stays local here.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "std.int" as int

import "std.io" as io

import "lex-soft/src/trace" as trace

import "lex-soft/src/a2a" as a2a

import "lex-jobs/src/jobs" as jobs

import "lex-schema/json_value" as jv

# ── Plane 4: Trail ────────────────────────────────────────────────────────────
#
# Every graph proposal, gate decision, and phase transition is appended here.
# event_kind values used by loom:
#   graph_proposed   graph_validated   graph_rejected
#   node_started     node_accepted     node_denied     node_failed
#   phase_advanced   sprint_complete
fn trail(db :: Db, sprint_id :: Str, event_kind :: Str, data :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  trace.record(db, sprint_id, sprint_id, event_kind, data)
}

# ── Plane 3: Artifacts ────────────────────────────────────────────────────────
#
# Node output is stored by content hash; handoffs carry the hash, not the
# payload. In M2 the "hash" is a random hex string — content-addressed
# storage over lex-vcs lands in M5.
type ArtifactRow = { content :: Str }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn artifact_put(db :: Db, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, fs_write, time, random, crypto] Result[Str, Str] {
  let hash := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('", sq(hash), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(content), "', '", now, "')"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(hash),
  }
}

fn artifact_get(db :: Db, hash :: Str) -> [sql, fs_read] Result[Str, Str] {
  let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
  let rows :: Result[List[ArtifactRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => match list.head(rs) {
      None => Err(str.concat("artifact not found: ", hash)),
      Some(r) => Ok(r.content),
    },
  }
}

# ── Plane 2: Inter-agent A2A ──────────────────────────────────────────────────
#
# Used by roles that need to call a peer (e.g. Architect calling an external
# design agent). For in-process M2 nodes this is rarely needed — the
# orchestrator invokes nodes directly.
fn send_a2a(db :: Db, from_id :: Str, to_id :: Str, topic :: Str, payload :: Str) -> [sql, fs_read, net, crypto, random] Result[Unit, Str] {
  a2a.send(db, from_id, to_id, topic, payload)
}

# ── Plane 1: Control / work ───────────────────────────────────────────────────
#
# M2-M4: synchronous in-process execution.
# M5: durable lex-jobs queue. Orchestrator enqueues node-jobs; workers pull,
#     execute, and write results to node_results; orchestrator polls to join.
#
# Queue name:  "loom:node"
# Handler:     "invoke"
# Payload:     JSON { sprint_id, node_id, phase, input_ref, model }
type JobInput = { sprint_id :: Str, node_id :: Str, input_ref :: Str, input_text :: Str }

type JobOutcome = JobDone(Str) | JobDenied(Str) | JobFailed(Str)

fn node_queue() -> Str {
  "loom:node"
}

fn node_handler() -> Str {
  "invoke"
}

# Serialise a node-job payload for enqueue.
fn node_job_payload(sprint_id :: Str, node_id :: Str, phase :: Str, input_ref :: Str, model :: Str) -> Str {
  jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("node_id", JStr(node_id)), ("phase", JStr(phase)), ("input_ref", JStr(input_ref)), ("model", JStr(model))]))
}

# Enqueue one node-job. Returns the lex-jobs row id.
fn enqueue_node(db :: Db, sprint_id :: Str, node_id :: Str, phase :: Str, input_ref :: Str, model :: Str) -> [sql, time] Result[Int, Str] {
  let payload := node_job_payload(sprint_id, node_id, phase, input_ref, model)
  jobs.enqueue(db, node_queue(), node_handler(), payload)
}

# Write the outcome of a node-job from the worker side.
fn write_node_result(db :: Db, sprint_id :: Str, node_id :: Str, phase :: Str, accepted :: Bool, artifact :: Str, reason :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let acc := if accepted {
    "1"
  } else {
    "0"
  }
  let q := str.join(["INSERT INTO node_results (id, sprint_id, node_id, phase, accepted, artifact, reason, created_at) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(phase), "', ", acc, ", '", sq(artifact), "', '", sq(reason), "', '", now, "')"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Read outcomes for a set of node ids. Returns only completed rows.
type NodeResultRow = { node_id :: Str, accepted :: Int, artifact :: Str, reason :: Str }

fn read_node_results(db :: Db, sprint_id :: Str, phase :: Str) -> [sql, fs_read] List[NodeResultRow] {
  let q := str.join(["SELECT node_id, accepted, artifact, reason FROM node_results WHERE sprint_id='", sq(sprint_id), "' AND phase='", sq(phase), "'"], "")
  let rows :: Result[List[NodeResultRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# Poll until all expected node_ids have results or timeout_ms elapses.
fn await_node_results(db :: Db, sprint_id :: Str, phase :: Str, node_ids :: List[Str], timeout_ms :: Int, poll_ms :: Int) -> [sql, fs_read, time, io] Result[List[NodeResultRow], Str] {
  await_loop(db, sprint_id, phase, node_ids, timeout_ms, poll_ms, 0)
}

fn await_loop(db :: Db, sprint_id :: Str, phase :: Str, node_ids :: List[Str], timeout_ms :: Int, poll_ms :: Int, elapsed_ms :: Int) -> [sql, fs_read, time, io] Result[List[NodeResultRow], Str] {
  if elapsed_ms >= timeout_ms {
    Err(str.join(["node-job await timed out after ", int.to_str(timeout_ms), "ms"], ""))
  } else {
    let results := read_node_results(db, sprint_id, phase)
    let done_ids := list.map(results, fn (r :: NodeResultRow) -> Str {
      r.node_id
    })
    let all_done := list.fold(node_ids, true, fn (ok :: Bool, id :: Str) -> Bool {
      if not ok {
        false
      } else {
        list.fold(done_ids, false, fn (found :: Bool, did :: Str) -> Bool {
          if found {
            true
          } else {
            did == id
          }
        })
      }
    })
    if all_done {
      Ok(results)
    } else {
      let __s := time.sleep_ms(poll_ms)
      await_loop(db, sprint_id, phase, node_ids, timeout_ms, poll_ms, elapsed_ms + poll_ms)
    }
  }
}

# Worker dispatch function — plug into jobs.work_forever.
# Calls invoke_node_from_payload and writes result to node_results.
# The caller must pass in the actual invoke_fn since transport.lex is
# deliberately free of orchestrator/roles imports (no circular deps).
fn make_worker_dispatch(db :: Db, invoke_fn :: (Str, Str, Str, Str, Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { accepted :: Bool, artifact :: Str, reason :: Str }) -> (Str, Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] jobs.WorkOutcome {
  fn (handler :: Str, payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] jobs.WorkOutcome {
    match handler {
      "invoke" => {
        let sprint_id := match jv.parse(payload) {
          Err(_) => "",
          Ok(j) => match jv.get_field(j, "sprint_id") {
            Some(JStr(s)) => s,
            _ => "",
          },
        }
        let node_id := match jv.parse(payload) {
          Err(_) => "",
          Ok(j) => match jv.get_field(j, "node_id") {
            Some(JStr(s)) => s,
            _ => "",
          },
        }
        let phase := match jv.parse(payload) {
          Err(_) => "",
          Ok(j) => match jv.get_field(j, "phase") {
            Some(JStr(s)) => s,
            _ => "",
          },
        }
        let input_ref := match jv.parse(payload) {
          Err(_) => "",
          Ok(j) => match jv.get_field(j, "input_ref") {
            Some(JStr(s)) => s,
            _ => "",
          },
        }
        let model := match jv.parse(payload) {
          Err(_) => "",
          Ok(j) => match jv.get_field(j, "model") {
            Some(JStr(s)) => s,
            _ => "",
          },
        }
        if str.is_empty(sprint_id) {
          Fail("invalid node-job payload: missing sprint_id or node_id")
        } else {
          if str.is_empty(node_id) {
            Fail("invalid node-job payload: missing sprint_id or node_id")
          } else {
            let result := invoke_fn(sprint_id, node_id, phase, input_ref, model)
            let __w := write_node_result(db, sprint_id, node_id, phase, result.accepted, result.artifact, result.reason)
            Done
          }
        }
      },
      _ => Fail(str.concat("unknown handler: ", handler)),
    }
  }
}

# Persist the active SprintGraph so distributed workers can look up node roles.
fn save_sprint_graph(db :: Db, sprint_id :: Str, phase :: Str, graph_json :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO sprint_graphs (id, sprint_id, phase, graph_json, created_at) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(phase), "', '", sq(graph_json), "', '", now, "')"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Record a phase transition in the phase_transitions table.
fn record_transition(db :: Db, sprint_id :: Str, from_phase :: Str, to_phase :: Str, evidence :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO phase_transitions (id, sprint_id, from_phase, to_phase, evidence, ts) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(from_phase), "', '", sq(to_phase), "', '", sq(evidence), "', '", now, "')"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

