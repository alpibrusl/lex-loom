# test_company.lex — C1 persistence round-trip + C2 condition DSL (#53).

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-agent/src/memory" as mem

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/company_runner" as company_runner

# ── C2: condition DSL (pure) ──────────────────────────────────────────────────
fn ctx(idx :: Int, verdict :: Str, summary :: Str, acc :: Int, bnc :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: summary, accepted_count: acc, bounced_count: bnc, spend_cents: 0 }
}

fn ctx_with_spend(idx :: Int, verdict :: Str, summary :: Str, acc :: Int, bnc :: Int, spend :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: summary, accepted_count: acc, bounced_count: bnc, spend_cents: spend }
}

fn expect(label :: Str, got :: Bool, want :: Bool) -> Result[Unit, Str] {
  if got == want {
    Ok(())
  } else {
    Err(str.concat("condition mismatch: ", label))
  }
}

fn test_always_empty_never() -> Result[Unit, Str] {
  let c := ctx(1, "passed", "", 0, 0)
  match expect("always", company.eval_condition("always", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("empty=always", company.eval_condition("", c), true) {
      Err(e) => Err(e),
      Ok(_) => expect("never", company.eval_condition("never", c), false),
    },
  }
}

fn test_iter_bounds() -> Result[Unit, Str] {
  let c := ctx(2, "passed", "", 0, 0)
  match expect("iter ge 2", company.eval_condition("iter ge 2", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("iter ge 3", company.eval_condition("iter ge 3", c), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("iter lt 3", company.eval_condition("iter lt 3", c), true) {
        Err(e) => Err(e),
        Ok(_) => expect("iter eq 2", company.eval_condition("iter eq 2", c), true),
      },
    },
  }
}

fn test_verdict_and_counts() -> Result[Unit, Str] {
  let c := ctx(1, "failed", "shipped MVP", 4, 1)
  match expect("verdict-failed", company.eval_condition("verdict-failed", c), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("verdict-passed", company.eval_condition("verdict-passed", c), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("digest contains", company.eval_condition("digest contains \"MVP\"", c), true) {
        Err(e) => Err(e),
        Ok(_) => match expect("digest contains miss", company.eval_condition("digest contains \"refund\"", c), false) {
          Err(e) => Err(e),
          Ok(_) => match expect("accepted ge 4", company.eval_condition("accepted ge 4", c), true) {
            Err(e) => Err(e),
            Ok(_) => expect("bounced lt 1", company.eval_condition("bounced lt 1", c), false),
          },
        },
      },
    },
  }
}

fn test_well_formed() -> Result[Unit, Str] {
  match expect("iter ge 2 wf", company.is_well_formed_condition("iter ge 2"), true) {
    Err(e) => Err(e),
    Ok(_) => match expect("bogus", company.is_well_formed_condition("frobnicate now"), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("iter bad op", company.is_well_formed_condition("iter zz 2"), false) {
        Err(e) => Err(e),
        Ok(_) => expect("digest wf", company.is_well_formed_condition("digest contains \"x\""), true),
      },
    },
  }
}

# ── C1: persistence round-trip (db-backed) ────────────────────────────────────
fn company_eq(a :: company.CompanyCfg, b :: company.CompanyCfg) -> Bool {
  if a.id == b.id {
    if a.goal == b.goal {
      if a.model == b.model {
        if a.max_iterations == b.max_iterations {
          if a.stop_when == b.stop_when {
            if a.pmf_when == b.pmf_when {
              if a.maintenance_when == b.maintenance_when {
                a.wake_when == b.wake_when
              } else {
                false
              }
            } else {
              false
            }
          } else {
            false
          }
        } else {
          false
        }
      } else {
        false
      }
    } else {
      false
    }
  } else {
    false
  }
}

fn test_company_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("co-rt")
        let cfg := { id: id, goal: "build the thing", model: "test", max_iterations: 3, stop_when: "iter ge 3", pmf_when: "verdict-passed", maintenance_when: "iter ge 5", wake_when: "verdict-failed" }
        match company.save_company(db, cfg) {
          Err(e) => Err(str.concat("save_company: ", e)),
          Ok(_) => match company.load_company(db, id) {
            None => Err("load_company returned None"),
            Some(c2) => if company_eq(c2, cfg) {
              run_iter_roundtrip(db, id)
            } else {
              Err("company round-trip mismatch")
            },
          },
        }
      },
    },
  }
}

