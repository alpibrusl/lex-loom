# worker.lex — durable-queue node worker for M5 distributed execution.
#
# Pulls node-jobs from the "loom:node" queue and executes them.
# Multiple worker processes can run concurrently against the same DB
# (SQLite: single worker safe; Postgres: use FOR UPDATE SKIP LOCKED
# once lex-jobs v2 ships that fix).
#
# execute_node_job builds a real orchestrator.SprintCfg from the job payload
# and calls orchestrator.invoke_node_attempt directly — the SAME gate
# evaluation (spec compiles/sh/judge/json-verdict-pass), retry-on-denial
# loop, and cast.lex roster selection the in-process sprint path uses.
# Earlier this delegated to nothing: it checked only "is the gate string
# non-empty and the output non-empty", so ANY gate silently passed as long
# as the model said something — every spec compiles/sh/judge check in the
# whole system would have been bypassed for any node run via this path
# (#93). Fixed by sharing orchestrator's real per-node logic instead of a
# second, drifted reimplementation.
#
# Usage (one worker process):
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs \
#     src/worker.lex run_worker
#
# Environment:
#   DB_PATH      — SQLite / Postgres connection (default: loom.db)
#   MODEL        — fallback LLM model name (default: claude-haiku-4-5-20251001)
#   POLL_MS      — queue poll interval in ms (default: 500)
#   RECLAIM_LEASE_SECONDS — reclaim 'running' jobs orphaned by a dead worker
#                           after this many seconds (default: 300; 0 disables)

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "std.int" as int

import "lex-orm/src/connection" as conn

import "std.list" as list

import "lex-jobs/src/jobs" as jobs

import "lex-schema/json_value" as jv

import "lex-llm/src/provider" as prov

import "./agent/runner" as runner

import "./migrate" as migrate

import "./transport" as tr

import "./roles" as roles

import "./graph" as graph

import "./orchestrator" as orch

import "./cast" as cast

fn get_env(key :: Str, fallback :: Str) -> [env] Str {
  match env.get(key) {
    None => fallback,
    Some(v) => if str.is_empty(v) {
      fallback
    } else {
      v
    },
  }
}

# Default node-execution budget for jobs enqueued without an explicit
# api_calls_max (e.g. hand-crafted test payloads) — matches main.lex's
# own MAX_API_CALLS default.
fn default_api_calls_max() -> Int {
  200
}

