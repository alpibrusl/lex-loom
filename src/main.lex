# main.lex — entry point for sprint operations.
#
# Commands (set via the function name passed to `lex run`):
#
#   init_db          — create/migrate DB schema only (no sprint)
#   run_sprint_cmd   — run a full sprint (Intake→Digest)
#   sprint_status    — current phase + success flag, node outcomes, last events, digest
#   sprint_trail     — print the full trail for a sprint
#   sprint_digest    — print the Digest artifacts (lessons + tightened specs)
#
# Usage (lex 0.9.8+ checks effects whole-program, so the read-only commands
# need the same effect row as run_sprint_cmd — main.lex imports the orchestrator):
#   lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream \
#     src/main.lex run_sprint_cmd
#
#   SPRINT_ID=sprint-1 lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream src/main.lex sprint_status
#   SPRINT_ID=sprint-1 lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream src/main.lex sprint_trail
#   SPRINT_ID=sprint-1 lex run --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream src/main.lex sprint_digest
#
# Environment:
#   DB_PATH       — SQLite file path         (default: loom.db)
#   MODEL         — LLM model name           (default: defaults.model())
#   REQUEST       — project request text     (default: built-in toy request)
#   SPRINT_ID     — sprint identifier        (default: sprint-1)
#   MAX_API_CALLS — max LLM node invocations (default: 200; matches sprint manifest budget)
#   EXEC_MODE     — "inline" (default) or "queue" (#93): "queue" enqueues each
#                   layer's nodes onto lex-jobs instead of running them
#                   in-process, and blocks on the results. Requires a separate
#                   `lex run ... src/worker.lex run_worker` process (or several)
#                   running against the SAME DB_PATH to actually drain the
#                   queue — a "queue" sprint with no worker running just
#                   times out waiting per layer.

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

import "./defaults" as defaults

import "./dump_config" as dump_config

import "./pool_seed" as pool_seed

import "./cloud" as cloud

import "lex-trail/src/log" as tlog

import "std.time" as time

import "./verify" as verify

import "./transport" as tr

import "./company" as company

import "./org" as org

import "./role_registry" as registry

import "./budget" as budget

import "./board" as board

import "./events" as events

import "./company_runner" as company_runner

import "./identity" as identity

import "./dag_view" as dagv

type TransRow = { from_phase :: Str, to_phase :: Str, evidence :: Str, ts :: Str }

type RunRow = { run_id :: Str }

type NrRow = { node_id :: Str, phase :: Str, accepted :: Int, artifact :: Str, reason :: Str }

type TrailCountRow = { n :: Int }

type PhaseRow = { to_phase :: Str }

type CompleteRow = { data_json :: Str }

type EventRow = { event_kind :: Str, data_json :: Str, ts :: Str }

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

# ── init_db ───────────────────────────────────────────────────────────────────
fn init_db() -> [env, sql, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  match open_db(db_path) {
    Err(_) => (),
    Ok(_) => (),
  }
}

# ── run_sprint_cmd ────────────────────────────────────────────────────────────
fn run_sprint_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let db_path := resolve_db_url()
  let model := defaults.resolved_model()
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
      let review := if get_env("REVIEW_TRANSITIONS", "") == "1" {
        true
      } else {
        get_env("REVIEW_TRANSITIONS", "") == "true"
      }
      let trail_log_none :: Option[tlog.Log] := None
      let exec_mode := defaults.resolved_exec_mode()
      let cfg := { id: sprint_id, request: request, model: model, db: db, api_calls_max: max_api_calls, roster: cast.empty_roster(), trail_log: trail_log_none, review_transitions: review, depth: 0, iter_ctx: None, exec_mode: exec_mode, policy_isolation: "" }
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

# ── cloud_poll ────────────────────────────────────────────────────────────────
# Poll Loom Cloud for a queued sprint, execute it, upload trail events.
# Env: LOOM_SERVER (required), LOOM_RUNNER_TOKEN (required), DB_PATH, MAX_API_CALLS
fn cloud_poll() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let server := get_env("LOOM_SERVER", "")
  let token := get_env("LOOM_RUNNER_TOKEN", "")
  if str.is_empty(server) {
    io.print("[cloud] LOOM_SERVER not set — exiting")
  } else {
    if str.is_empty(token) {
      io.print("[cloud] LOOM_RUNNER_TOKEN not set — exiting")
    } else {
      let db_path := resolve_db_url()
      let max_calls := parse_int_or(get_env("MAX_API_CALLS", "200"), 200)
      let __log := io.print(str.join(["[cloud] runner connecting to ", server], ""))
      match open_db(db_path) {
        Err(e) => io.print(str.concat("[cloud] FATAL: ", e)),
        Ok(db) => cloud.poll_once(db, server, token, max_calls),
      }
    }
  }
}