# split out to keep nesting shallow
fn run_iter_roundtrip(db :: conn.ConnDb, id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g1" }) {
    Err(e) => Err(str.concat("record_iteration: ", e)),
    Ok(_) => match company.record_iteration(db, { company_id: id, idx: 2, sprint_id: str.concat(id, "/iter-2"), parent_sprint_id: str.concat(id, "/iter-1"), status: "running", goal: "g2" }) {
      Err(e) => Err(str.concat("record_iteration 2: ", e)),
      Ok(_) => {
        let latest := company.latest_iteration_idx(db, id)
        if latest == 2 {
          let its := company.load_iterations(db, id)
          if list.len(its) == 2 {
            Ok(())
          } else {
            Err(str.concat("expected 2 iterations, got ", int.to_str(list.len(its))))
          }
        } else {
          Err(str.concat("expected latest idx 2, got ", int.to_str(latest)))
        }
      },
    },
  }
}

fn exec(db :: conn.ConnDb, s :: Str) -> [sql, fs_write] Unit {
  let __r := sql.exec(db.handle, s, [])
  ()
}

fn test_persist_memory() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let __d := exec(db, "INSERT INTO digests (id, sprint_id, summary_text, lessons, seed_graph_json, created_at) VALUES ('d1', 'acme/iter-1', 'sum', 'Use str.split in hot paths.', '{}', '2026-01-01')")
        let __g1 := exec(db, "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', 'acme/iter-1', 'op_grant', '{\"node\":\"build\",\"role\":\"build\",\"agent\":\"build-agent\",\"tools\":\"\"}', 't1')")
        let __g2 := exec(db, "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES ('r', 'acme/iter-1', 'op_grant', '{\"node\":\"qa\",\"role\":\"qa\",\"agent\":\"qa-agent\",\"tools\":\"\"}', 't2')")
        let n := company.persist_iteration_memory(db, "acme/iter-1")
        if n == 2 {
          let entries := mem.recall_all(db, "build-agent")
          match list.head(entries) {
            None => Err("no memory recalled for build-agent"),
            Some(e) => if str.contains(e.content, "str.split") {
              Ok(())
            } else {
              Err(str.concat("recalled wrong content: ", e.content))
            },
          }
        } else {
          Err(str.concat("expected 2 agents updated, got ", int.to_str(n)))
        }
      },
    },
  }
}

fn test_strategist_continue() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"continue\",\"goal\":\"\",\"reason\":\"not met yet\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("expected continue, got ", d.decision))
  }
}

fn test_strategist_revise() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"revise\",\"goal\":\"Narrow to just the parser\",\"reason\":\"too big\"}")
  if d.decision == "revise" {
    if d.goal == "Narrow to just the parser" {
      Ok(())
    } else {
      Err(str.concat("revise goal lost: ", d.goal))
    }
  } else {
    Err(str.concat("expected revise, got ", d.decision))
  }
}

fn test_strategist_revise_no_goal_degrades() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"revise\",\"goal\":\"\",\"reason\":\"x\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("empty-goal revise should degrade to continue, got ", d.decision))
  }
}

fn test_strategist_stop_and_garbage() -> Result[Unit, Str] {
  let s := company.parse_strategist_decision("{\"decision\":\"stop\",\"goal\":\"\",\"reason\":\"mission achieved\"}")
  if s.decision == "stop" {
    let g := company.parse_strategist_decision("not json at all")
    if g.decision == "continue" {
      Ok(())
    } else {
      Err(str.concat("garbage should default to continue, got ", g.decision))
    }
  } else {
    Err(str.concat("expected stop, got ", s.decision))
  }
}

fn test_iteration_sprint_id() -> Result[Unit, Str] {
  if company.iteration_sprint_id("acme", 2) == "acme/iter-2" {
    Ok(())
  } else {
    Err("iteration_sprint_id wrong")
  }
}

