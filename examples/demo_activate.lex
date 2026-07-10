# demo_activate.lex — C4 proof: a node gated `iter ge 2` is skipped in iteration
# 1 (offline, no LLM) and would run in iteration 2. Exercises the real
# orchestrator.invoke_node activation dispatch.

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/orchestrator" as orch

import "../src/cast" as cast

fn open_db(path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c),
    },
  }
}

fn demo_skip() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  match open_db("/tmp/demo-activate.db") {
    Err(e) => io.print(str.concat("FATAL: ", e)),
    Ok(db) => {
      let ctx1 := { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0, spend_cents: 0 }
      let cfg := { id: "demo-activate", request: "r", model: "none", db: db, api_calls_max: 10, roster: cast.empty_roster(), trail_log: None, review_transitions: false, depth: 0, iter_ctx: Some(ctx1), exec_mode: "inline" }
      let node := { id: "growth_subloom", role: "build", gate: "spec true", expand: None, activate_when: "iter ge 2" }
      let outcome := orch.invoke_node(node, "", cfg, None)
      let __r := io.print(str.join(["[demo] iter=1 node gated 'iter ge 2' -> sealed=", if outcome.sealed {
        "true"
      } else {
        "false"
      }, " reason=", outcome.reason], ""))
      ()
    },
  }
}