# ── sprint_status ─────────────────────────────────────────────────────────────
fn sprint_status() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let esc := str.replace(sprint_id, "'", "''")
      let __h := io.print(str.join(["Sprint: ", sprint_id], ""))
      let __sep := io.print("──────────────────────────────────────")
      let qc := str.join(["SELECT to_phase FROM phase_transitions WHERE sprint_id='", esc, "' ORDER BY ts DESC LIMIT 1"], "")
      let cur :: Result[List[PhaseRow], SqlError] := sql.query(db.handle, qc, [])
      let __cur := match cur {
        Err(_) => (),
        Ok(cs) => match list.head(cs) {
          None => io.print("Current phase: (no transitions yet)"),
          Some(c) => io.print(str.join(["Current phase: ", c.to_phase], "")),
        },
      }
      let qsc := str.join(["SELECT data_json FROM traces WHERE agent_id='", esc, "' AND event_kind='sprint_complete' ORDER BY id DESC LIMIT 1"], "")
      let scr :: Result[List[CompleteRow], SqlError] := sql.query(db.handle, qsc, [])
      let __sc := match scr {
        Err(_) => (),
        Ok(ss) => match list.head(ss) {
          None => io.print("Success: — (sprint not complete)"),
          Some(s) => {
            let ok := str.contains(s.data_json, "\"success\":true")
            let sealed := str.contains(s.data_json, "\"fully_sealed\":true")
            io.print(str.join(["Success: ", if ok {
              "✓ PASS"
            } else {
              "✗ FAIL"
            }, if sealed {
              "  (fully sealed)"
            } else {
              "  (awaiting attestation)"
            }], ""))
          },
        },
      }
      let __sep0 := io.print("──────────────────────────────────────")
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
      let qe := str.join(["SELECT event_kind, data_json, ts FROM traces WHERE agent_id='", esc, "' ORDER BY id DESC LIMIT 5"], "")
      let erows :: Result[List[EventRow], SqlError] := sql.query(db.handle, qe, [])
      let __ev := match erows {
        Err(_) => (),
        Ok(es) => if list.is_empty(es) {
          ()
        } else {
          let __eh := io.print("Last 5 events (most recent first):")
          let __er := list.map(es, fn (e :: EventRow) -> [io] Unit {
            io.print(str.join(["  [", e.ts, "] ", e.event_kind, "  ", str.slice(e.data_json, 0, 80)], ""))
          })
          ()
        },
      }
      let __sep4 := io.print("──────────────────────────────────────")
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

# ── link_native_run ───────────────────────────────────────────────────────────
# Record sprint_id → native `lex run --trace` run_id (#7). Called by the
# bin/loom-traced.sh wrapper after a traced sprint, with RUN_ID in the env.
# Idempotent on run_id (PRIMARY KEY); a re-run gets a new run_id → a new row.
fn link_native_run() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := resolve_db_url()
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  let run_id := get_env("RUN_ID", "")
  if str.is_empty(run_id) {
    io.print("[loom] link_native_run: RUN_ID not set — nothing to link")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[loom] FATAL: ", e)),
      Ok(db) => {
        let esc_s := str.replace(sprint_id, "'", "''")
        let esc_r := str.replace(run_id, "'", "''")
        let now := time.now_str()
        let q := str.join(["INSERT OR REPLACE INTO sprint_runs (id, sprint_id, run_id, created_at) VALUES ('", esc_r, "','", esc_s, "','", esc_r, "','", now, "')"], "")
        let __ins := sql.exec(db.handle, q, [])
        let __p := io.print(str.join(["[loom] linked sprint ", sprint_id, " → native run ", run_id], ""))
        ()
      },
    }
  }
}

# ── sprint_run ────────────────────────────────────────────────────────────────
# Print ONLY the latest native run_id for SPRINT_ID (empty line if none), so
# bin/loom-replay.sh can capture it. Use `lex trace <run_id>` /
# `lex replay <run_id> src/main.lex run_sprint_cmd --override NODE=JSON`.
fn sprint_run() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print(""),
    Ok(db) => {
      let esc := str.replace(sprint_id, "'", "''")
      let q := str.join(["SELECT run_id FROM sprint_runs WHERE sprint_id='", esc, "' ORDER BY created_at DESC LIMIT 1"], "")
      let r :: Result[List[RunRow], SqlError] := sql.query(db.handle, q, [])
      match r {
        Err(_) => io.print(""),
        Ok(rs) => match list.head(rs) {
          None => io.print(""),
          Some(row) => io.print(row.run_id),
        },
      }
    },
  }
}