# NOTE: this environment's "sqlite::memory:" connection is apparently keyed by
# the literal URL string and can persist across SEPARATE process invocations
# (confirmed empirically), not just within one process. Db-backed tests must
# therefore use a fresh random id each run rather than a fixed literal, or they
# can silently observe state left behind by an earlier `lex run` invocation.
fn rand_id(prefix :: Str) -> [crypto, random] Str {
  str.join([prefix, "-", crypto.random_str_hex(8)], "")
}

fn stage_cfg(pmf :: Str, maint :: Str) -> company.CompanyCfg {
  stage_cfg_id("acme", pmf, maint)
}

fn stage_cfg_id(id :: Str, pmf :: Str, maint :: Str) -> company.CompanyCfg {
  { id: id, goal: "g", model: "m", max_iterations: 10, stop_when: "", pmf_when: pmf, maintenance_when: maint, wake_when: "" }
}

fn test_stage_advances_on_pmf() -> Result[Unit, Str] {
  let cfg := stage_cfg("verdict-passed", "")
  let passed := ctx(1, "passed", "", 1, 0)
  let failed := ctx(1, "failed", "", 0, 1)
  if company.next_stage(Validation, failed, cfg, false) == Validation {
    if company.next_stage(Validation, passed, cfg, false) == Growth {
      Ok(())
    } else {
      Err("PMF met should advance Validation -> Growth")
    }
  } else {
    Err("PMF unmet should stay in Validation")
  }
}

fn test_stage_empty_condition_never_advances() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "")
  let passed := ctx(1, "passed", "", 1, 0)
  if company.next_stage(Validation, passed, cfg, false) == Validation {
    Ok(())
  } else {
    Err("empty pmf_when should never auto-advance")
  }
}

fn test_stage_growth_to_maintenance() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "iter ge 5")
  let early := ctx(3, "passed", "", 1, 0)
  let mature := ctx(5, "passed", "", 1, 0)
  if company.next_stage(Growth, early, cfg, false) == Growth {
    if company.next_stage(Growth, mature, cfg, false) == Maintenance {
      Ok(())
    } else {
      Err("maintenance_when met should advance Growth -> Maintenance")
    }
  } else {
    Err("maintenance_when unmet should stay in Growth")
  }
}

fn test_stage_sunset_from_any_stage() -> Result[Unit, Str] {
  let cfg := stage_cfg("", "")
  let c := ctx(2, "passed", "", 1, 0)
  if company.next_stage(Validation, c, cfg, true) == Sunset {
    if company.next_stage(Growth, c, cfg, true) == Sunset {
      if company.next_stage(Sunset, c, cfg, false) == Sunset {
        Ok(())
      } else {
        Err("sunset must be terminal")
      }
    } else {
      Err("sunset_now should sunset from Growth")
    }
  } else {
    Err("sunset_now should sunset from Validation")
  }
}

fn test_stage_persistence_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("stage-rt")
        match company.save_company(db, stage_cfg_id(id, "verdict-passed", "")) {
          Err(e) => Err(str.concat("save_company: ", e)),
          Ok(_) => {
            let s0 := company.load_stage(db, id)
            if s0 == Ideation {
              match company.save_stage(db, id, Growth) {
                Err(e) => Err(str.concat("save_stage: ", e)),
                Ok(_) => {
                  let s1 := company.load_stage(db, id)
                  if s1 == Growth {
                    Ok(())
                  } else {
                    Err("stage did not persist as Growth")
                  }
                },
              }
            } else {
              Err(str.concat("new company should start in Ideation, got: ", company.stage_to_str(s0)))
            }
          },
        }
      },
    },
  }
}

fn test_is_dormant() -> Result[Unit, Str] {
  let failed := ctx(3, "failed", "", 0, 1)
  let passed := ctx(3, "passed", "", 1, 0)
  match expect("empty wake_when never dormant", company.is_dormant(Maintenance, "", passed), false) {
    Err(e) => Err(e),
    Ok(_) => match expect("non-Maintenance never dormant", company.is_dormant(Growth, "verdict-failed", passed), false) {
      Err(e) => Err(e),
      Ok(_) => match expect("wake_when unmet -> dormant", company.is_dormant(Maintenance, "verdict-failed", passed), true) {
        Err(e) => Err(e),
        Ok(_) => expect("wake_when met -> not dormant", company.is_dormant(Maintenance, "verdict-failed", failed), false),
      },
    },
  }
}

