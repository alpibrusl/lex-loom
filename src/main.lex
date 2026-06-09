# main.lex — entry point for sprint operations.
#
# Commands (set via the function name passed to `lex run`):
#
#   run_sprint_cmd   — run a full sprint (Intake→Digest)
#   sprint_status    — show phase, outcomes, and trail summary for a sprint
#   sprint_trail     — print the full trail for a sprint
#   sprint_digest    — print the Digest artifacts (lessons + tightened specs)
#
# Usage:
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc \
#     src/main.lex run_sprint_cmd
#
#   lex run --allow-effects env,io,sql,fs_read src/main.lex sprint_status
#   lex run --allow-effects env,io,sql,fs_read src/main.lex sprint_trail
#   lex run --allow-effects env,io,sql,fs_read src/main.lex sprint_digest
#
# Environment:
#   DB_PATH       — SQLite file path         (default: loom.db)
#   MODEL         — LLM model name           (default: gemma4:latest)
#   REQUEST       — project request text     (default: built-in toy request)
#   SPRINT_ID     — sprint identifier        (default: sprint-1)
#   MAX_API_CALLS — max LLM node invocations (default: 200; matches sprint manifest budget)

import "std.env" as env

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "std.list" as list

import "std.int" as int

import "lex-orm/src/connection" as conn

import "./migrate" as migrate

import "./orchestrator" as orch

import "./digest" as dg

import "./cast" as cast

import "./pool_seed" as pool_seed

type TransRow = { from_phase :: Str, to_phase :: Str, evidence :: Str, ts :: Str }

type NrRow = { node_id :: Str, phase :: Str, accepted :: Int, artifact :: Str, reason :: Str }

type TrailCountRow = { n :: Int }

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

fn parse_int_or(s :: Str, fallback :: Int) -> Int {
  match str.to_int(s) {
    Some(n) => n,
    None => fallback,
  }
}

fn resolve_db_url() -> [env] Str {
  let url := get_env("DB_URL", "")
  if str.is_empty(url) {
    get_env("DB_PATH", "loom.db")
  } else {
    url
  }
}

fn open_db(url_or_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(url_or_path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c),
    },
  }
}

# ── run_sprint_cmd ────────────────────────────────────────────────────────────
fn run_sprint_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let db_path := resolve_db_url()
  let model := get_env("MODEL", get_env("OLLAMA_MODEL", "gemma4:latest"))
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  let request := get_env("REQUEST", "Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.")
  let max_api_calls := parse_int_or(get_env("MAX_API_CALLS", "200"), 200)
  let __p1 := io.print(str.join(["[loom] sprint=", sprint_id, " db=", db_path], ""))
  let __p2 := io.print(str.join(["[loom] request=", request], ""))
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[loom] FATAL: ", e)),
    Ok(db) => {
      let __seed := pool_seed.seed(db)
      let prior_specs := dg.load_tightened_specs(db, sprint_id)
      let __ps := if list.is_empty(prior_specs) {
        io.print("[loom] no prior tightened specs (first sprint or new series)")
      } else {
        io.print(str.join(["[loom] ", int.to_str(list.len(prior_specs)), " tightened spec(s) from prior sprint loaded"], ""))
      }
      let cfg := { id: sprint_id, request: request, model: model, db: db, api_calls_max: max_api_calls, roster: cast.empty_roster() }
      let result := orch.run_sprint(cfg)
      let status := if result.success {
        "SUCCESS"
      } else {
        "FAILED"
      }
      let __p3 := io.print(str.join(["[loom] ", status, " — ", result.summary], ""))
      ()
    },
  }
}