# ── verify_sprint_cmd ─────────────────────────────────────────────────────────
# Independently re-derive a sprint's integrity (#47): re-hash every accepted
# artifact from the content-addressed store and confirm it matches the id the
# trail referenced. Prints a JSON verdict and records a `sprint_verified` event
# so the verification is itself auditable.
fn verify_sprint_cmd() -> [env, io, sql, fs_read, fs_write, vcs, crypto, time, random, proc] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let r := verify.verify_sprint(db, sprint_id)
      let json := verify.report_json(r)
      let __p := io.print(str.join(["[verify] integrity ", json], ""))
      let __t := tr.trail(db, sprint_id, "sprint_verified", json)
      let rr := verify.reverify_sprint(db, sprint_id)
      let rjson := verify.rereport_json(rr)
      let __p2 := io.print(str.join(["[verify] grounded ", rjson], ""))
      let __t2 := tr.trail(db, sprint_id, "sprint_reverified", rjson)
      let ar := verify.verify_authority(db, sprint_id)
      let ajson := verify.authreport_json(ar)
      let __p3 := io.print(str.join(["[verify] authority ", ajson], ""))
      let __t3 := tr.trail(db, sprint_id, "sprint_authority_verified", ajson)
      let op := verify.verify_operations(db, sprint_id)
      let ojson := verify.opreport_json(op)
      let __p4 := io.print(str.join(["[verify] operations ", ojson], ""))
      let __t4 := tr.trail(db, sprint_id, "sprint_operations_verified", ojson)
      let all_verified := if r.verified {
        if rr.verified {
          if ar.verified {
            op.verified
          } else {
            false
          }
        } else {
          false
        }
      } else {
        false
      }
      let verdicts_json := str.join(["{\"integrity\":", json, ",\"grounded\":", rjson, ",\"authority\":", ajson, ",\"operations\":", ojson, "}"], "")
      let __att := attest_sprint(db, sprint_id, verdicts_json, all_verified)
      ()
    },
  }
}

# ── did:lex attestations (#52) ────────────────────────────────────────────────
# Every agent the sprint granted authority to (its op_grant set) receives a
# SIGNED attestation bundle binding the four-layer verdicts to its did. A
# verified bundle is the only thing that accrues reputation; an unverified run
# is recorded but earns nothing.
fn attest_sprint(db :: conn.ConnDb, sprint_id :: Str, verdicts_json :: Str, all_verified :: Bool) -> [io, sql, fs_write, crypto, random, time] Unit {
  let agents := verify.grant_agents(db, sprint_id)
  let __each := list.map(agents, fn (ar :: (Str, Str)) -> [io, sql, fs_write, crypto, random, time] Unit {
    match ar {
      (agent_id, role) => {
        let ident := identity.issue_attestation(db, sprint_id, agent_id, role, verdicts_json, all_verified)
        let line := str.join(["{\"agent\":\"", agent_id, "\",\"did\":\"", ident.did, "\",\"verified\":", if all_verified {
          "true"
        } else {
          "false"
        }, "}"], "")
        let __p := io.print(str.join(["[verify] attested ", line], ""))
        let __t := tr.trail(db, sprint_id, "sprint_attested", line)
        ()
      },
    }
  })
  ()
}

# ── verify_record_cmd (#68, hosted verifier) ──────────────────────────────────
# Machine-readable sibling of verify_sprint_cmd: recompute the four-layer
# verdicts over a record and print ONE line, "VERDICTS|<json>" — the
# contract src/server/verify_api.lex's subprocess relay parses. Grounded
# re-runs are OFF unless VERIFY_RERUN_GROUNDED=1 (they execute the
# record's own build commands — sandbox only); the skipped layer is
# reported as skipped, never silently passed. Unlike verify_sprint_cmd
# this writes nothing back to the record: verifying a copy someone
# handed you should not mutate it.
#   DB_PATH=their.db SPRINT_ID=co/iter-1 lex run --max-steps 0 \
#     --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs,stream \
#     src/main.lex verify_record_cmd
fn verify_record_cmd() -> [env, io, sql, fs_read, fs_write, vcs, crypto, proc] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  let rerun_grounded := get_env("VERIFY_RERUN_GROUNDED", "") == "1"
  match conn.open(db_path) {
    Err(_) => io.print("VERDICTS|{\"error\":\"cannot open record\"}"),
    Ok(db) => io.print(str.concat("VERDICTS|", verify.verdicts_json(db, sprint_id, rerun_grounded))),
  }
}

# ── reputation_cmd ────────────────────────────────────────────────────────────
# Print the did:lex reputation registry: reputation = count of VERIFIED
# attestations per did (derived, never stored), sessions = all attestations.
fn reputation_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => io.print(identity.registry_json(db)),
  }
}

# ── sprint_dag_cmd ────────────────────────────────────────────────────────────
# Prints a Mermaid flowchart of a sprint's graph, including every expand-node
# sub-sprint nested as its own subgraph, with each node coloured by its
# current status (pending/running/done/FAILED, read from the trail).
# Paste the output into a ```mermaid fence or https://mermaid.live.
#
#   SPRINT_ID=sprint-1 lex run --allow-effects env,io,sql,fs_read,fs_write src/main.lex sprint_dag_cmd
fn sprint_dag_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => io.print(dagv.sprint_dag_mermaid(db, sprint_id)),
  }
}