fn test_resume_point_fresh() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let r := company.resume_point(db, rand_id("nope"))
        if r.start_idx == 1 {
          if str.is_empty(r.parent_sprint) {
            if str.is_empty(r.last_goal) {
              Ok(())
            } else {
              Err("fresh company should have no last_goal")
            }
          } else {
            Err("fresh company should have no parent_sprint")
          }
        } else {
          Err(str.concat("fresh company should resume at 1, got ", int.to_str(r.start_idx)))
        }
      },
    },
  }
}

fn test_resume_point_after_iterations() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("resume-it")
        let sprint1 := str.concat(id, "/iter-1")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: sprint1, parent_sprint_id: "", status: "success", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => match company.finish_iteration(db, id, 1, "success") {
            Err(e) => Err(e),
            Ok(_) => {
              let r := company.resume_point(db, id)
              if r.start_idx == 2 {
                if r.parent_sprint == sprint1 {
                  if r.last_goal == "g1" {
                    Ok(())
                  } else {
                    Err(str.concat("expected last_goal 'g1' (what was actually attempted), got: ", r.last_goal))
                  }
                } else {
                  Err(str.concat("wrong parent_sprint: ", r.parent_sprint))
                }
              } else {
                Err(str.concat("expected resume at 2, got ", int.to_str(r.start_idx)))
              }
            },
          },
        }
      },
    },
  }
}

fn test_save_company_preserves_stage() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("save-pres")
        let cfg := stage_cfg_id(id, "verdict-passed", "")
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.save_stage(db, id, Growth) {
            Err(e) => Err(e),
            Ok(_) => match company.save_company(db, cfg) {
              Err(e) => Err(e),
              Ok(_) => {
                let s := company.load_stage(db, id)
                if s == Growth {
                  Ok(())
                } else {
                  Err("re-saving the company must not reset its stage")
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_strategist_add() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"add\",\"goal\":\"Add a subtract function\",\"reason\":\"grow the library\"}")
  if d.decision == "add" {
    if d.goal == "Add a subtract function" {
      Ok(())
    } else {
      Err(str.concat("add goal lost: ", d.goal))
    }
  } else {
    Err(str.concat("expected add, got ", d.decision))
  }
}

fn test_strategist_add_no_goal_degrades() -> Result[Unit, Str] {
  let d := company.parse_strategist_decision("{\"decision\":\"add\",\"goal\":\"\",\"reason\":\"x\"}")
  if d.decision == "continue" {
    Ok(())
  } else {
    Err(str.concat("empty-goal add should degrade to continue, got ", d.decision))
  }
}

fn test_backlog_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("backlog")
        match company.next_backlog_item(db, id) {
          Some(_) => Err("fresh company should have no backlog item"),
          None => match company.append_backlog(db, id, "Add subtract") {
            Err(e) => Err(e),
            Ok(_) => match company.append_backlog(db, id, "Add multiply") {
              Err(e) => Err(e),
              Ok(_) => match company.next_backlog_item(db, id) {
                None => Err("expected a pending backlog item"),
                Some(item) => if item.goal == "Add subtract" {
                  match company.mark_backlog_status(db, id, item.idx, "active") {
                    Err(e) => Err(e),
                    Ok(_) => match company.next_backlog_item(db, id) {
                      None => Err("expected multiply to become the next pending item"),
                      Some(item2) => if item2.goal == "Add multiply" {
                        Ok(())
                      } else {
                        Err(str.concat("expected multiply next, got ", item2.goal))
                      },
                    },
                  }
                } else {
                  Err(str.concat("expected subtract first (FIFO), got ", item.goal))
                },
              },
            },
          },
        }
      },
    },
  }
}

fn test_track_company_id() -> Result[Unit, Str] {
  if company.track_company_id("acme", "web") == "acme/web" {
    Ok(())
  } else {
    Err("track_company_id should compose portfolio_id/track_id")
  }
}