# ── sprint_status ─────────────────────────────────────────────────────────────
fn sprint_status() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let __h := io.print(str.join(["Sprint: ", sprint_id], ""))
      let __sep := io.print("──────────────────────────────────────")
      let q := str.join(["SELECT from_phase, to_phase, evidence, ts FROM phase_transitions WHERE sprint_id='", str.replace(sprint_id, "'", "''"), "' ORDER BY ts"], "")
      let rows :: Result[List[TransRow], SqlError] := sql.query(db.handle, q, [])
      match rows {
        Err(_) => (),
        Ok(rs) => {
          let __ph := io.print("Phase transitions:")
          let __prs := list.map(rs, fn (r :: TransRow) -> [io] Unit {
            io.print(str.join(["  ", r.from_phase, " → ", r.to_phase, "  (", r.evidence, ")  ", r.ts], ""))
          })
          ()
        },
      }
      let __sep2 := io.print("──────────────────────────────────────")
      let q2 := str.join(["SELECT node_id, phase, accepted, artifact, reason FROM node_results WHERE sprint_id='", str.replace(sprint_id, "'", "''"), "' ORDER BY created_at"], "")
      let rows2 :: Result[List[NrRow], SqlError] := sql.query(db.handle, q2, [])
      match rows2 {
        Err(_) => (),
        Ok(rs) => {
          if not list.is_empty(rs) {
            let __no := io.print("Node outcomes:")
            let __nrs := list.map(rs, fn (r :: NrRow) -> [io] Unit {
              let icon := if r.accepted == 1 {
                "✓"
              } else {
                "✗"
              }
              io.print(str.join(["  ", icon, " [", r.phase, "] ", r.node_id, if r.accepted == 1 {
                str.concat(" → ", str.slice(r.artifact, 0, 16))
              } else {
                str.concat(" DENIED: ", r.reason)
              }], ""))
            })
            ()
          } else {
            io.print("No node results (sprint may still be running or used in-process mode)")
          }
        },
      }
      let __sep3 := io.print("──────────────────────────────────────")
      let q3 := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", str.replace(sprint_id, "'", "''"), "'"], "")
      let rows3 :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, q3, [])
      match rows3 {
        Err(_) => (),
        Ok(rs) => match list.head(rs) {
          None => (),
          Some(r) => {
            let __tc := io.print(str.join(["Trail events: ", int.to_str(r.n)], ""))
            ()
          },
        },
      }
      let specs := dg.load_tightened_specs(db, sprint_id)
      let seed := dg.load_seed_graph(db, sprint_id)
      let __ds := if not list.is_empty(specs) {
        io.print(str.join(["Digest: ", int.to_str(list.len(specs)), " tightened spec(s) — next sprint seeded"], ""))
      } else {
        io.print("Digest: not yet produced")
      }
      ()
    },
  }
}

# ── sprint_trail ──────────────────────────────────────────────────────────────
fn sprint_trail() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let rows := dg.load_trail(db, sprint_id)
      let __h := io.print(str.join(["Trail for sprint: ", sprint_id, " (", int.to_str(list.len(rows)), " events)"], ""))
      let __sep := io.print("──────────────────────────────────────")
      let __rs := list.map(rows, fn (r :: dg.TrailRow) -> [io] Unit {
        io.print(str.join(["[", r.ts, "] ", r.event_kind, "  ", str.slice(r.data_json, 0, 80)], ""))
      })
      ()
    },
  }
}

# ── sprint_digest ─────────────────────────────────────────────────────────────
fn sprint_digest() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let __h := io.print(str.join(["Digest for sprint: ", sprint_id], ""))
      let __sep := io.print("──────────────────────────────────────")
      let specs := dg.load_tightened_specs(db, sprint_id)
      if list.is_empty(specs) {
        let __p := io.print("No Digest produced yet.")
        ()
      } else {
        let __sp := io.print(str.join(["Tightened specs (", int.to_str(list.len(specs)), "):"], ""))
        let __sr := list.map(specs, fn (s :: dg.TightenedSpec) -> [io] Unit {
          io.print(str.join(["  role=", s.node_role, "\n  gate: ", s.spec_src, "\n  why:  ", s.reason], ""))
        })
        let seed := dg.load_seed_graph(db, sprint_id)
        match seed {
          None => io.print("\nNo seed graph produced."),
          Some(g) => {
            let __sg := io.print(str.join(["\nSeed graph for next sprint (", int.to_str(list.len(g.nodes)), " nodes):"], ""))
            let __sn := list.map(g.nodes, fn (n :: { id :: Str, role :: Str, gate :: Str }) -> [io] Unit {
              io.print(str.join(["  [", n.role, "] ", n.id, "  gate: ", n.gate], ""))
            })
            ()
          },
        }
      }
    },
  }
}