# ── attention queue: list + resolve (#89, decision-rights lex-loom#165) ──────
# The `human <oracle>` gate lane (monetization_handoff and any other
# human-gated node) pushes here and the node stays UNSEALED until a human
# calls attention_resolve_cmd — nothing else in the system can advance it.
#
# RESOLVER_ID is required and is always recorded (audit: who actually
# approved this). If the company has registered relationships.lex contacts
# for this item's oracle, RESOLVER_ID must be one of them (authorization:
# only the accountable contact, not anyone with CLI/DB access) — a company
# with no contacts registered for that oracle stays fully open, same as
# before this existed (see company.is_authorized_resolver).
#
#   lex run --allow-effects env,io,sql,fs_read,fs_write src/main.lex attention_list_cmd
#   ATTENTION_ID=<id> VERDICT=approved|rejected REASON="..." RESOLVER_ID=jane-doe \
#     lex run --allow-effects env,io,sql,fs_read,fs_write,vcs src/main.lex attention_resolve_cmd
fn attention_list_cmd() -> [env, io, sql, fs_read, fs_write, vcs] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let pending := tr.list_attention_pending(db)
      if list.is_empty(pending) {
        io.print("(no pending human-attestation items)")
      } else {
        let __h := io.print(str.join(["Pending human attestation (", int.to_str(list.len(pending)), "):"], ""))
        let __sep := io.print("──────────────────────────────────────")
        let __rows := list.map(pending, fn (a :: tr.AttentionRow) -> [io, sql, fs_read, vcs] Unit {
          let __p1 := io.print(str.join(["id=", a.id, "  sprint=", a.sprint_id, "  node=", a.node_id, "  oracle=", a.oracle], ""))
          match tr.artifact_get(db, a.artifact_hash) {
            Err(_) => io.print("  (artifact unavailable)"),
            Ok(content) => io.print(str.join(["  ---\n", content, "\n  ---"], "")),
          }
        })
        ()
      }
    },
  }
}

fn attention_resolve_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let id := get_env("ATTENTION_ID", "")
  let verdict := get_env("VERDICT", "")
  let reason := get_env("REASON", "")
  let resolver_id := get_env("RESOLVER_ID", "")
  if str.is_empty(id) {
    io.print("[loom] ATTENTION_ID is required")
  } else {
    if str.is_empty(resolver_id) {
      io.print("[loom] RESOLVER_ID is required — who is resolving this must always be on the record")
    } else {
      if verdict != "approved" {
        if verdict != "rejected" {
          io.print("[loom] VERDICT must be 'approved' or 'rejected'")
        } else {
          resolve_attention_cmd_run(db_path, id, verdict, reason, resolver_id)
        }
      } else {
        resolve_attention_cmd_run(db_path, id, verdict, reason, resolver_id)
      }
    }
  }
}

# GOV4 (lex-loom#224): resolves route through board.decide — the ONE
# authorized decide path the web API also calls, so the identity check can
# never diverge between surfaces (#204's criterion, upgraded to one fn).
fn resolve_attention_cmd_run(db_path :: Str, id :: Str, verdict :: Str, reason :: Str, resolver_id :: Str) -> [env, io, sql, fs_write, fs_read, time, random, crypto] Unit {
  match conn.open(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => match board.decide(db, id, verdict, reason, resolver_id) {
      Err(e) => io.print(str.concat("[loom] ", e)),
      Ok(msg) => io.print(str.join(["[loom] ", id, " -> ", msg], "")),
    },
  }
}

# ── board_* commands (GOV4, lex-loom#224) ────────────────────────────────────
# The board's decision surface: everything the company owes an answer on,
# typed, aged, decidable, minuted.
#
#   COMPANY_ID=acme lex run ... src/main.lex board_pending_cmd
#   COMPANY_ID=acme ATTENTION_ID=<id> VERDICT=approved|rejected|deferred \
#     REASON="..." RESOLVER_ID=<contact> lex run ... src/main.lex board_decide_cmd
#   COMPANY_ID=acme lex run ... src/main.lex board_minutes_cmd
fn board_pending_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[board] FATAL: ", e)),
    Ok(db) => io.print(board.sla_section(db, company_id)),
  }
}

fn board_decide_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := resolve_db_url()
  let id := get_env("ATTENTION_ID", "")
  if str.is_empty(id) {
    io.print("[board] ATTENTION_ID is required")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[board] FATAL: ", e)),
      Ok(db) => match board.decide(db, id, get_env("VERDICT", ""), get_env("REASON", ""), get_env("RESOLVER_ID", "")) {
        Err(e) => io.print(str.concat("[board] ", e)),
        Ok(msg) => io.print(str.join(["[board] ", id, " -> ", msg], "")),
      },
    }
  }
}

fn board_minutes_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[board] FATAL: ", e)),
    Ok(db) => {
      let ms := board.minutes(db, company_id)
      if list.is_empty(ms) {
        io.print("[board] no decisions on record yet")
      } else {
        io.print(str.join(ms, "\n"))
      }
    },
  }
}