fn test_portfolio_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-rt")
        match company.add_track(db, pid, "web", "Build the web app") {
          Err(e) => Err(e),
          Ok(_) => match company.add_track(db, pid, "cli", "Build the CLI") {
            Err(e) => Err(e),
            Ok(_) => {
              let active := company.active_tracks(db, pid)
              if list.len(active) == 2 {
                match company.mark_track_status(db, pid, "cli", "done") {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let still_active := company.active_tracks(db, pid)
                    if list.len(still_active) == 1 {
                      Ok(())
                    } else {
                      Err(str.concat("expected 1 active track after marking cli done, got ", int.to_str(list.len(still_active))))
                    }
                  },
                }
              } else {
                Err(str.concat("expected 2 active tracks, got ", int.to_str(list.len(active))))
              }
            },
          },
        }
      },
    },
  }
}

fn test_add_track_idempotent() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let pid := rand_id("portfolio-idem")
        match company.add_track(db, pid, "web", "Build the web app") {
          Err(e) => Err(e),
          Ok(_) => match company.mark_track_status(db, pid, "web", "done") {
            Err(e) => Err(e),
            Ok(_) => match company.add_track(db, pid, "web", "a different goal") {
              Err(e) => Err(e),
              Ok(_) => {
                let ts := company.load_tracks(db, pid)
                match list.head(ts) {
                  None => Err("expected the track to still exist"),
                  Some(t) => if t.status == "done" {
                    Ok(())
                  } else {
                    Err("re-seeding an existing track must not reset its status")
                  },
                }
              },
            },
          },
        }
      },
    },
  }
}

fn test_shipped_summary_empty() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let s := company.shipped_summary(db, rand_id("nothing-shipped"))
        if s == "(nothing shipped yet)" {
          Ok(())
        } else {
          Err(str.concat("expected the empty placeholder, got: ", s))
        }
      },
    },
  }
}

fn test_shipped_summary_lists_successes_only() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("shipped")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "Add a Stack module" }) {
          Err(e) => Err(e),
          Ok(_) => match company.record_iteration(db, { company_id: id, idx: 2, sprint_id: str.concat(id, "/iter-2"), parent_sprint_id: str.concat(id, "/iter-1"), status: "failed", goal: "Add a broken module" }) {
            Err(e) => Err(e),
            Ok(_) => {
              let s := company.shipped_summary(db, id)
              if str.contains(s, "Stack module") {
                if str.contains(s, "broken module") {
                  Err("shipped_summary must not list a failed iteration")
                } else {
                  Ok(())
                }
              } else {
                Err(str.concat("expected the shipped Stack module to be listed, got: ", s))
              }
            },
          },
        }
      },
    },
  }
}

fn test_board_notes_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("board")
        let pend0 := company.pending_board_notes(db, id)
        if list.is_empty(pend0) {
          match company.add_board_note(db, id, "focus on the Map module next") {
            Err(e) => Err(e),
            Ok(_) => {
              let pend1 := company.pending_board_notes(db, id)
              if list.len(pend1) == 1 {
                match company.mark_board_notes_consumed(db, id) {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let pend2 := company.pending_board_notes(db, id)
                    if list.is_empty(pend2) {
                      Ok(())
                    } else {
                      Err("note should be consumed after mark_board_notes_consumed")
                    }
                  },
                }
              } else {
                Err(str.concat("expected 1 pending note, got ", int.to_str(list.len(pend1))))
              }
            },
          }
        } else {
          Err("fresh company should have no pending board notes")
        }
      },
    },
  }
}

fn test_board_report_contains_sections() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("board-rt")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "Add the first widget" }) {
            Err(e) => Err(e),
            Ok(_) => match company.append_backlog(db, id, "Add a second widget") {
              Err(e) => Err(e),
              Ok(_) => {
                let report := company.board_report(db, id)
                if str.contains(report, "Build a widget factory") {
                  if str.contains(report, "Add the first widget") {
                    if str.contains(report, "Add a second widget") {
                      Ok(())
                    } else {
                      Err(str.concat("report missing backlog item: ", report))
                    }
                  } else {
                    Err(str.concat("report missing shipped feature: ", report))
                  }
                } else {
                  Err(str.concat("report missing mission: ", report))
                }
              },
            },
          },
        }
      },
    },
  }
}