# Parse and execute a single node-job payload.
#
# Builds a real orchestrator.SprintCfg (roster of one, resolved the same
# way orchestrator.select_roster would for this node) and calls
# orchestrator.invoke_node_attempt directly, so this path gets the exact
# same gate evaluation, retry-on-denial loop, and grounded checks
# (verify_compiles/verify_shell_on_output/LLM-judge) as the in-process
# sprint path — not a second, hand-rolled approximation of it.
#
# Writes the result to node_results via transport.write_node_result, and
# updates the cast agent's reputation immediately (increment on accept,
# bounce/possible-retire on denial) rather than waiting for a whole-sprint
# batch update, since a queue-driven sprint has no single synchronous
# "sprint completed" moment to batch at.
fn execute_node_job(db :: conn.ConnDb, payload :: Str, model_default :: Str, provider :: prov.Provider) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] jobs.WorkOutcome {
  match jv.parse(payload) {
    Err(_) => Fail("invalid JSON payload"),
    Ok(j) => {
      let sprint_id := match jv.get_field(j, "sprint_id") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let node_id := match jv.get_field(j, "node_id") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let phase := match jv.get_field(j, "phase") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let input_ref := match jv.get_field(j, "input_ref") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let model := match jv.get_field(j, "model") {
        Some(JStr(s)) => if str.is_empty(s) {
          model_default
        } else {
          s
        },
        _ => model_default,
      }
      let request := match jv.get_field(j, "request") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let api_calls_max := match jv.get_field(j, "api_calls_max") {
        Some(JInt(n)) => if n > 0 {
          n
        } else {
          default_api_calls_max()
        },
        _ => default_api_calls_max(),
      }
      if str.is_empty(sprint_id) {
        Fail("payload missing sprint_id or node_id")
      } else {
        if str.is_empty(node_id) {
          Fail("payload missing sprint_id or node_id")
        } else {
          let __tl := io.print(str.join(["[loom/worker] sprint=", sprint_id, " node=", node_id, " phase=", phase], ""))
          let input_content := if str.is_empty(input_ref) {
            ""
          } else {
            match tr.artifact_get(db, input_ref) {
              Err(_) => "",
              Ok(c) => c,
            }
          }
          let node_opt := load_node(db, sprint_id, node_id)
          match node_opt {
            None => Fail(str.join(["node not found in sprint graph: ", node_id], "")),
            Some(n) => {
              let roster_entry := cast.cast_node(db, n, request, model, sprint_id)
              let cfg := { id: sprint_id, request: request, model: model, db: db, api_calls_max: api_calls_max, roster: [roster_entry], trail_log: None, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline" }
              let outcome := orch.invoke_node_attempt(n, input_content, cfg, 1, "", None)
              let __rep := if str.is_empty(roster_entry.pool_agent_id) {
                ()
              } else {
                if outcome.attested {
                  cast.increment_attestation(db, roster_entry.pool_agent_id)
                } else {
                  cast.record_bounce(db, roster_entry.pool_agent_id)
                }
              }
              let __wr := tr.write_node_result(db, sprint_id, node_id, phase, outcome.attested, outcome.artifact, outcome.reason)
              let __tl2 := io.print(str.join(["[loom/worker] done node=", node_id, " attested=", if outcome.attested {
                "true"
              } else {
                "false"
              }], ""))
              if outcome.attested {
                Done
              } else {
                Fail(outcome.reason)
              }
            },
          }
        }
      }
    },
  }
}

# Load a node from the sprint_graphs table by sprint_id + node_id.
# sprint_graphs stores the full graph JSON; we parse and search.
type GraphRow = { graph_json :: Str }

fn load_node(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str) -> [sql, fs_read] Option[graph.Node] {
  let q := str.join(["SELECT graph_json FROM sprint_graphs WHERE sprint_id='", sq(sprint_id), "' ORDER BY created_at DESC LIMIT 1"], "")
  let rows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => match graph.from_json_str(r.graph_json) {
        Err(_) => None,
        Ok(g) => list.fold(g.nodes, None, fn (acc :: Option[graph.Node], n :: graph.Node) -> Option[graph.Node] {
          match acc {
            Some(_) => acc,
            None => if n.id == node_id {
              Some(n)
            } else {
              None
            },
          }
        }),
      },
    },
  }
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn poll_loop(db :: conn.ConnDb, queue :: Str, poll_ms :: Int, model :: Str, provider :: prov.Provider, lease_seconds :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  match jobs.try_claim(db.handle, queue) {
    Err(e) => io.print(str.concat("[loom/worker] claim error: ", e)),
    Ok(None) => {
      let __rc := if lease_seconds > 0 {
        match jobs.reclaim_stale(db.handle, queue, lease_seconds) {
          Err(e) => io.print(str.concat("[loom/worker] reclaim error: ", e)),
          Ok(0) => (),
          Ok(n) => io.print(str.join(["[loom/worker] reclaimed ", int.to_str(n), " stale job(s)"], "")),
        }
      } else {
        ()
      }
      let __s := time.sleep_ms(poll_ms)
      poll_loop(db, queue, poll_ms, model, provider, lease_seconds)
    },
    Ok(Some(job)) => {
      let outcome := execute_node_job(db, job.payload, model, provider)
      let __ack := match outcome {
        Done => jobs.ack(db.handle, job.id),
        Retry(reason) => jobs.retry_or_fail(db.handle, job, reason),
        Fail(reason) => jobs.fail(db.handle, job.id, reason),
      }
      poll_loop(db, queue, poll_ms, model, provider, lease_seconds)
    },
  }
}

fn run_worker() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let model := get_env("MODEL", "claude-haiku-4-5-20251001")
  let poll_ms := match str.to_int(get_env("POLL_MS", "500")) {
    None => 500,
    Some(n) => n,
  }
  let lease_seconds := match str.to_int(get_env("RECLAIM_LEASE_SECONDS", "300")) {
    None => 300,
    Some(n) => n,
  }
  let __p := io.print(str.join(["[loom/worker] starting db=", db_path, " poll_ms=", int.to_str(poll_ms), " reclaim_lease_seconds=", int.to_str(lease_seconds)], ""))
  match conn.open(db_path) {
    Err(_) => io.print("[loom/worker] FATAL open db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => io.print(str.concat("[loom/worker] FATAL migrate: ", e)),
      Ok(_) => {
        let provider := roles.make_provider()
        let __p2 := io.print("[loom/worker] listening on loom:node queue")
        poll_loop(db, tr.node_queue(), poll_ms, model, provider, lease_seconds)
      },
    },
  }
}

