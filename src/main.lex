# main.lex — entry point for a single sprint run.
#
# Usage:
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#     src/main.lex run_sprint_cmd
#
# Environment:
#   DB_PATH   — SQLite file path         (default: loom.db)
#   MODEL     — LLM model name           (default: claude-haiku-4-5-20251001)
#   REQUEST   — project request text     (default: built-in toy request)
#   SPRINT_ID — sprint identifier        (default: sprint-1)
#
# The Digest at end of sprint writes tightened specs and a seed graph to the DB.
# Run the next sprint with SPRINT_ID=sprint-2 against the same DB_PATH to
# benefit from the prior Digest (learning loop closes automatically).

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "std.list" as list

import "std.int" as int

import "./migrate" as migrate

import "./orchestrator" as orch

import "./digest" as dg

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

fn run_sprint_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let model := get_env("MODEL", "claude-haiku-4-5-20251001")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  let request := get_env("REQUEST", "Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.")
  let __p1 := io.print(str.join(["[loom] sprint=", sprint_id, " db=", db_path], ""))
  let __p2 := io.print(str.join(["[loom] request=", request], ""))
  match sql.open(db_path) {
    Err(e) => io.print(str.concat("[loom] FATAL open db: ", e.message)),
    Ok(db) => match migrate.run(db) {
      Err(e) => io.print(str.concat("[loom] FATAL migrate: ", e)),
      Ok(_) => {
        let prior_specs := dg.load_tightened_specs(db, sprint_id)
        let __ps := if list.is_empty(prior_specs) {
          io.print("[loom] no prior tightened specs (first sprint or new series)")
        } else {
          io.print(str.join(["[loom] ", int.to_str(list.len(prior_specs)), " tightened spec(s) from prior sprint loaded"], ""))
        }
        let cfg := { id: sprint_id, request: request, model: model, db: db }
        let result := orch.run_sprint(cfg)
        let status := if result.success {
          "SUCCESS"
        } else {
          "FAILED"
        }
        let __p3 := io.print(str.join(["[loom] ", status, " — ", result.summary], ""))
        ()
      },
    },
  }
}

