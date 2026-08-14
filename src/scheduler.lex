# scheduler.lex — HB1 (#213): the loom heartbeat.
#
# Before this, a company only ran while a human shell invocation was alive
# (bin/run-company.sh -> run_company_cmd), `wake_when` was only evaluated on
# manual re-invoke, and company_monitor_cmd assumed an external cron nobody
# shipped. This scheduler is the missing daemon: a long-lived process that owns
# the lifecycle of every company in $LOOM_WORKSPACE.
#
# Each tick, for every <workspace>/<id>/company.db:
#   1. classify — decide run/skip from persisted state ONLY (the company's own
#      DB is the single source of truth; the scheduler keeps no state of its
#      own, so a kill/restart resumes cleanly by construction).
#   2. run     — at most MAX_RUNS_PER_TICK companies per tick go through the
#      exact same company_runner.run_company path a manual invocation uses.
#   3. monitor — companies NOT run this tick still get the between-run
#      revenue/liveness sweep (the company_monitor_cmd logic), so operate
#      signals accrue and a dormant company's wake_when can become true.
#
# Classification (see `classify` — pure, unit-tested in tests/test_scheduler.lex):
#   - past max_iterations            -> skip (proceed would refuse anyway)
#   - Sunset, no queued backlog      -> skip (terminal; a backlog item reactivates)
#   - stop_when holds, no board note -> skip (a stopped company STAYS stopped;
#     only an explicit, still-pending board note is grounds to run once more —
#     the board intervened, the strategist should hear it. Applies only once
#     an iteration has actually been recorded: resume_point's fresh default
#     ctx has idx 1, which would make e.g. `iter ge 1` "hold" before anything
#     ever ran — a company can only STAY stopped if it started)
#   - dormant (Maintenance,          -> skip (cheap; wake_when re-evaluated
#     wake_when unmet)                  against signals monitor keeps fresh)
#   - otherwise                      -> run
#
# Every decision is trail-recorded (`scheduler_decision` under the company id)
# so the heartbeat itself is auditable. A directory whose company.db cannot be
# opened, or opens but has no company row, is skipped LOUDLY (print + — where
# a DB is writable — an attention-queue entry), never guessed at: refuse,
# don't downgrade.
#
# Run (long-lived; TICK_MS between ticks, MAX_TICKS=0 means forever):
#   LOOM_WORKSPACE=~/loom-companies bin/loom-scheduler.sh
#
# EXEC_MODE stays whatever the environment says (loom-scheduler.sh defaults it
# to "inline": this scheduler launches no queue workers — that's HB3).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.env" as env

import "std.time" as time

import "std.process" as proc

import "lex-orm/src/connection" as conn

import "./migrate" as migrate

import "./company" as company

import "./company_runner" as company_runner

import "./pool_seed" as pool_seed

import "./transport" as tr

# One scheduling decision: action is "run" or "skip"; reason is the specific
# branch that fired (max_iterations | sunset | backlog_reactivation | stopped |
# board_note_override | dormant | woken | due).
type SchedDecision = { action :: Str, reason :: Str }

fn run_decision(reason :: Str) -> SchedDecision {
  { action: "run", reason: reason }
}

fn skip_decision(reason :: Str) -> SchedDecision {
  { action: "skip", reason: reason }
}

# Pure classification over already-loaded facts, so every branch is testable
# without a DB or an LLM. Ordering is load-bearing:
#   max_iterations is absolute (run_company's proceed refuses past it, so a
#   run decision would be a pointless invocation); Sunset and stopped are
#   terminal-unless-overridden; dormancy is the cheap steady state; anything
#   left is due.
fn classify(stage :: company.LifecycleStage, cfg :: company.CompanyCfg, ctx :: company.IterCtx, start_idx :: Int, has_backlog :: Bool, has_notes :: Bool) -> SchedDecision {
  if start_idx > cfg.max_iterations {
    skip_decision("max_iterations")
  } else {
    if stage == Sunset {
      if has_backlog {
        run_decision("backlog_reactivation")
      } else {
        skip_decision("sunset")
      }
    } else {
      let stopped := if start_idx <= 1 or str.is_empty(str.trim(cfg.stop_when)) {
        false
      } else {
        company.eval_condition(cfg.stop_when, ctx)
      }
      if stopped {
        if has_notes {
          run_decision("board_note_override")
        } else {
          skip_decision("stopped")
        }
      } else {
        if company.is_dormant(stage, cfg.wake_when, ctx) {
          skip_decision("dormant")
        } else {
          if stage == Maintenance {
            run_decision("woken")
          } else {
            run_decision("due")
          }
        }
      }
    }
  }
}