# ── events_cmd (HB2, lex-loom#214) ───────────────────────────────────────────
# The wake history: every external event recorded for a company, chronological,
# with its one-shot consumption mark (which scheduler run absorbed it, when).
# Replaying this ledger IS the audit of what woke what.
#
#   COMPANY_ID=acme lex run --allow-effects env,io,sql,fs_read,fs_write \
#     src/main.lex events_cmd
fn events_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[events] FATAL: ", e)),
    Ok(db) => {
      let hs := events.history(db, company_id)
      if list.is_empty(hs) {
        io.print(str.join(["[events] no events recorded for ", company_id], ""))
      } else {
        io.print(str.join(hs, "\n"))
      }
    },
  }
}

# ── company_monitor_cmd ────────────────────────────────────────────────────────
# Health-checks a company's latest iteration OUTSIDE the iteration loop, and
# records the result into the same company_operate_signals table the
# strategist's prompt reads from (#102).
#
# Repositioned since HB1/#242: this is a MANUAL/DEBUG tool now. The original
# "run from cron/a systemd timer" role is owned by the scheduler daemon
# (`bin/loom-scheduler.sh`), whose every tick gives each not-run company this
# exact sweep — plus the operate event bridges the standalone command does
# not run. Use this only to force one sweep by hand while diagnosing.
#
#   COMPANY_ID=acme lex run --allow-effects env,io,sql,fs_read,fs_write,time,proc \
#     src/main.lex company_monitor_cmd
fn company_monitor_cmd() -> [env, io, sql, fs_read, fs_write, time, proc] Unit {
  let db_path := get_env("DB_PATH", "loom.db")
  let company_id := get_env("COMPANY_ID", "")
  if str.is_empty(company_id) {
    io.print("[loom] COMPANY_ID is required")
  } else {
    match conn.open(db_path) {
      Err(_) => io.print("[loom] FATAL open db"),
      Ok(db) => {
        let idx := company.latest_iteration_idx(db, company_id)
        if idx == 0 {
          io.print(str.join(["[loom] no iterations recorded yet for company ", company_id], ""))
        } else {
          let sprint_id := company.iteration_sprint_id(company_id, idx)
          let __rev := match company.check_and_record_revenue(db, company_id, idx) {
            Err(e) => io.print(str.concat("[loom] revenue check failed: ", e)),
            Ok(_) => (),
          }
          match company.check_and_record_liveness(db, company_id, idx, sprint_id) {
            Err(e) => io.print(str.concat("[loom] liveness check failed: ", e)),
            Ok(_) => io.print(str.join(["[loom] liveness checked for ", company_id, " iter ", int.to_str(idx)], "")),
          }
        }
      },
    }
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
        io.print(str.join(["[", r.ts, "] ", r.event_kind, "  ", str.slice(r.data_json, 0, 600)], ""))
      })
      ()
    },
  }
}

# ── sprint_report ─────────────────────────────────────────────────────────────
# Trail-derived human-facing summary (#34). Every claim is backed by a real
# trail query — no hardcoded "attempt #1" or "Sprint N passed" strings.
#
# Usage:
#   SPRINT_ID=sprint-1 lex run --allow-effects ... src/main.lex sprint_report
fn sprint_report() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let sprint_id := get_env("SPRINT_ID", "sprint-1")
  match open_db(db_path) {
    Err(_) => io.print("[loom] FATAL open db"),
    Ok(db) => {
      let esc := str.replace(sprint_id, "'", "''")
      let __h := io.print(str.join(["Sprint report: ", sprint_id], ""))
      let __sep := io.print("──────────────────────────────────────")
      let qa := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", esc, "' AND event_kind='node_accepted'"], "")
      let qa_rows :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, qa, [])
      let accepted_count := match qa_rows {
        Err(_) => 0,
        Ok(rs) => match list.head(rs) {
          None => 0,
          Some(r) => r.n,
        },
      }
      let qd := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", esc, "' AND event_kind='node_denied'"], "")
      let qd_rows :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, qd, [])
      let denied_count := match qd_rows {
        Err(_) => 0,
        Ok(rs) => match list.head(rs) {
          None => 0,
          Some(r) => r.n,
        },
      }
      let qb := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", esc, "' AND event_kind='phase_bounced'"], "")
      let qb_rows :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, qb, [])
      let bounce_count := match qb_rows {
        Err(_) => 0,
        Ok(rs) => match list.head(rs) {
          None => 0,
          Some(r) => r.n,
        },
      }
      let qr := str.join(["SELECT COUNT(*) AS n FROM traces WHERE agent_id='", esc, "' AND event_kind='node_retrying'"], "")
      let qr_rows :: Result[List[TrailCountRow], SqlError] := sql.query(db.handle, qr, [])
      let retry_count := match qr_rows {
        Err(_) => 0,
        Ok(rs) => match list.head(rs) {
          None => 0,
          Some(r) => r.n,
        },
      }
      let qp := str.join(["SELECT data_json FROM traces WHERE agent_id='", esc, "' AND (event_kind='sprint_complete' OR event_kind='sprint_failed') ORDER BY id DESC LIMIT 1"], "")
      let qp_rows :: Result[List[CompleteRow], SqlError] := sql.query(db.handle, qp, [])
      let outcome := match qp_rows {
        Err(_) => "unknown",
        Ok(rs) => match list.head(rs) {
          None => "in-progress",
          Some(r) => if str.contains(r.data_json, "\"success\":true") {
            "PASSED"
          } else {
            if str.contains(r.data_json, "\"success\":false") {
              "FAILED"
            } else {
              "FAILED"
            }
          },
        },
      }
      let qa_attempt := bounce_count + 1
      let __r1 := io.print(str.join(["Outcome:         ", outcome], ""))
      let __r2 := io.print(str.join(["Nodes accepted:  ", int.to_str(accepted_count)], ""))
      let __r3 := io.print(str.join(["Nodes denied:    ", int.to_str(denied_count), " (gate bounces)"], ""))
      let __r4 := io.print(str.join(["Node retries:    ", int.to_str(retry_count)], ""))
      let __r5 := io.print(str.join(["QA pass attempt: #", int.to_str(qa_attempt), " (", int.to_str(bounce_count), " rework round(s))"], ""))
      let __sep2 := io.print("──────────────────────────────────────")
      let __note := io.print("(all figures derived from trail — no hardcoded claims)")
      ()
    },
  }
}

