# transport.lex — the four communication planes (§4).

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "std.int" as int

import "std.io" as io

import "lex-orm/src/connection" as conn

import "./agent/trace" as trace

import "./agent/a2a" as a2a

import "lex-jobs/src/jobs" as jobs

import "lex-schema/json_value" as jv

import "std.vcs" as vcs

# ── Plane 4: Trail ────────────────────────────────────────────────────────────
fn trail(db :: conn.ConnDb, sprint_id :: Str, event_kind :: Str, data :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  trace.record(db, sprint_id, sprint_id, event_kind, data)
}

type TrailCountRow = { n :: Int }

fn count_trail_events(db :: conn.ConnDb, sprint_id :: Str, event_kind :: Str) -> [sql, fs_read] Int {
  let q := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind='", sq(event_kind), "'"], "")
  let rows :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# ── Plane 3: Artifacts ────────────────────────────────────────────────────────
type ArtifactRow = { content :: Str }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

# Branch-per-sprint ref namespace in the vcs store (#5): one namespace per
# sprint, keyed by node id → blob sha. e.g. "loom/sprint-portfolio-1".
fn sprint_ns(sprint_id :: Str) -> Str {
  str.concat("loom/sprint-", sprint_id)
}

# Mirror an artifact into the content-addressed vcs store + branch-per-sprint
# ref (#5 / M6.1c). Best-effort: the SQLite row is the source of truth, so a
# missing/unwritable store does not fail the put. The vcs blob sha is identical
# to the SQLite hash (both crypto.sha256_str), so the two backends are
# interchangeable by id — `lex` store tooling can read sprint artifacts, and
# `vcs.ref_get(sprint_ns(id), node)` lists a sprint's outputs.
#
# Returns the failure reason instead of swallowing it (lex-loom#196) — a
# missing/unwritable store is still not fatal to the put, but the caller now
# has what it needs to make that failure visible rather than leaving the
# audit trail silently incomplete with no way to discover it happened.
fn mirror_vcs(sprint_id :: Str, node_id :: Str, content :: Str, hash :: Str) -> [vcs, fs_write, fs_read] Result[Unit, Str] {
  match vcs.put_blob(content) {
    Err(e) => Err(str.concat("put_blob: ", e)),
    Ok(_) => match vcs.ref_set(sprint_ns(sprint_id), node_id, hash) {
      Err(e) => Err(str.concat("ref_set: ", e)),
      Ok(_) => Ok(()),
    },
  }
}

# Content-addressed (#5 / M6.0): the hash is the SHA-256 of the content itself,
# so identical content always yields the same id. INSERT OR IGNORE makes a
# re-store of the same content idempotent (the first writer's sprint_id/node_id
# metadata stays); the SHA is returned either way so callers get a stable ref.
# M6.1c: also mirrored into the vcs blob store + branch-per-sprint ref.
#
# A mirror failure never fails the put (the SQLite row is still the source of
# truth) but is now recorded as a queryable "loom.artifact.mirror_failed"
# trace row (lex-loom#196) — previously this was `Err(_) => ()`, a
# disk-full/permissions/wrong-path failure across an entire sprint left
# zero trace anywhere that the mirror was incomplete.
fn artifact_put(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, fs_write, fs_read, time, random, crypto, vcs] Result[Str, Str] {
  let hash := crypto.sha256_str(content)
  let now := time.now_str()
  let q := str.join(["INSERT OR IGNORE INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES ('", sq(hash), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(content), "', '", now, "')"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => {
      let __m := match mirror_vcs(sprint_id, node_id, content, hash) {
        Ok(_) => (),
        Err(reason) => trail(db, sprint_id, "loom.artifact.mirror_failed", jv.stringify(JObj([("node_id", JStr(node_id)), ("hash", JStr(hash)), ("reason", JStr(reason))]))),
      }
      Ok(hash)
    },
  }
}

# Read by content hash: try the vcs blob store first (cross-sprint, store-backed),
# fall back to the SQLite artifacts table (offline / single-process). The sha is
# the same in both, so either backend answers correctly.
fn artifact_get(db :: conn.ConnDb, hash :: Str) -> [sql, fs_read, vcs] Result[Str, Str] {
  match vcs.get_blob(hash) {
    Ok(content) => Ok(content),
    Err(_) => {
      let q := str.join(["SELECT content FROM artifacts WHERE hash='", sq(hash), "'"], "")
      let rows :: Result[List[ArtifactRow], SqlError] := sql.query(db.handle, q, [])
      match rows {
        Err(e) => Err(e.message),
        Ok(rs) => match list.head(rs) {
          None => Err(str.concat("artifact not found: ", hash)),
          Some(r) => Ok(r.content),
        },
      }
    },
  }
}

# Which node produced a given artifact hash. Used by transition review to bounce
# an insufficient handoff back to the agent that produced it. None if unknown.
type NodeIdRow = { node_id :: Str }

fn artifact_node_id(db :: conn.ConnDb, hash :: Str) -> [sql, fs_read] Option[Str] {
  let q := str.join(["SELECT node_id FROM artifacts WHERE hash='", sq(hash), "'"], "")
  let rows :: Result[List[NodeIdRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.node_id),
    },
  }
}

# ── Plane 2: Inter-agent A2A ──────────────────────────────────────────────────
fn send_a2a(db :: conn.ConnDb, from_id :: Str, to_id :: Str, topic :: Str, payload :: Str) -> [sql, fs_read, net, crypto, random] Result[Unit, Str] {
  a2a.send(db, from_id, to_id, topic, payload)
}

# ── Plane 1: Control / work ───────────────────────────────────────────────────
type JobInput = { sprint_id :: Str, node_id :: Str, input_ref :: Str, input_text :: Str }

type JobOutcome = JobDone(Str) | JobDenied(Str) | JobFailed(Str)

fn node_queue() -> Str {
  "loom:node"
}

fn node_handler() -> Str {
  "invoke"
}

# `request` (the sprint's original request text) and `api_calls_max` are
# carried so the worker can build a real orchestrator.SprintCfg and call
# orchestrator.invoke_node_attempt directly — the same gate/retry/roster
# logic the in-process path uses, instead of a separately-maintained
# reimplementation that drifts (#93).
fn node_job_payload(sprint_id :: Str, node_id :: Str, phase :: Str, input_ref :: Str, model :: Str, request :: Str, api_calls_max :: Int) -> Str {
  jv.stringify(JObj([("sprint_id", JStr(sprint_id)), ("node_id", JStr(node_id)), ("phase", JStr(phase)), ("input_ref", JStr(input_ref)), ("model", JStr(model)), ("request", JStr(request)), ("api_calls_max", JInt(api_calls_max))]))
}

fn enqueue_node(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, phase :: Str, input_ref :: Str, model :: Str, request :: Str, api_calls_max :: Int) -> [sql, time] Result[Int, Str] {
  let payload := node_job_payload(sprint_id, node_id, phase, input_ref, model, request, api_calls_max)
  jobs.enqueue(db.handle, node_queue(), node_handler(), payload)
}

# Delete any row(s) already recorded for (sprint_id, phase, node_id) before
# enqueueing a fresh job for that node. `read_node_results`/`await_node_results`
# key their "is this node done yet" check on node_id+phase alone, with no
# per-enqueue generation marker — dynamic-extension rounds (#run_extensions)
# reuse the SAME phase name ("Implementation") and the SAME node ids (e.g.
# "py_build-api", "py_qa-tests") every round, so a STALE accepted row from an
# earlier round satisfied a later round's await instantly, letting the
# orchestrator race ahead to Demo/Digest/Complete while the real job for that
# round was still running on a worker — which then wrote its own late
# node_started/node_accepted trace events well after the sprint had already
# "completed". Found live running a real company (tzconvert): sprint_complete
# fired with fully_sealed:false while a passing py_qa-tests/launch-api round
# was still landing. Clearing the stale row first forces await_node_results
# to see only a row written by THIS round's job.
fn clear_node_result(db :: conn.ConnDb, sprint_id :: Str, phase :: Str, node_id :: Str) -> [sql] Result[Unit, Str] {
  let q := str.join(["DELETE FROM node_results WHERE sprint_id='", sq(sprint_id), "' AND phase='", sq(phase), "' AND node_id='", sq(node_id), "'"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn write_node_result(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, phase :: Str, accepted :: Bool, artifact :: Str, reason :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let acc := if accepted {
    "1"
  } else {
    "0"
  }
  let q := str.join(["INSERT INTO node_results (id, sprint_id, node_id, phase, accepted, artifact, reason, created_at) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(phase), "', ", acc, ", '", sq(artifact), "', '", sq(reason), "', '", now, "')"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type NodeResultRow = { node_id :: Str, accepted :: Int, artifact :: Str, reason :: Str }

fn read_node_results(db :: conn.ConnDb, sprint_id :: Str, phase :: Str) -> [sql, fs_read] List[NodeResultRow] {
  let q := str.join(["SELECT node_id, accepted, artifact, reason FROM node_results WHERE sprint_id='", sq(sprint_id), "' AND phase='", sq(phase), "'"], "")
  let rows :: Result[List[NodeResultRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn await_node_results(db :: conn.ConnDb, sprint_id :: Str, phase :: Str, node_ids :: List[Str], timeout_ms :: Int, poll_ms :: Int) -> [sql, fs_read, time, io] Result[List[NodeResultRow], Str] {
  await_loop(db, sprint_id, phase, node_ids, timeout_ms, poll_ms, 0)
}

fn await_loop(db :: conn.ConnDb, sprint_id :: Str, phase :: Str, node_ids :: List[Str], timeout_ms :: Int, poll_ms :: Int, elapsed_ms :: Int) -> [sql, fs_read, time, io] Result[List[NodeResultRow], Str] {
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

fn make_worker_dispatch(db :: conn.ConnDb, invoke_fn :: (Str, Str, Str, Str, Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] { accepted :: Bool, artifact :: Str, reason :: Str }) -> (Str, Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] jobs.WorkOutcome {
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

# ── Attention queue ────────────────────────────────────────────────────────────
type AttentionRow = { id :: Str, sprint_id :: Str, node_id :: Str, gate :: Str, oracle :: Str, artifact_hash :: Str, verdict :: Str, rejection_reason :: Str, created_at :: Str }

fn push_attention(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, gate :: Str, oracle :: Str, artifact_hash :: Str) -> [sql, fs_write, time, random, crypto] Result[Str, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO attention_queue (id, sprint_id, node_id, gate, oracle, artifact_hash, verdict, created_at) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(node_id), "', '", sq(gate), "', '", sq(oracle), "', '", sq(artifact_hash), "', 'pending', '", now, "')"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(id),
  }
}

fn list_attention_pending(db :: conn.ConnDb) -> [sql, fs_read] List[AttentionRow] {
  let q := "SELECT id, sprint_id, node_id, gate, oracle, artifact_hash, verdict, rejection_reason, created_at FROM attention_queue WHERE verdict='pending' ORDER BY created_at ASC"
  let rows :: Result[List[AttentionRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn resolve_attention(db :: conn.ConnDb, id :: Str, verdict :: Str, reason :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := str.join(["UPDATE attention_queue SET verdict='", sq(verdict), "', rejection_reason='", sq(reason), "', resolved_at='", now, "' WHERE id='", sq(id), "'"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn save_sprint_graph(db :: conn.ConnDb, sprint_id :: Str, phase :: Str, graph_json :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO sprint_graphs (id, sprint_id, phase, graph_json, created_at) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(phase), "', '", sq(graph_json), "', '", now, "')"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn record_transition(db :: conn.ConnDb, sprint_id :: Str, from_phase :: Str, to_phase :: Str, evidence :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO phase_transitions (id, sprint_id, from_phase, to_phase, evidence, ts) VALUES ('", sq(id), "', '", sq(sprint_id), "', '", sq(from_phase), "', '", sq(to_phase), "', '", sq(evidence), "', '", now, "')"], "")
  match sql.exec(db.handle, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