# Gather a company's facts from its DB and classify. None when the company row
# is missing (an unbootstrapped or corrupt DB) — the caller skips it loudly.
fn classify_company(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_write, time] Option[(company.CompanyCfg, SchedDecision)] {
  match company.load_company(db, company_id) {
    None => None,
    Some(cfg) => {
      let stage := company.load_stage(db, company_id)
      let resume := company.resume_point(db, company_id)
      let has_backlog := match company.next_backlog_item(db, company_id) {
        None => false,
        Some(_) => true,
      }
      let has_notes := not list.is_empty(company.pending_board_notes(db, company_id))
      Some((cfg, classify(stage, cfg, resume.prev_ctx, resume.start_idx, has_backlog, has_notes)))
    },
  }
}

# The between-run sweep for a company this tick did NOT run: the exact
# company_monitor_cmd logic (revenue then liveness, which itself cascades into
# sensing + the operate sweep), so signals keep accruing while the company
# sleeps and a wake_when has something fresh to fire against.
fn monitor_company(db :: conn.ConnDb, company_id :: Str) -> [env, io, sql, fs_read, fs_write, time, proc] Unit {
  let idx := company.latest_iteration_idx(db, company_id)
  if idx == 0 {
    ()
  } else {
    let sprint_id := company.iteration_sprint_id(company_id, idx)
    let __rev := match company.check_and_record_revenue(db, company_id, idx) {
      Err(e) => io.print(str.join(["[scheduler] ", company_id, ": revenue check failed: ", e], "")),
      Ok(_) => (),
    }
    match company.check_and_record_liveness(db, company_id, idx, sprint_id) {
      Err(e) => io.print(str.join(["[scheduler] ", company_id, ": liveness check failed: ", e], "")),
      Ok(_) => (),
    }
  }
}

fn decision_json(d :: SchedDecision, stage :: company.LifecycleStage, start_idx :: Int) -> Str {
  str.join(["{\"action\":\"", d.action, "\",\"reason\":\"", d.reason, "\",\"stage\":\"", company.stage_to_str(stage), "\",\"next_iter\":", int.to_str(start_idx), "}"], "")
}

# Handle one discovered company: open its DB (refuse loudly on failure),
# classify, trail the decision, then run or monitor. Returns 1 if a company
# run was started (counts against MAX_RUNS_PER_TICK), else 0.
fn handle_company(workspace :: Str, company_id :: Str, api_max :: Int, evolve :: Bool, runs_left :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Int {
  let db_path := str.join([workspace, "/", company_id, "/company.db"], "")
  match conn.open(db_path) {
    Err(_) => {
      let __p := io.print(str.join(["[scheduler] SKIP ", company_id, ": cannot open ", db_path, " — refusing to guess (fix or remove the directory)"], ""))
      0
    },
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => {
        let __p := io.print(str.join(["[scheduler] SKIP ", company_id, ": migrate failed: ", e], ""))
        0
      },
      Ok(_) => match classify_company(db, company_id) {
        None => {
          let __p := io.print(str.join(["[scheduler] SKIP ", company_id, ": no company row in ", db_path, " — not bootstrapped?"], ""))
          let __a := tr.push_attention(db, str.join([company_id, "/scheduler"], ""), "scheduler", "config", "board", "")
          0
        },
        Some(pair) => match pair {
          (cfg, d) => {
            let stage := company.load_stage(db, company_id)
            let resume := company.resume_point(db, company_id)
            let __t := tr.trail(db, company_id, "scheduler_decision", decision_json(d, stage, resume.start_idx))
            if d.action == "run" and runs_left > 0 {
              let __p := io.print(str.join(["[scheduler] RUN ", company_id, " (", d.reason, ")"], ""))
              let __seed := pool_seed.seed(db)
              let __res := company_runner.run_company(db, cfg, api_max, evolve)
              1
            } else {
              let why := if d.action == "run" {
                "run_cap_reached"
              } else {
                d.reason
              }
              let __p := io.print(str.join(["[scheduler] skip ", company_id, " (", why, ")"], ""))
              let __m := monitor_company(db, company_id)
              0
            }
          },
        },
      },
    },
  }
}