# ── Operate loop v0 (#84/#85) ─────────────────────────────────────────────
fn insert_test_artifact(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str, content :: Str) -> [sql, time] Result[Unit, Str] {
  let now := time.now_str()
  let hash := str.join([sprint_id, "-", node_id, "-", now], "")
  let q := ormq.for_dialect({ sql: "INSERT OR IGNORE INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES (?, ?, ?, ?, ?)", params: [PStr(hash), PStr(sprint_id), PStr(node_id), PStr(content), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn test_find_launch_url_from_artifact() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-launch")
        match insert_test_artifact(db, sprint_id, "loom-launch", "{\"ok\":true,\"url\":\"http://localhost:9999\",\"response\":\"hi\"}") {
          Err(e) => Err(e),
          Ok(_) => match company.find_launch_url(db, sprint_id) {
            None => Err("expected a launch url, got None"),
            Some(url) => if url == "http://localhost:9999" {
              Ok(())
            } else {
              Err(str.concat("wrong url extracted: ", url))
            },
          },
        }
      },
    },
  }
}

fn test_find_launch_url_none_for_cli() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let sprint_id := rand_id("op-cli")
        match insert_test_artifact(db, sprint_id, "loom-py-build", "print('hello')") {
          Err(e) => Err(e),
          Ok(_) => match company.find_launch_url(db, sprint_id) {
            None => Ok(()),
            Some(url) => Err(str.concat("expected no launch url for a CLI-only sprint, got ", url)),
          },
        }
      },
    },
  }
}

fn test_operate_signal_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-signal")
        let empty := company.recent_operate_signals(db, id, "liveness", 5)
        if list.is_empty(empty) {
          match company.record_operate_signal(db, id, 1, "liveness", "up") {
            Err(e) => Err(e),
            Ok(_) => {
              let after := company.recent_operate_signals(db, id, "liveness", 5)
              if list.len(after) == 1 {
                let first := match list.head(after) {
                  Some(s) => s,
                  None => "",
                }
                if str.contains(first, "up") {
                  Ok(())
                } else {
                  Err("recorded signal missing its value")
                }
              } else {
                Err(str.concat("expected 1 signal, got ", int.to_str(list.len(after))))
              }
            },
          }
        } else {
          Err("fresh company should have no operate signals")
        }
      },
    },
  }
}

fn test_board_report_shows_operate_section() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-report")
        let cfg := { id: id, goal: "Build a live API", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.record_operate_signal(db, id, 1, "liveness", "down") {
            Err(e) => Err(e),
            Ok(_) => {
              let report := company.board_report(db, id)
              if str.contains(report, "down") {
                Ok(())
              } else {
                Err(str.concat("report missing operate signal: ", report))
              }
            },
          },
        }
      },
    },
  }
}

