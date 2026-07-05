# test_company.lex — C1 persistence round-trip + C2 condition DSL (#53).

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-agent/src/memory" as mem

import "../src/migrate" as migrate

import "../src/company" as company

# ── C2: condition DSL (pure) ──────────────────────────────────────────────────
fn ctx(idx :: Int, verdict :: Str, summary :: Str, acc :: Int, bnc :: Int) -> company.IterCtx {
  { idx: idx, last_verdict: verdict, digest_summary: summary, accepted_count: acc, bounced_count: bnc }
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
  match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: str.concat(id, "/iter-1"), parent_sprint_id: "", status: "running" }) {
    Err(e) => Err(str.concat("record_iteration: ", e)),
    Ok(_) => match company.record_iteration(db, { company_id: id, idx: 2, sprint_id: str.concat(id, "/iter-2"), parent_sprint_id: str.concat(id, "/iter-1"), status: "running" }) {
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
            Ok(())
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
        match company.record_iteration(db, { company_id: id, idx: 1, sprint_id: sprint1, parent_sprint_id: "", status: "success" }) {
          Err(e) => Err(e),
          Ok(_) => match company.finish_iteration(db, id, 1, "success") {
            Err(e) => Err(e),
            Ok(_) => {
              let r := company.resume_point(db, id)
              if r.start_idx == 2 {
                if r.parent_sprint == sprint1 {
                  Ok(())
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

fn suite() -> [sql, fs_read, fs_write, time, crypto, random] List[Result[Unit, Str]] {
  [test_always_empty_never(), test_iter_bounds(), test_verdict_and_counts(), test_well_formed(), test_iteration_sprint_id(), test_company_roundtrip(), test_persist_memory(), test_strategist_continue(), test_strategist_revise(), test_strategist_revise_no_goal_degrades(), test_strategist_stop_and_garbage(), test_stage_advances_on_pmf(), test_stage_empty_condition_never_advances(), test_stage_growth_to_maintenance(), test_stage_sunset_from_any_stage(), test_stage_persistence_roundtrip(), test_is_dormant(), test_resume_point_fresh(), test_resume_point_after_iterations(), test_save_company_preserves_stage(), test_strategist_add(), test_strategist_add_no_goal_degrades(), test_backlog_roundtrip()]
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