# All company ids in the workspace (any directory containing a company.db).
# bash resolves the listing exactly like company.sync_project_dir resolves the
# workspace — one idiom for filesystem work loom's stdlib doesn't cover.
fn discover(workspace :: Str) -> [proc] List[Str] {
  let script := str.join(["WS=\"", workspace, "\"; for d in \"$WS\"/*/; do [ -f \"${d}company.db\" ] && basename \"$d\"; done; true"], "")
  match proc.run("bash", ["-c", script]) {
    Err(_) => [],
    Ok(r) => list.filter(str.split(r.stdout, "\n"), fn (l :: Str) -> Bool {
      not str.is_empty(str.trim(l))
    }),
  }
}

fn run_companies(workspace :: Str, ids :: List[Str], api_max :: Int, evolve :: Bool, runs_left :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Int {
  match list.head(ids) {
    None => 0,
    Some(cid) => {
      let started := handle_company(workspace, str.trim(cid), api_max, evolve, runs_left)
      started + run_companies(workspace, list.tail(ids), api_max, evolve, runs_left - started)
    },
  }
}

# One tick: discover, then classify/run/monitor every company. Returns the
# number of company runs started this tick.
fn tick(workspace :: Str, api_max :: Int, evolve :: Bool, max_runs :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Int {
  let ids := discover(workspace)
  let __p := io.print(str.join(["[scheduler] tick: ", int.to_str(list.len(ids)), " company(ies) in ", workspace], ""))
  run_companies(workspace, ids, api_max, evolve, max_runs)
}

fn sched_loop(workspace :: Str, tick_ms :: Int, api_max :: Int, evolve :: Bool, max_runs :: Int, ticks_done :: Int, max_ticks :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let started := tick(workspace, api_max, evolve, max_runs)
  let __p := io.print(str.join(["[scheduler] tick ", int.to_str(ticks_done + 1), " done — ", int.to_str(started), " run(s) started"], ""))
  if max_ticks > 0 and ticks_done + 1 >= max_ticks {
    io.print("[scheduler] MAX_TICKS reached — exiting")
  } else {
    let __s := time.sleep_ms(tick_ms)
    sched_loop(workspace, tick_ms, api_max, evolve, max_runs, ticks_done + 1, max_ticks)
  }
}

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

# Entry point (see bin/loom-scheduler.sh). Environment:
#   LOOM_WORKSPACE    — where companies live      (default: $HOME/loom-companies)
#   TICK_MS           — sleep between ticks       (default: 60000)
#   MAX_RUNS_PER_TICK — company runs per tick cap (default: 1)
#   MAX_TICKS         — 0 = run forever           (default: 0)
#   MAX_API_CALLS     — per-run LLM budget        (default: 200)
#   EVOLVE            — strategist on/off         (default: 1)
fn run_scheduler() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let workspace := get_env("LOOM_WORKSPACE", str.concat(get_env("HOME", "/root"), "/loom-companies"))
  let tick_ms := parse_int_or(get_env("TICK_MS", "60000"), 60000)
  let max_runs := parse_int_or(get_env("MAX_RUNS_PER_TICK", "1"), 1)
  let max_ticks := parse_int_or(get_env("MAX_TICKS", "0"), 0)
  let api_max := parse_int_or(get_env("MAX_API_CALLS", "200"), 200)
  let evolve_flag := get_env("EVOLVE", "1")
  let evolve := if evolve_flag == "0" {
    false
  } else {
    evolve_flag != "false"
  }
  let __p := io.print(str.join(["[scheduler] workspace=", workspace, " tick_ms=", int.to_str(tick_ms), " max_runs_per_tick=", int.to_str(max_runs), " max_ticks=", int.to_str(max_ticks)], ""))
  sched_loop(workspace, tick_ms, api_max, evolve, max_runs, 0, max_ticks)
}

