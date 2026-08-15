# test_blocking_gates.lex — GOV1 (lex-loom#221): blocking human gates.
#
# The full park -> resolve -> resume/cancel state machine, exercised against
# the REAL orchestrator.run_phase with proc-executor agents (`cat` — input in,
# input out), so every assertion runs offline: no LLM, no network. The gate
# DSL parsing is asserted pure.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "lex-llm/src/providers" as providers

import "../src/migrate" as migrate

import "../src/gates" as gates

import "../src/graph" as graph

import "../src/orchestrator" as orch

import "../src/cast" as cast

import "../src/agent/runner" as runner

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

# ── Gate DSL parsing (pure) ───────────────────────────────────────────────────
fn test_blocking_parse() -> Result[Unit, Str] {
  match check("plain human gate is not blocking", not gates.is_blocking("human legal")) {
    Err(e) => Err(e),
    Ok(_) => match check("blocking modifier parses", gates.is_blocking("human legal blocking")) {
      Err(e) => Err(e),
      Ok(_) => match check("oracle name survives the modifier", gates.oracle_of("human legal blocking") == "legal") {
        Err(e) => Err(e),
        Ok(_) => match check("no timeout by default", gates.blocking_timeout_hours("human legal blocking") == 0) {
          Err(e) => Err(e),
          Ok(_) => match check("timeout hours parse", gates.blocking_timeout_hours("human legal blocking 48h") == 48) {
            Err(e) => Err(e),
            Ok(_) => check("spec gates are never blocking", not gates.is_blocking("spec non-empty")),
          },
        },
      },
    },
  }
}

# ── Offline harness: proc agents + a hand-built graph ────────────────────────
fn proc_agent(node_id :: Str) -> cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: "docs", system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn gate_graph(sprint_id :: Str) -> graph.SprintGraph {
  { id: sprint_id, phase: Implementation, nodes: [{ id: "legal_review", role: "docs", gate: "human legal blocking", expand: None, activate_when: "" }, { id: "publish", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "docs", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "legal_review", to: "publish", handoff: "schema {}" }] }
}

fn mk_cfg(db :: conn.ConnDb, sprint_id :: Str) -> orch.SprintCfg {
  let trail_none :: Option[tlog.Log] := None
  { id: sprint_id, request: "demo request", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("legal_review"), proc_agent("publish"), proc_agent("docs")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
}

fn outcome_for(outcomes :: List[orch.NodeOutcome], node_id :: Str) -> Option[orch.NodeOutcome] {
  list.fold(outcomes, None, fn (acc :: Option[orch.NodeOutcome], o :: orch.NodeOutcome) -> Option[orch.NodeOutcome] {
    match acc {
      Some(_) => acc,
      None => if o.node_id == node_id {
        Some(o)
      } else {
        None
      },
    }
  })
}

fn open_db() -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open memory db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

# Pass 1: the blocking gate parks itself and its dependent subtree; the
# independent node completes; parked is NOT failure.
fn test_park_holds_subtree_and_continues_independent() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let sid := str.concat("gov1-park-", crypto.random_str_hex(6))
      let cfg := mk_cfg(db, sid)
      let g := gate_graph(sid)
      let pr := orch.run_phase(g, Implementation, "", [], cfg)
      match outcome_for(pr.outcomes, "legal_review") {
        None => Err("no outcome for legal_review"),
        Some(o1) => match check("gate node parked", str.starts_with(o1.reason, "PARKED ")) {
          Err(e) => Err(e),
          Ok(_) => match outcome_for(pr.outcomes, "publish") {
            None => Err("no outcome for publish"),
            Some(o2) => match check("dependent subtree held", o2.reason == "PARKED downstream of a blocking human gate") {
              Err(e) => Err(e),
              Ok(_) => match outcome_for(pr.outcomes, "docs") {
                None => Err("no outcome for docs"),
                Some(o3) => match check("independent track completed", o3.attested and o3.sealed) {
                  Err(e) => Err(e),
                  Ok(_) => match check("parked is not failure (phase success)", pr.success) {
                    Err(e) => Err(e),
                    Ok(_) => check("exactly one attention item pending", list.len(tr.attention_pending_for_sprint(db, sid)) == 1),
                  },
                },
              },
            },
          },
        },
      }
    },
  }
}

# Approve, re-enter: the gate seals from the human-attested artifact without
# re-running the node or pushing a duplicate item; downstream now runs.
fn test_approve_resumes_downstream() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let sid := str.concat("gov1-approve-", crypto.random_str_hex(6))
      let cfg := mk_cfg(db, sid)
      let g := gate_graph(sid)
      let __p1 := orch.run_phase(g, Implementation, "", [], cfg)
      match list.head(tr.attention_pending_for_sprint(db, sid)) {
        None => Err("expected a pending attention item after pass 1"),
        Some(item) => {
          let __r := tr.resolve_attention(db, item.id, "approved", "", "board-jane")
          let pr := orch.run_phase(g, Implementation, "", [], cfg)
          match outcome_for(pr.outcomes, "legal_review") {
            None => Err("no outcome for legal_review on re-entry"),
            Some(o1) => match check("approved gate seals with the attested artifact", o1.attested and o1.sealed and o1.artifact == item.artifact_hash) {
              Err(e) => Err(e),
              Ok(_) => match outcome_for(pr.outcomes, "publish") {
                None => Err("no outcome for publish on re-entry"),
                Some(o2) => match check("downstream resumed and completed", o2.attested) {
                  Err(e) => Err(e),
                  Ok(_) => match check("phase succeeded after approval", pr.success) {
                    Err(e) => Err(e),
                    Ok(_) => check("no duplicate attention item pushed", list.is_empty(tr.attention_pending_for_sprint(db, sid))),
                  },
                },
              },
            },
          }
        },
      }
    },
  }
}

# Reject, re-enter: the subtree cancels with the board's reason on the trail;
# nothing downstream of the rejected gate ever runs; no auto-approve exists.
fn test_reject_cancels_subtree() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let sid := str.concat("gov1-reject-", crypto.random_str_hex(6))
      let cfg := mk_cfg(db, sid)
      let g := gate_graph(sid)
      let __p1 := orch.run_phase(g, Implementation, "", [], cfg)
      match list.head(tr.attention_pending_for_sprint(db, sid)) {
        None => Err("expected a pending attention item after pass 1"),
        Some(item) => {
          let __r := tr.resolve_attention(db, item.id, "rejected", "not legally publishable", "board-jane")
          let pr := orch.run_phase(g, Implementation, "", [], cfg)
          match outcome_for(pr.outcomes, "legal_review") {
            None => Err("no outcome for legal_review on re-entry"),
            Some(o1) => match check("rejected gate cancels with the board's reason", not o1.attested and str.contains(o1.reason, "cancelled by board-jane: not legally publishable")) {
              Err(e) => Err(e),
              Ok(_) => match check("cancellation is on the trail", tr.trail_contains(db, sid, "node_cancelled", item.id)) {
                Err(e) => Err(e),
                Ok(_) => match check("rejection fails the phase", not pr.success) {
                  Err(e) => Err(e),
                  Ok(_) => check("nothing downstream of the rejected gate ran", match outcome_for(pr.outcomes, "publish") {
                    None => true,
                    Some(o2) => not o2.attested,
                  }),
                },
              },
            },
          }
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_blocking_parse(), test_park_holds_subtree_and_continues_independent(), test_approve_resumes_downstream(), test_reject_cancels_subtree()]
}

fn run_all() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

