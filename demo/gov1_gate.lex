# demo/gov1_gate.lex — CLI scaffolding for demo/gov1-blocking-gate-roundtrip.sh.
#
# Drives the REAL orchestrator.run_phase over a 3-node graph with a
# `human legal blocking` gate, using proc-executor agents (`cat`) so the whole
# round-trip runs offline. Each pass_cmd invocation is a separate process —
# park state lives entirely in the DB, exactly as a scheduler-resumed company
# would see it.
#
#   pass_cmd  (DB_PATH, SPRINT_ID) — run the phase once and print per-node
#             outcomes as "node|attested|reason" lines plus a PHASE| summary.

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

fn proc_agent(node_id :: Str) -> cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: "docs", system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn gate_graph(sprint_id :: Str) -> graph.SprintGraph {
  { id: sprint_id, phase: Implementation, nodes: [{ id: "legal_review", role: "docs", gate: "human legal blocking", expand: None, activate_when: "" }, { id: "publish", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "independent_docs", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "legal_review", to: "publish", handoff: "schema {}" }] }
}

fn pass_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let db_path := get_env("DB_PATH", "gov1-demo.db")
  let sprint_id := get_env("SPRINT_ID", "gov1-demo")
  match conn.open(db_path) {
    Err(_) => io.print("[gov1-demo] FATAL: open db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => io.print(str.concat("[gov1-demo] FATAL: ", e)),
      Ok(_) => {
        let trail_none :: Option[tlog.Log] := None
        let cfg := { id: sprint_id, request: "publish the launch blog post", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("legal_review"), proc_agent("publish"), proc_agent("independent_docs")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
        let pr := orch.run_phase(gate_graph(sprint_id), Implementation, "", [], cfg)
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

