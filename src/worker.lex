# worker.lex — durable-queue node worker for M5 distributed execution.
#
# Pulls node-jobs from the "loom:node" queue and executes them.
# Multiple worker processes can run concurrently against the same DB
# (SQLite: single worker safe; Postgres: use FOR UPDATE SKIP LOCKED
# once lex-jobs v2 ships that fix).
#
# Usage (one worker process):
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#     src/worker.lex run_worker
#
# Environment:
#   DB_PATH      — SQLite / Postgres connection (default: loom.db)
#   MODEL        — fallback LLM model name (default: claude-haiku-4-5-20251001)
#   POLL_MS      — queue poll interval in ms (default: 500)

import "std.env"  as env
import "std.io"   as io
import "std.str"  as str
import "std.sql"  as sql
import "std.int"  as int
import "std.list" as list

import "lex-jobs/src/jobs"     as jobs
import "lex-schema/json_value" as jv
import "lex-agent/src/message" as msg
import "lex-soft/src/runner"   as runner

import "./migrate"    as migrate
import "./transport"  as tr
import "./roles"      as roles
import "./graph"      as graph

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None    => default,
    Some(v) => if str.is_empty(v) { default } else { v },
  }
}

# Parse and execute a single node-job payload.
# Writes the result to node_results via transport.write_node_result.
fn execute_node_job(db :: Db, payload :: Str, model_default :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] jobs.WorkOutcome {
  match jv.parse(payload) {
    Err(_) => Fail("invalid JSON payload"),
    Ok(j) => {
      let sprint_id := match jv.get_field(j, "sprint_id") { Some(JStr(s)) => s, _ => "" }
      let node_id   := match jv.get_field(j, "node_id")   { Some(JStr(s)) => s, _ => "" }
      let phase     := match jv.get_field(j, "phase")     { Some(JStr(s)) => s, _ => "" }
      let input_ref := match jv.get_field(j, "input_ref") { Some(JStr(s)) => s, _ => "" }
      let model     := match jv.get_field(j, "model")     { Some(JStr(s)) => if str.is_empty(s) { model_default } else { s }, _ => model_default }

      if str.is_empty(sprint_id) || str.is_empty(node_id) {
        Fail("payload missing sprint_id or node_id")
      } else {
        let __tl := io.print(str.join(["[loom/worker] sprint=", sprint_id, " node=", node_id, " phase=", phase], ""))

        # Resolve input artifact content
        let input_content := if str.is_empty(input_ref) {
          ""
        } else {
          match tr.artifact_get(db, input_ref) {
            Err(_) => "",
            Ok(c)  => c,
          }
        }

        # Resolve node from graph stored in sprint_graphs table
        # For M5 we look up the role from a node_roles helper table;
        # for now we use a default build role if lookup fails.
        let node_opt := load_node(db, sprint_id, node_id)
        match node_opt {
          None => Fail(str.join(["node not found in sprint graph: ", node_id], "")),
          Some(n) => {
            match roles.for_role(n.role, model) {
              None => Fail(str.join(["unknown role: ", n.role], "")),
              Some(agent_cfg) => {
                let handler := runner.make_handler(db, agent_cfg)
                let in_msg  := msg.user_text(if str.is_empty(input_content) { sprint_id } else { input_content })
                let outcome := handler(in_msg)
                let output  := match outcome.reply {
                  None    => "",
                  Some(m) => match list.head(m.parts) {
                    None              => "",
                    Some(TextPart(s)) => s,
                    Some(_)           => "",
                  },
                }
                let accepted := !str.is_empty(output) && !str.is_empty(n.gate)
                let reason   := if accepted { "" } else { "empty output or missing gate" }
                let artifact := if accepted {
                  match tr.artifact_put(db, sprint_id, node_id, output) {
                    Err(_) => "",
                    Ok(h)  => h,
                  }
                } else {
                  ""
                }
                let __wr := tr.write_node_result(db, sprint_id, node_id, phase, accepted, artifact, reason)
                let __tl2 := io.print(str.join(["[loom/worker] done node=", node_id, " accepted=", if accepted { "true" } else { "false" }], ""))
                Done
              },
            }
          },
        }
      }
    },
  }
}

# Load a node from the sprint_graphs table by sprint_id + node_id.
# sprint_graphs stores the full graph JSON; we parse and search.
type GraphRow = { graph_json :: Str }

fn load_node(db :: Db, sprint_id :: Str, node_id :: Str) -> [sql, fs_read] Option[graph.Node] {
  let q := str.join([
    "SELECT graph_json FROM sprint_graphs WHERE sprint_id='",
    sq(sprint_id), "' ORDER BY created_at DESC LIMIT 1"
  ], "")
  let rows :: Result[List[GraphRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_)  => None,
    Ok(rs)  => match list.head(rs) {
      None    => None,
      Some(r) => match graph.from_json_str(r.graph_json) {
        Err(_) => None,
        Ok(g)  => list.fold(g.nodes, None, fn (acc :: Option[graph.Node], n :: graph.Node) -> Option[graph.Node] {
          match acc {
            Some(_) => acc,
            None    => if n.id == node_id { Some(n) } else { None },
          }
        }),
      },
    },
  }
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn run_worker() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let db_path  := get_env("DB_PATH",  "loom.db")
  let model    := get_env("MODEL",    "claude-haiku-4-5-20251001")
  let poll_ms  := match int.from_str(get_env("POLL_MS", "500")) {
    None    => 500,
    Some(n) => n,
  }

  let __p := io.print(str.join(["[loom/worker] starting db=", db_path, " poll_ms=", int.to_str(poll_ms)], ""))

  match sql.open(db_path) {
    Err(e) => io.print(str.concat("[loom/worker] FATAL open db: ", e.message)),
    Ok(db) =>
      match migrate.run(db) {
        Err(e) => io.print(str.concat("[loom/worker] FATAL migrate: ", e)),
        Ok(_) => {
          let dispatch := fn (handler :: Str, payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
            match handler {
              "invoke" => execute_node_job(db, payload, model),
              _        => Fail(str.concat("unknown handler: ", handler)),
            }
          }
          let __p2 := io.print("[loom/worker] listening on loom:node queue")
          match jobs.work_forever(db, tr.node_queue(), poll_ms, dispatch) {
            Err(e) => io.print(str.concat("[loom/worker] worker exited: ", e)),
            Ok(_)  => (),
          }
        },
      },
  }
}
