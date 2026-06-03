# server/mcp.lex — MCP stdio front door for loom (§14).
#
# Exposes the same sprint controls as server/a2a.lex via the MCP stdio
# transport so Claude Code, Cursor, and any MCP-compatible client can
# start and inspect sprints as tool calls.
#
# Tools exposed (one per A2A skill):
#   start_sprint   — start a new sprint
#   sprint_status  — query current state
#   sprint_trail   — fetch trail events
#   sprint_digest  — fetch Digest artifacts
#
# Usage:
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#     src/server/mcp.lex run_mcp_server
#
# Environment:
#   DB_PATH       — SQLite file path  (default: loom.db)
#   MODEL         — LLM model default (default: claude-haiku-4-5-20251001)
#   LOOM_BASE_URL — base URL for A2A AgentCard (default: http://localhost:9100)

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "lex-mcp/src/server" as mcp_server

import "../migrate" as migrate

import "./a2a" as a2a_server

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

fn run_mcp_server() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let model := get_env("MODEL", "claude-haiku-4-5-20251001")
  let base_url := get_env("LOOM_BASE_URL", "http://localhost:9100")
  match sql.open(db_path) {
    Err(e) => io.print(str.concat("[loom/mcp] FATAL open db: ", e.message)),
    Ok(db) => match migrate.run(db) {
      Err(e) => io.print(str.concat("[loom/mcp] FATAL migrate: ", e)),
      Ok(_) => {
        let agent := a2a_server.make_agent(db, model, base_url)
        mcp_server.run(agent)
      },
    },
  }
}

