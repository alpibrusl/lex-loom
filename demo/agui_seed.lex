# demo/agui_seed.lex — CLI scaffolding for demo/agui-replay-roundtrip.sh.
#
# seed_cmd calls the exact real production function
# src/agui_store.lex::persist_agui_events with a realistic step sequence
# (StepDelta(TextChunk) then StepDone, matching what a real runner.step
# LLM-branch call produces) — no reimplementation, this is the same code
# path runner.lex's LLM branch calls after a node's turn finishes.

import "std.io" as io

import "std.str" as str

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-llm/src/delta" as d

import "lex-llm/src/message" as msg

import "../src/migrate" as migrate

import "../src/agui_store" as agui_store

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

fn open_db(db_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("open db failed: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "demo/agui-replay-demo.db")
  let sprint_id := get_env("SPRINT_ID", "agui-demo/iter-1")
  let run_id := get_env("RUN_ID", "run-demo-1")
  let agent_id := get_env("AGENT_ID", "loom-build")
  let text := get_env("TEXT", "here is the artifact this node produced")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[agui-demo] FATAL: ", e)),
    Ok(db) => {
      let steps := [StepDelta(TextChunk(text)), StepDone(AssistantMsg(text, []))]
      let __p := agui_store.persist_agui_events(db, run_id, sprint_id, agent_id, steps)
      io.print(str.join(["[agui-demo] persisted agui events for sprint=", sprint_id, " run=", run_id, " agent=", agent_id], ""))
    },
  }
}