# ── run_company ───────────────────────────────────────────────────────────────
# A persistent goal that produces a series of iterating looms (#53).
fn run_company_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let db_path := resolve_db_url()
  let model := defaults.resolved_model()
  let company_id := get_env("COMPANY_ID", "acme")
  let goal := get_env("GOAL", "Build a CLI tool that counts word frequencies in a text file and prints the top-10 words.")
  let max_iterations := parse_int_or(get_env("MAX_ITERATIONS", "3"), 3)
  let stop_when := get_env("STOP_WHEN", "")
  let pmf_when := get_env("PMF_WHEN", "")
  let maintenance_when := get_env("MAINTENANCE_WHEN", "")
  let wake_when := get_env("WAKE_WHEN", "")
  let soft_mesh_url := get_env("SOFT_MESH_URL", "")
  let soft_org_id := get_env("SOFT_ORG_ID", "")
  let soft_roles := get_env("SOFT_ROLES", "")
  let soft_settlement := get_env("SOFT_SETTLEMENT", "")
  let policy_isolation := get_env("POLICY_ISOLATION", "")
  let api_max := parse_int_or(get_env("MAX_API_CALLS", "200"), 200)
  let evolve_flag := get_env("EVOLVE", "1")
  let evolve := if evolve_flag == "0" {
    false
  } else {
    evolve_flag != "false"
  }
  let org_spec := get_env("ORG_EDGES", "")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[company] FATAL: ", e)),
    Ok(db) => match org.parse_org_spec(org_spec) {
      Err(m) => io.print(str.join(["[company] FATAL: refusing to start — invalid [org] declaration: ", m], "")),
      Ok(org_edges) => match registry.validate_packs(get_env("ROLE_PACKS", "")) {
        Err(m) => io.print(str.join(["[company] FATAL: refusing to start — invalid [roles].packs declaration: ", m], "")),
        Ok(packs) => match budget.parse_envelope_spec(get_env("BUDGET_ENVELOPES", "")) {
          Err(m) => io.print(str.join(["[company] FATAL: refusing to start — invalid [budget.envelopes] declaration: ", m], "")),
          Ok(envelopes) => {
            let __org := if list.is_empty(org_edges) {
              Ok(())
            } else {
              org.save_org(db, company_id, org_edges)
            }
            let __op := if list.is_empty(org_edges) {
              ()
            } else {
              io.print(str.join(["[company] org chart loaded (", int.to_str(list.len(org_edges)), " reporting line(s))"], ""))
            }
            let __seed := pool_seed.seed(db)
            let ccfg := { id: company_id, goal: goal, model: model, max_iterations: max_iterations, stop_when: stop_when, pmf_when: pmf_when, maintenance_when: maintenance_when, wake_when: wake_when, soft_mesh_url: soft_mesh_url, soft_org_id: soft_org_id, soft_roles: soft_roles, soft_settlement: soft_settlement, policy_isolation: policy_isolation }
            let __save := company.save_company(db, ccfg)
            let __packs := if list.is_empty(packs) {
              Ok(())
            } else {
              registry.save_packs(db, company_id, packs)
            }
            let __pp := if list.is_empty(packs) {
              ()
            } else {
              io.print(str.join(["[company] role packs staffed: core + ", str.join(packs, ", ")], ""))
            }
            let __envs := list.map(envelopes, fn (p :: (Str, Int)) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
              match p {
                (scope, cents) => match budget.set_envelope(db, company_id, scope, cents, "founder") {
                  Err(m) => io.print(str.concat("[budget] envelope not set: ", m)),
                  Ok(_) => io.print(str.join(["[budget] envelope ", scope, ": ", int.to_str(cents), "c (declared at launch)"], "")),
                },
              }
            })
            let __res := company_runner.run_company(db, ccfg, api_max, evolve)
            ()
          },
        },
      },
    },
  }
}

