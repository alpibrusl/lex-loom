# demo/pilot_seed.lex — CLI scaffolding for demo/pilot-verify-roundtrip.sh
# (#68, Phase 3: independent verification of a run you did not produce).
#
# Party A ("the operator") runs a REAL 2-node sprint through the actual
# orchestrator with proc-executor agents (`cat`), fully offline — the same
# machinery a model-driven run uses writes the same record: node_accepted
# trail events referencing content-addressed artifact hashes, op_grant
# authority events, artifacts in the DB. Nothing here fabricates rows; the
# point of the pilot demo is that the record being verified was produced
# by the real run path.
#
#   run_cmd (DB_PATH, SPRINT_ID) — run the sprint once; print per-node
#           outcomes as "node|attested|reason" lines plus a PHASE| summary.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "lex-llm/src/providers" as providers

import "../src/migrate" as migrate

import "../src/graph" as graph

import "../src/orchestrator" as orch

import "../src/cast" as cast

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None => default,
    Some(v) => if str.is_empty(v) {
      default
    } else {
      v
    },
  }
}

fn proc_agent(node_id :: Str) -> [env] cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: "docs", system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn pilot_graph(sprint_id :: Str) -> graph.SprintGraph {
  { id: sprint_id, phase: Implementation, nodes: [{ id: "write_docs", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "summarize", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "write_docs", to: "summarize", handoff: "schema {}" }] }
}

fn run_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let db_path := get_env("DB_PATH", "pilot-demo.db")
  let sprint_id := get_env("SPRINT_ID", "pilot-demo")
  match conn.open(db_path) {
    Err(_) => io.print("[pilot-demo] FATAL: open db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => io.print(str.concat("[pilot-demo] FATAL: ", e)),
      Ok(_) => {
        let trail_none :: Option[tlog.Log] := None
        let cfg := { id: sprint_id, request: "write the pilot quickstart docs", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("write_docs"), proc_agent("summarize")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
        let pr := orch.run_phase(pilot_graph(sprint_id), Implementation, "", [], cfg)
        let __each := list.map(pr.outcomes, fn (o :: orch.NodeOutcome) -> [io] Unit {
          io.print(str.join([o.node_id, "|", if o.attested {
            "attested"
          } else {
            "held"
          }, "|", str.slice(o.reason, 0, 80)], ""))
        })
        io.print(str.concat("PHASE|", if pr.success {
          "success"
        } else {
          "failed"
        }))
      },
    },
  }
}

