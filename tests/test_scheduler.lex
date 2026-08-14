# test_scheduler.lex — HB1 (#213): the heartbeat's classification logic.
#
# `classify` is pure over already-loaded facts, so every branch of the
# run/skip decision — the part that makes "a stopped company stays stopped"
# and "a dormant company wakes when wake_when fires" true — is asserted here
# with no DB and no LLM. `classify_company` is then round-tripped once against
# a real migrated DB to prove the fact-gathering wiring (load_company,
# resume_point, backlog, board notes) feeds the pure core correctly.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/scheduler" as scheduler

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn cfg_with(stop_when :: Str, wake_when :: Str, max_iterations :: Int) -> company.CompanyCfg {
  { id: "sched-test", goal: "g", model: "m", max_iterations: max_iterations, stop_when: stop_when, pmf_when: "", maintenance_when: "", wake_when: wake_when, soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn ctx_with(idx :: Int, verdict :: Str, spend_cents :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: "", accepted_count: 0, bounced_count: 0, spend_cents: spend_cents }
}

# A fresh company (Ideation, nothing recorded) is simply due.
fn test_fresh_company_runs() -> Result[Unit, Str] {
  let d := scheduler.classify(Ideation, cfg_with("", "", 3), ctx_with(1, "", 0), 1, false, false, "")
  check("fresh company is due to run", d.action == "run" and d.reason == "due")
}

# A stop_when can only hold once an iteration was actually recorded:
# resume_point's fresh default ctx has idx 1, which would otherwise make
# `iter ge 1` "hold" before the company ever ran once.
fn test_stop_when_needs_history() -> Result[Unit, Str] {
  let d := scheduler.classify(Ideation, cfg_with("iter ge 1", "", 3), ctx_with(1, "", 0), 1, false, false, "")
  check("fresh company with iter ge 1 stop still runs", d.action == "run" and d.reason == "due")
}

# Past max_iterations nothing runs, whatever else holds — proceed would refuse.
fn test_max_iterations_is_absolute() -> Result[Unit, Str] {
  let d := scheduler.classify(Growth, cfg_with("", "", 2), ctx_with(2, "passed", 0), 3, true, true, "")
  check("past max_iterations skips even with backlog+notes", d.action == "skip" and d.reason == "max_iterations")
}

# Sunset is terminal — unless a backlog item is queued (the strategist's
# earlier "stop" meant "this goal is done", not "the company is done").
fn test_sunset_stays_down_without_backlog() -> Result[Unit, Str] {
  let d := scheduler.classify(Sunset, cfg_with("", "", 5), ctx_with(2, "passed", 0), 3, false, false, "")
  check("sunset without backlog skips", d.action == "skip" and d.reason == "sunset")
}

fn test_sunset_reactivates_via_backlog() -> Result[Unit, Str] {
  let d := scheduler.classify(Sunset, cfg_with("", "", 5), ctx_with(2, "passed", 0), 3, true, false, "")
  check("sunset with backlog runs", d.action == "run" and d.reason == "backlog_reactivation")
}

# The acceptance criterion for #213: a company stopped by its stop_when
# condition STAYS stopped — the scheduler must not resurrect it on its own.
fn test_stopped_company_stays_stopped() -> Result[Unit, Str] {
  let d := scheduler.classify(Growth, cfg_with("spend ge 1.00", "", 5), ctx_with(2, "passed", 250), 3, false, false, "")
  check("stop_when holding skips", d.action == "skip" and d.reason == "stopped")
}

# ...and the ONLY thing that overrides a stop is an explicit pending board
# note: the board intervened, so the strategist gets one iteration to hear it.
fn test_board_note_overrides_stop() -> Result[Unit, Str] {
  let d := scheduler.classify(Growth, cfg_with("spend ge 1.00", "", 5), ctx_with(2, "passed", 250), 3, false, true, "")
  check("pending board note runs a stopped company", d.action == "run" and d.reason == "board_note_override")
}

# Maintenance with an unmet wake_when is the cheap dormant steady state.
fn test_dormant_company_skips() -> Result[Unit, Str] {
  let d := scheduler.classify(Maintenance, cfg_with("", "verdict-failed", 9), ctx_with(2, "passed", 0), 3, false, false, "")
  check("maintenance with unmet wake_when is dormant", d.action == "skip" and d.reason == "dormant")
}

# When the wake condition fires against the last grounded ctx, it wakes.
fn test_wake_when_fires() -> Result[Unit, Str] {
  let d := scheduler.classify(Maintenance, cfg_with("", "verdict-failed", 9), ctx_with(2, "failed", 0), 3, false, false, "")
  check("maintenance with met wake_when wakes", d.action == "run" and d.reason == "woken")
}

# stop_when wins over dormancy: a stopped Maintenance company with a firing
# wake_when still stays down without a board note.
fn test_stop_beats_wake() -> Result[Unit, Str] {
  let d := scheduler.classify(Maintenance, cfg_with("spend ge 1.00", "verdict-failed", 9), ctx_with(2, "failed", 250), 3, false, false, "")
  check("stopped beats woken", d.action == "skip" and d.reason == "stopped")
}

# GOV1 (#221): a parked company with an unresolved blocking gate stays put —
# nothing but a board resolution moves it.
fn test_parked_pending_skips() -> Result[Unit, Str] {
  let d := scheduler.classify(Growth, cfg_with("", "", 5), ctx_with(2, "passed", 0), 2, true, true, "pending")
  check("pending gate keeps the company parked", d.action == "skip" and d.reason == "parked")
}

# ...and once every gate item is resolved, it is due to re-enter the SAME
# iteration (approved gates seal, rejected gates cancel — decided in-sprint).
fn test_parked_resolved_resumes() -> Result[Unit, Str] {
  let d := scheduler.classify(Growth, cfg_with("", "", 5), ctx_with(2, "passed", 0), 2, false, false, "resolved")
  check("resolved gates resume the company", d.action == "run" and d.reason == "gate_resolved")
}

# Round-trip against a real DB: the fact-gathering feeds the pure core.
fn test_classify_company_round_trip() -> [sql, fs_read, fs_write, time, io, random, crypto] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open memory db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate: ", e)),
      Ok(_) => {
        let cfg := cfg_with("iter ge 1", "", 5)
        match company.save_company(db, cfg) {
          Err(e) => Err(str.concat("save_company: ", e)),
          Ok(_) => match scheduler.classify_company(db, "sched-test") {
            None => Err("classify_company found no company row after save"),
            Some(p1) => match p1 {
              (_, d1) => match check("fresh saved company is due", d1.action == "run" and d1.reason == "due") {
                Err(e) => Err(e),
                Ok(_) => {
                  let __it := company.record_iteration(db, { company_id: "sched-test", idx: 1, sprint_id: "sched-test/iter-1", parent_sprint_id: "", status: "running", goal: "g" })
                  let __fin := company.finish_iteration(db, "sched-test", 1, "success")
                  match scheduler.classify_company(db, "sched-test") {
                    None => Err("classify_company lost the company row"),
                    Some(p2) => match p2 {
                      (_, d2) => match check("stop_when iter ge 1 now holds -> stopped", d2.action == "skip" and d2.reason == "stopped") {
                        Err(e) => Err(e),
                        Ok(_) => {
                          let __note := company.add_board_note(db, "sched-test", "board says: one more push")
                          match scheduler.classify_company(db, "sched-test") {
                            None => Err("classify_company lost the company row after note"),
                            Some(p3) => match p3 {
                              (_, d3) => check("pending board note overrides the stop", d3.action == "run" and d3.reason == "board_note_override"),
                            },
                          }
                        },
                      },
                    },
                  }
                },
              },
            },
          },
        }
      },
    },
  }
}

# An unknown company id is refused, not guessed at.
fn test_unknown_company_is_none() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open memory db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate: ", e)),
      Ok(_) => match scheduler.classify_company(db, "nope") {
        None => Ok(()),
        Some(_) => Err("classify_company invented a company"),
      },
    },
  }
}

fn suite() -> [sql, fs_write, fs_read, time, io, random, crypto] List[Result[Unit, Str]] {
  [test_fresh_company_runs(), test_stop_when_needs_history(), test_max_iterations_is_absolute(), test_sunset_stays_down_without_backlog(), test_sunset_reactivates_via_backlog(), test_stopped_company_stays_stopped(), test_board_note_overrides_stop(), test_dormant_company_skips(), test_wake_when_fires(), test_stop_beats_wake(), test_parked_pending_skips(), test_parked_resolved_resumes(), test_classify_company_round_trip(), test_unknown_company_is_none()]
}

fn run_all() -> [io, sql, fs_write, fs_read, time, random, crypto] Unit {
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