# ── OP2 (#86): Strategist actually sees Operate signals ─────────────────────
fn test_strategist_prompt_includes_operate_signals() -> Result[Unit, Str] {
  let ctx := { idx: 2, last_verdict: "passed", digest_summary: "shipped the widget", accepted_count: 3, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a widget factory", "widget v1", [], "2026-07-06T12:00:00Z: down", "Add widget v2", ctx)
  if str.contains(prompt, "OPERATE SIGNALS") {
    if str.contains(prompt, "down") {
      Ok(())
    } else {
      Err(str.concat("prompt missing the actual signal value: ", prompt))
    }
  } else {
    Err(str.concat("prompt missing OPERATE SIGNALS section: ", prompt))
  }
}

fn test_strategist_prompt_no_signals_yet() -> Result[Unit, Str] {
  let ctx := { idx: 1, last_verdict: "passed", digest_summary: "first ship", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
  let prompt := company_runner.strategist_prompt("Build a widget factory", "(empty)", [], "(no launched server for this company, or no liveness checks yet)", "Ship v1", ctx)
  if str.contains(prompt, "no launched server") {
    Ok(())
  } else {
    Err(str.concat("prompt should gracefully state no signals exist yet: ", prompt))
  }
}

# ── OP3 (#87): cost ledger ────────────────────────────────────────────────────
fn test_parse_dollars_to_cents() -> Result[Unit, Str] {
  if company.parse_dollars_to_cents("5.00") == 500 {
    if company.parse_dollars_to_cents("5") == 500 {
      if company.parse_dollars_to_cents("0.30") == 30 {
        if company.parse_dollars_to_cents("5.5") == 550 {
          Ok(())
        } else {
          Err(str.concat("5.5 -> expected 550, got ", int.to_str(company.parse_dollars_to_cents("5.5"))))
        }
      } else {
        Err(str.concat("0.30 -> expected 30, got ", int.to_str(company.parse_dollars_to_cents("0.30"))))
      }
    } else {
      Err(str.concat("5 -> expected 500, got ", int.to_str(company.parse_dollars_to_cents("5"))))
    }
  } else {
    Err(str.concat("5.00 -> expected 500, got ", int.to_str(company.parse_dollars_to_cents("5.00"))))
  }
}

fn test_spend_condition() -> Result[Unit, Str] {
  let under := ctx_with_spend(3, "passed", "", 0, 0, 250)
  let over := ctx_with_spend(3, "passed", "", 0, 0, 600)
  match expect("spend ge 5.00 under", company.eval_condition("spend ge 5.00", under), false) {
    Err(e) => Err(e),
    Ok(_) => match expect("spend ge 5.00 over", company.eval_condition("spend ge 5.00", over), true) {
      Err(e) => Err(e),
      Ok(_) => match expect("spend lt 5.00 under", company.eval_condition("spend lt 5.00", under), true) {
        Err(e) => Err(e),
        Ok(_) => expect("spend wf", company.is_well_formed_condition("spend ge 5.00"), true),
      },
    },
  }
}

fn test_cost_ledger_roundtrip() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-cost")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => {
            let before := company.get_company_cost_cents(db, id)
            if before == 0 {
              match company.add_company_cost_cents(db, id, 123) {
                Err(e) => Err(e),
                Ok(_) => {
                  let after := company.get_company_cost_cents(db, id)
                  if after == 123 {
                    match company.add_company_cost_cents(db, id, 77) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let after2 := company.get_company_cost_cents(db, id)
                        if after2 == 200 {
                          Ok(())
                        } else {
                          Err(str.concat("expected cumulative 200 cents, got ", int.to_str(after2)))
                        }
                      },
                    }
                  } else {
                    Err(str.concat("expected 123 cents, got ", int.to_str(after)))
                  }
                },
              }
            } else {
              Err("fresh company should have 0 cost")
            }
          },
        }
      },
    },
  }
}

fn test_board_report_shows_spend() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-cost-report")
        let cfg := { id: id, goal: "Build a widget factory", model: "test", max_iterations: 3, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "" }
        match company.save_company(db, cfg) {
          Err(e) => Err(e),
          Ok(_) => match company.add_company_cost_cents(db, id, 530) {
            Err(e) => Err(e),
            Ok(_) => {
              let report := company.board_report(db, id)
              if str.contains(report, "$5.30") {
                Ok(())
              } else {
                Err(str.concat("report missing formatted spend: ", report))
              }
            },
          },
        }
      },
    },
  }
}

# ── OP6 (#90): rough-edge cleanups found live this session ───────────────────
fn test_should_consume_notes_continue_keeps_pending() -> Result[Unit, Str] {
  let notes := ["focus on licensing next"]
  let continue_decision := { decision: "continue", goal: "", reason: "still improving" }
  if company_runner.should_consume_notes(notes, continue_decision) == false {
    Ok(())
  } else {
    Err("a 'continue' decision should NOT consume pending notes")
  }
}

fn test_should_consume_notes_acted_on() -> Result[Unit, Str] {
  let notes := ["focus on licensing next"]
  let revise := { decision: "revise", goal: "add licensing", reason: "pivoting per board note" }
  let add := { decision: "add", goal: "add licensing", reason: "queueing per board note" }
  let stop := { decision: "stop", goal: "", reason: "mission complete" }
  if company_runner.should_consume_notes(notes, revise) {
    if company_runner.should_consume_notes(notes, add) {
      if company_runner.should_consume_notes(notes, stop) {
        Ok(())
      } else {
        Err("'stop' should consume pending notes")
      }
    } else {
      Err("'add' should consume pending notes")
    }
  } else {
    Err("'revise' should consume pending notes")
  }
}

fn test_should_consume_notes_empty_is_noop() -> Result[Unit, Str] {
  let stop := { decision: "stop", goal: "", reason: "mission complete" }
  if company_runner.should_consume_notes([], stop) == false {
    Ok(())
  } else {
    Err("no pending notes should never need consuming")
  }
}

