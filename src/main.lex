# main.lex — entry point for a single sprint run.
#
# Usage:
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#     src/main.lex run_sprint_cmd
#
# Environment:
#   DB_PATH   — SQLite file path (default: loom.db)
#   MODEL     — LLM model name  (default: claude-haiku-4-5-20251001)
#   REQUEST   — project request text (default: built-in toy request)
#   SPRINT_ID — sprint identifier    (default: sprint-1)

import "std.env" as env
import "std.io"  as io
import "std.str" as str
import "std.sql" as sql

import "./migrate"      as migrate
import "./orchestrator" as orch

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None    => default,
    Some(v) => if str.is_empty(v) { default } else { v },
  }
}

fn run_sprint_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let db_path   := get_env("DB_PATH",   "loom.db")
  let model     := get_env("MODEL",     "claude-haiku-4-5-20251001")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  let request   := get_env("REQUEST",   "Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.")

  let __p1 := io.print(str.join(["[loom] sprint=", sprint_id, " db=", db_path], ""))
  let __p2 := io.print(str.join(["[loom] request=", request], ""))

  match sql.open(db_path) {
    Err(e) => io.print(str.concat("[loom] FATAL open db: ", e.message)),
    Ok(db) =>
      match migrate.run(db) {
        Err(e) => io.print(str.concat("[loom] FATAL migrate: ", e)),
        Ok(_) => {
          let cfg := {
            id:      sprint_id,
            request: request,
            model:   model,
            db:      db,
          }
          let result := orch.run_sprint(cfg)
          let __p3 := io.print(str.join(["[loom] ", if result.success { "SUCCESS" } else { "FAILED" }, " — ", result.summary], ""))
          ()
        },
      },
  }
}