# ── run_portfolio ─────────────────────────────────────────────────────────────
# One company, N concurrent product tracks sharing the same staff pool (#78).
# Seed tracks via TRACK_COUNT + TRACK_<n>_ID/TRACK_<n>_GOAL (n = 1..TRACK_COUNT);
# seeding is idempotent, so a re-invoked portfolio only advances existing tracks.
#
# DEPRECATED (#242): portfolio tracks predate the scheduler and are the weaker
# of two "many products" mechanisms — all tracks share ONE company DB, run
# sequentially, and have no per-track governance (no budget envelopes, no
# event wakes, no board surface of their own). The workspace-of-companies
# model is strictly stronger: bootstrap each product line as its OWN company
# (`bin/bootstrap-company.sh <manifest> --no-run` into $LOOM_WORKSPACE) and
# let `bin/loom-scheduler.sh` run them concurrently under MAX_RUNS_PER_TICK,
# each with its full governance surface. This command keeps working for
# existing portfolio DBs but warns loudly; removal is a later major.
fn build_track_seed(n :: Int, count :: Int) -> [env] List[(Str, Str)] {
  if n > count {
    []
  } else {
    let tid := get_env(str.concat("TRACK_", str.concat(int.to_str(n), "_ID")), "")
    let tgoal := get_env(str.concat("TRACK_", str.concat(int.to_str(n), "_GOAL")), "")
    let rest := build_track_seed(n + 1, count)
    if str.is_empty(tid) {
      rest
    } else {
      list.concat([(tid, tgoal)], rest)
    }
  }
}

fn run_portfolio_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let __warn1 := io.print("[portfolio] DEPRECATED (#242): portfolio tracks share one DB, run sequentially, and have no per-track governance.")
  let __warn2 := io.print("[portfolio]   Prefer one company per product line in a workspace: bin/bootstrap-company.sh <manifest> --no-run, then bin/loom-scheduler.sh")
  let __warn3 := io.print("[portfolio]   (concurrent runs, budget envelopes, event wakes, and a board surface per company). This command still works for existing portfolio DBs.")
  let db_path := resolve_db_url()
  let model := defaults.resolved_model()
  let portfolio_id := get_env("PORTFOLIO_ID", "acme")
  let max_iterations := parse_int_or(get_env("MAX_ITERATIONS", "1"), 1)
  let api_max := parse_int_or(get_env("MAX_API_CALLS", "200"), 200)
  let track_count := parse_int_or(get_env("TRACK_COUNT", "0"), 0)
  let evolve_flag := get_env("EVOLVE", "1")
  let evolve := if evolve_flag == "0" {
    false
  } else {
    evolve_flag != "false"
  }
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[portfolio] FATAL: ", e)),
    Ok(db) => {
      let __seed := pool_seed.seed(db)
      let track_seed := build_track_seed(1, track_count)
      let __res := company_runner.run_portfolio(db, portfolio_id, model, api_max, max_iterations, evolve, track_seed)
      ()
    },
  }
}

# ── board_report / board_note (#82) ──────────────────────────────────────────
# Read-only board report and an advisory note channel for the human board
# member. Neither blocks or gates normal company operation.
fn board_report_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[board] FATAL: ", e)),
    Ok(db) => io.print(str.join([board.sla_section(db, company_id), "\n", company.board_report(db, company_id), budget.report_section(db, company_id)], "")),
  }
}

# ── budget_set_cmd (GOV2, lex-loom#222) ──────────────────────────────────────
# The board's ONLY way to create or resize a spend envelope after launch.
# RESOLVER_ID is required and recorded on the trail — envelope changes are a
# governance act, not something any agent code path can do.
fn budget_set_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  let scope := get_env("SCOPE", "")
  let resolver := get_env("RESOLVER_ID", "")
  let cents := match str.to_int(get_env("CAP_CENTS", "")) {
    Some(c) => c,
    None => 0,
  }
  if str.is_empty(resolver) {
    io.print("[budget] FATAL: RESOLVER_ID is required — envelope changes are board-only and always attributed")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[budget] FATAL: ", e)),
      Ok(db) => match budget.set_envelope(db, company_id, scope, cents, resolver) {
        Err(m) => io.print(str.concat("[budget] FATAL: ", m)),
        Ok(_) => io.print(str.join(["[budget] envelope ", scope, " set to ", int.to_str(cents), "c by ", resolver], "")),
      },
    }
  }
}

