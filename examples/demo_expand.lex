# demo_expand.lex — end-to-end demo of #35 recursive nodes (node-as-loom).
#
# Two scenarios, both exercising the real orchestrator.invoke_node dispatch:
#
#   demo_depth_cap   — an expand node at depth == max_expand_depth() must be
#                      refused with a budget_exhausted trail event and NO child
#                      sprint. Deterministic, offline (no LLM call).
#
#   demo_live_child  — an expand node at depth 0 runs a full child sprint and,
#                      on success, attests the child result. Requires a model.
#
# Run:
#   DB_PATH=/tmp/demo-expand.db lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc examples/demo_expand.lex demo_depth_cap
#   MODEL=qwen3-coder:30b DB_PATH=/tmp/demo-expand.db lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc examples/demo_expand.lex demo_live_child

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/orchestrator" as orch

import "../src/graph" as graph

import "../src/cast" as cast

import "../src/pool_seed" as pool_seed

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

fn open_db(path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c),
    },
  }
}

fn print_outcome(label :: Str, o :: orch.NodeOutcome) -> [io] Unit {
  let __h := io.print(str.join(["── ", label, " ──"], ""))
  let __a := io.print(str.join(["  attested: ", if o.attested {
    "true"
  } else {
    "false"
  }], ""))
  let __s := io.print(str.join(["  sealed:   ", if o.sealed {
    "true"
  } else {
    "false"
  }], ""))
  let __ar := io.print(str.join(["  artifact: ", o.artifact], ""))
  let __r := io.print(str.join(["  reason:   ", o.reason], ""))
  ()
}

# ── Scenario 1: depth cap refusal (offline) ───────────────────────────────────
fn demo_depth_cap() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  let db_path := get_env("DB_PATH", "/tmp/demo-expand.db")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("FATAL: ", e)),
    Ok(db) => {
      let cfg := { id: "demo-depthcap", request: "parent request", model: get_env("MODEL", "gemma4:latest"), db: db, api_calls_max: 50, roster: cast.empty_roster(), trail_log: None, review_transitions: false, depth: 3, iter_ctx: None }
      let node := { id: "expander", role: "build", gate: "spec json", expand: Some("Decompose and build the sub-feature"), activate_when: "" }
      let __i := io.print("Invoking an expand node at depth 3 (== max). Expect refusal, no child sprint.")
      let outcome := orch.invoke_node(node, "", cfg, None)
      print_outcome("depth-cap outcome", outcome)
      ()
    },
  }
}

# ── Scenario 2: live child sprint (needs a model) ─────────────────────────────
fn demo_live_child() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs] Unit {
  let db_path := get_env("DB_PATH", "/tmp/demo-expand.db")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("FATAL: ", e)),
    Ok(db) => {
      let __seed := pool_seed.seed(db)
      let cfg := { id: "demo-live", request: "Build a tiny math utility", model: get_env("MODEL", "qwen3-coder:30b"), db: db, api_calls_max: 60, roster: cast.empty_roster(), trail_log: None, review_transitions: false, depth: 0, iter_ctx: None }
      let node := { id: "math_feature", role: "build", gate: "spec json", expand: Some("Write a pure Lex function add(a :: Int, b :: Int) -> Int that returns a + b, with an examples block."), activate_when: "" }
      let __i := io.print("Invoking an expand node at depth 0. Expect a full child sprint to run and attest.")
      let outcome := orch.invoke_node(node, "", cfg, None)
      print_outcome("live-child outcome", outcome)
      ()
    },
  }
}