fn test_resume_point_marks_running_as_interrupted() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-interrupt")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "running", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let __rp := company.resume_point(db, id)
            let its := company.load_iterations(db, id)
            match list.head(its) {
              None => Err("expected the iteration row to still exist"),
              Some(it) => if it.status == "interrupted" {
                Ok(())
              } else {
                Err(str.join(["expected status 'interrupted', got '", it.status, "'"], ""))
              },
            }
          },
        }
      },
    },
  }
}

fn test_resume_point_leaves_terminal_status_alone() -> [sql, fs_write, time, crypto, random] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-terminal")
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "success", goal: "g1" }) {
          Err(e) => Err(e),
          Ok(_) => {
            let __rp := company.resume_point(db, id)
            let its := company.load_iterations(db, id)
            match list.head(its) {
              None => Err("expected the iteration row to still exist"),
              Some(it) => if it.status == "success" {
                Ok(())
              } else {
                Err(str.join(["resume_point should not touch a terminal status, got '", it.status, "'"], ""))
              },
            }
          },
        }
      },
    },
  }
}

fn test_graduate_backlog_marks_previous_done() -> [sql, fs_write, time, crypto, random, io] Result[Unit, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let id := rand_id("op-graduate")
        match company.append_backlog(db, id, "ship v1") {
          Err(e) => Err(e),
          Ok(_) => match company.append_backlog(db, id, "ship v2") {
            Err(e) => Err(e),
            Ok(_) => {
              let __first := company_runner.graduate_backlog(db, id, 1)
              let __second := company_runner.graduate_backlog(db, id, 2)
              let items := company.load_backlog(db, id)
              let v1 := list.fold(items, None, fn (acc :: Option[Str], it :: company.BacklogItem) -> Option[Str] {
                match acc {
                  Some(_) => acc,
                  None => if it.idx == 1 { Some(it.status) } else { None },
                }
              })
              match v1 {
                Some(status) => if status == "done" {
                  Ok(())
                } else {
                  Err(str.join(["expected item 1 to be 'done' after graduating past it, got '", status, "'"], ""))
                },
                None => Err("expected backlog item 1 to exist"),
              }
            },
          },
        }
      },
    },
  }
}

fn suite() -> [sql, fs_read, fs_write, time, crypto, random, io] List[Result[Unit, Str]] {
  [test_always_empty_never(), test_iter_bounds(), test_verdict_and_counts(), test_well_formed(), test_iteration_sprint_id(), test_company_roundtrip(), test_persist_memory(), test_strategist_continue(), test_strategist_revise(), test_strategist_revise_no_goal_degrades(), test_strategist_stop_and_garbage(), test_stage_advances_on_pmf(), test_stage_empty_condition_never_advances(), test_stage_growth_to_maintenance(), test_stage_sunset_from_any_stage(), test_stage_persistence_roundtrip(), test_is_dormant(), test_resume_point_fresh(), test_resume_point_after_iterations(), test_save_company_preserves_stage(), test_strategist_add(), test_strategist_add_no_goal_degrades(), test_backlog_roundtrip(), test_track_company_id(), test_portfolio_roundtrip(), test_add_track_idempotent(), test_shipped_summary_empty(), test_shipped_summary_lists_successes_only(), test_board_notes_roundtrip(), test_board_report_contains_sections(), test_find_launch_url_from_artifact(), test_find_launch_url_none_for_cli(), test_operate_signal_roundtrip(), test_board_report_shows_operate_section(), test_strategist_prompt_includes_operate_signals(), test_strategist_prompt_no_signals_yet(), test_parse_dollars_to_cents(), test_spend_condition(), test_cost_ledger_roundtrip(), test_board_report_shows_spend(), test_should_consume_notes_continue_keeps_pending(), test_should_consume_notes_acted_on(), test_should_consume_notes_empty_is_noop(), test_resume_point_marks_running_as_interrupted(), test_resume_point_leaves_terminal_status_alone(), test_graduate_backlog_marks_previous_done()]
}

fn run_all() -> [sql, fs_read, fs_write, time, crypto, random, io] Unit {
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