# ── roster_grant_report_cmd (OA1, lex-loom#182) ──────────────────────────────
# For the company's latest iteration, report which lex-os grant preset each
# roster role would run under -- the declared [policy.isolation] override if
# set, else manifests.lex's own default mapping. Builds a real roster via
# cast.select_roster but doesn't execute anything -- purely informational.
#
# Usage:
#   COMPANY_ID=acme lex run --allow-effects env,io,sql,fs_read,fs_write \
#     src/main.lex roster_grant_report_cmd
fn roster_grant_report_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[loom] FATAL: ", e)),
    Ok(db) => match company.load_company(db, company_id) {
      None => io.print(str.join(["[loom] no company found for ", company_id], "")),
      Some(ccfg) => {
        let idx := company.latest_iteration_idx(db, company_id)
        if idx == 0 {
          io.print(str.join(["[loom] no iterations recorded yet for company ", company_id], ""))
        } else {
          let sprint_id := company.iteration_sprint_id(company_id, idx)
          match dg.load_seed_graph(db, sprint_id) {
            None => io.print(str.join(["[loom] no seed graph found for sprint ", sprint_id], "")),
            Some(g) => {
              let roster := cast.select_roster(db, g, ccfg.goal, ccfg.model, sprint_id)
              let __h := io.print(str.join(["Grant report for ", company_id, " (", sprint_id, "):"], ""))
              io.print(cast.grant_report_text(roster, ccfg.policy_isolation))
            },
          }
        }
      },
    },
  }
}

fn board_note_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  let note := get_env("NOTE", "")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[board] FATAL: ", e)),
    Ok(db) => if str.is_empty(str.trim(note)) {
      io.print("[board] NOTE is empty — nothing added")
    } else {
      match company.add_board_note(db, company_id, note) {
        Err(e) => io.print(str.concat("[board] FATAL: ", e)),
        Ok(_) => io.print(str.join(["[board] note queued for ", company_id, ": ", note], "")),
      }
    },
  }
}

# ── add_contact_cmd (#151) ────────────────────────────────────────────────────
# Register a human as the contact for one oracle/domain on a company —
#   COMPANY_ID=acme ORACLE=legal-counsel CONTACT_ID=jane-doe \
#   CONTACT_NAME="Jane Doe" CONTACT_URL=mailto:jane@example.com \
#   lex run --allow-effects env,io,sql,fs_read,fs_write,time,crypto,random \
#     src/main.lex add_contact_cmd
fn add_contact_cmd() -> [env, io, sql, fs_read, fs_write, time, crypto, random] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  let oracle := get_env("ORACLE", "")
  let contact_id := get_env("CONTACT_ID", "")
  let contact_name := get_env("CONTACT_NAME", "")
  let contact_url := get_env("CONTACT_URL", "")
  if str.is_empty(oracle) or str.is_empty(contact_id) or str.is_empty(contact_name) {
    io.print("[contacts] ORACLE, CONTACT_ID, and CONTACT_NAME are required")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[contacts] FATAL: ", e)),
      Ok(db) => match company.add_contact(db, company_id, oracle, contact_id, contact_name, contact_url) {
        Err(e) => io.print(str.concat("[contacts] FATAL: ", e)),
        Ok(_) => io.print(str.join(["[contacts] ", company_id, "/", oracle, " -> ", contact_name], "")),
      },
    }
  }
}

# ── add_pool_contact_cmd (#151) ───────────────────────────────────────────────
# Point an oracle/domain at an existing agent_pool specialist instead of a
# human — the specialist's own measured record (attestation_count, domain
# tags) is the accountability signal, not a contact address.
#   COMPANY_ID=acme ORACLE=security AGENT_ID=strict-qa-v1 \
#   lex run --allow-effects env,io,sql,fs_read,fs_write,time,crypto,random \
#     src/main.lex add_pool_contact_cmd
fn add_pool_contact_cmd() -> [env, io, sql, fs_read, fs_write, time, crypto, random] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  let oracle := get_env("ORACLE", "")
  let agent_id := get_env("AGENT_ID", "")
  if str.is_empty(oracle) or str.is_empty(agent_id) {
    io.print("[contacts] ORACLE and AGENT_ID are required")
  } else {
    match open_db(db_path) {
      Err(e) => io.print(str.concat("[contacts] FATAL: ", e)),
      Ok(db) => match company.add_pool_agent_contact(db, company_id, oracle, agent_id) {
        Err(e) => io.print(str.concat("[contacts] FATAL: ", e)),
        Ok(_) => io.print(str.join(["[contacts] ", company_id, "/", oracle, " -> agent:", agent_id], "")),
      },
    }
  }
}

# ── dump_config_cmd (#247) ────────────────────────────────────────────────────
# Print the company's effective configuration, one line per field, each
# annotated with the layer that decided it (company row, env var, isolation
# override, kind default, spend envelope). Values come from the same
# resolution functions the runtime uses — see src/dump_config.lex.
#   COMPANY_ID=acme lex run --allow-effects env,io,sql,fs_read,fs_write \
#     src/main.lex dump_config_cmd
fn dump_config_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := resolve_db_url()
  let company_id := get_env("COMPANY_ID", "acme")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[dump-config] FATAL: ", e)),
    Ok(db) => match dump_config.dump(db, company_id) {
      Err(e) => io.print(str.concat("[dump-config] FATAL: ", e)),
      Ok(text) => io.print(text),
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
            let __sn := list.map(g.nodes, fn (n :: { id :: Str, role :: Str, gate :: Str, expand :: Option[Str], activate_when :: Str }) -> [io] Unit {
              io.print(str.join(["  [", n.role, "] ", n.id, "  gate: ", n.gate], ""))
            })
            ()
          },
        }
      }
    },
  }
}

