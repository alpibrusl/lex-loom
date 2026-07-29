# tests — the first auto tier, behind a circuit breaker (#118/#124, CTL6):
# structural ceilings stay put with no measured record, a class that
# earns a real ≥30-sample/≥70%-hit-rate record reaches Auto, the kill
# test (forced consecutive falsifications trip the breaker and demote
# the class despite a healthy lifetime rate), dwell/concurrency blocking,
# the precondition re-check, and oscillation detection.
#
# Assumes a FRESH store (this suite's own convention throughout: `rm -f
# "sqlite::memory:"` before a clean verification run; CI always starts
# from a fresh checkout). Uses distinct subsystems/companies per test to
# avoid cross-test dwell/concurrency interference within one run.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.io" as io

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/operate_ledger" as ledger

import "../src/sensing" as sensing

import "../src/diagnosis" as diag

import "../src/effects" as eff

import "../src/actuation" as act

fn open_db() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[conn.ConnDb, Str] {
  match conn.open("sqlite::memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn fresh_company(tag :: Str) -> [time] Str {
  str.join(["acttest-", tag, "-", time.now_str()], "")
}

# Seed N clean "materialised" dispositions for a class on a company,
# spaced 1000 idx apart so they never overlap each other's dwell window
# or count as an oscillation pair. Each gets its own incident (unique
# opened_at) so content-addressed ids don't collide. `disposed_at` is
# real wall-clock time — chronological fold order across the whole
# suite must match actual test execution order, not a hand-picked date
# string, or a class's circuit-breaker state depends on which OTHER
# test happened to seed data with a "later-looking" fake timestamp.
fn seed_materialised(db :: conn.ConnDb, cid :: Str, class_key :: Str, n :: Int, base_idx :: Int) -> [sql, time] Result[Unit, Str] {
  if n <= 0 {
    Ok(())
  } else {
    let at := time.now_str()
    match ledger.open_incident(db, cid, "liveness", at, "[\"liveness\"]", 0) {
      Err(e) => Err(e),
      Ok(inc) => match ledger.record_action(db, inc, cid, class_key, cid, "{}", "auto", at) {
        Err(e) => Err(e),
        Ok(act_id) => match ledger.record_effect(db, act_id, inc, "liveness", "below", 1000, at, at, 90, "rollback") {
          Err(e) => Err(e),
          Ok(eff_id) => match ledger.set_effect_window(db, eff_id, base_idx, base_idx + 1) {
            Err(e) => Err(e),
            Ok(_) => match ledger.record_disposition(db, eff_id, "materialised", at) {
              Err(e) => Err(e),
              Ok(_) => seed_materialised(db, cid, class_key, n - 1, base_idx + 1000),
            },
          },
        },
      },
    }
  }
}

# Seed N clean "falsified" dispositions, same shape as seed_materialised
# (real wall-clock `disposed_at`, same reasoning).
fn seed_falsified(db :: conn.ConnDb, cid :: Str, class_key :: Str, n :: Int, base_idx :: Int) -> [sql, time] Result[Unit, Str] {
  if n <= 0 {
    Ok(())
  } else {
    let at := time.now_str()
    match ledger.open_incident(db, cid, "liveness", at, "[\"liveness\"]", 0) {
      Err(e) => Err(e),
      Ok(inc) => match ledger.record_action(db, inc, cid, class_key, cid, "{}", "auto", at) {
        Err(e) => Err(e),
        Ok(act_id) => match ledger.record_effect(db, act_id, inc, "liveness", "below", 1000, at, at, 90, "rollback") {
          Err(e) => Err(e),
          Ok(eff_id) => match ledger.set_effect_window(db, eff_id, base_idx, base_idx + 1) {
            Err(e) => Err(e),
            Ok(_) => match ledger.record_disposition(db, eff_id, "falsified", at) {
              Err(e) => Err(e),
              Ok(_) => seed_falsified(db, cid, class_key, n - 1, base_idx + 1000),
            },
          },
        },
      },
    }
  }
}

# Free the global concurrency slot a proposal occupies once a test is
# done asserting on it — with the design's cap of 1, a contract left
# pending forever would starve every later test's own decide() call.
fn dispose_now(db :: conn.ConnDb, effect_id :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  ledger.record_disposition(db, effect_id, "materialised", at)
}

# Diagnose a company as "transient" (-> class "hold", Auto ceiling) via a
# minimal incident, and propose a contract for it.
fn propose_hold(db :: conn.ConnDb, cid :: Str, now_idx :: Int, at :: Str) -> [sql, time] Result[Str, Str] {
  match ledger.open_incident(db, cid, "liveness", at, "[\"liveness\"]", 1000) {
    Err(e) => Err(e),
    Ok(inc) => match ledger.set_diagnosed_cause(db, inc, "transient", 90) {
      Err(e) => Err(e),
      Ok(_) => eff.propose_contract(db, None, inc, now_idx, at),
    },
  }
}

# Structural ceilings never change regardless of measured record — the
# same invariant CTL5 tested, now exercised through the full decide()
# path (real_tier -> decide). application_error's class (rollback_release)
# is Compensatable/Service — per lex-ctl/tier.ceiling that caps at
# Propose (only Global blast reaches Escalate for a Compensatable
# class; no class in the current vocabulary is Irreversible or Global,
# so none can structurally reach Escalate — see CTL5's own vocabulary).
fn test_compensatable_class_never_clears_to_auto() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("compceil")
      match ledger.open_incident(db, cid, "errors", "2026-01-01T00:00:01", "[\"errors\"]", 1000) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.set_diagnosed_cause(db, inc, "application_error", 90) {
          Err(e) => Err(e),
          Ok(_) => match eff.propose_contract(db, None, inc, 1, "2026-01-01T00:00:02") {
            Err(e) => Err(e),
            Ok(effect_id) => match act.decide(db, effect_id, 1) {
              Err(e) => Err(e),
              Ok(Cleared(Propose)) => dispose_now(db, effect_id, "2026-01-01T00:00:03"),
              Ok(other) => Err(str.concat("expected the application_error class to stay at Propose, got ", act.decision_str(other))),
            },
          },
        },
      }
    },
  }
}

# A class with a healthy real record (≥30 samples, ≥70% hit rate, no
# recent breaker trip), no dwell/concurrency conflict, and an unchanged
# precondition clears all the way to Auto.
fn test_class_with_real_record_reaches_auto() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match seed_materialised(db, fresh_company("history"), "hold", 40, 100000) {
      Err(e) => Err(e),
      Ok(_) => {
        let cid := fresh_company("live")
        match propose_hold(db, cid, 500000, "2026-02-03T00:00:00Z") {
          Err(e) => Err(e),
          Ok(effect_id) => match act.decide(db, effect_id, 500000) {
            Err(e) => Err(e),
            Ok(Cleared(Auto)) => dispose_now(db, effect_id, "2026-02-03T00:00:01Z"),
            Ok(other) => Err(str.concat("expected Cleared(Auto), got ", act.decision_str(other))),
          },
        }
      },
    },
  }
}

# The kill test: 3 consecutive falsified dispositions trip the breaker
# and demote the class to Propose — even though the lifetime hit rate
# (40 hits, 3 misses ≈ 93%) is still comfortably above the 70% bar. The
# breaker is a SEPARATE gate from the aggregate rate.
fn test_circuit_breaker_trips_and_demotes() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let history_co := fresh_company("breaker-hist")
      match seed_materialised(db, history_co, "hold", 40, 200000) {
        Err(e) => Err(e),
        Ok(_) => match seed_falsified(db, history_co, "hold", 3, 240000) {
          Err(e) => Err(e),
          Ok(_) => {
            let cid := fresh_company("breaker-live")
            match propose_hold(db, cid, 900000, "2026-02-04T00:00:00Z") {
              Err(e) => Err(e),
              Ok(effect_id) => match act.decide(db, effect_id, 900000) {
                Err(e) => Err(e),
                Ok(Cleared(Propose)) => dispose_now(db, effect_id, "2026-02-04T00:00:01Z"),
                Ok(other) => Err(str.concat("expected the tripped breaker to demote to Propose, got ", act.decision_str(other))),
              },
            }
          },
        },
      }
    },
  }
}

# A qualified class is Blocked, not Auto, while a prior contract on the
# SAME subsystem is still pending and its window overlaps.
fn test_dwell_lock_blocks_overlapping_action() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match seed_materialised(db, fresh_company("history2"), "hold", 40, 300000) {
      Err(e) => Err(e),
      Ok(_) => {
        let cid := fresh_company("dwell")
        match propose_hold(db, cid, 1, "2026-02-05T00:00:00Z") {
          Err(e) => Err(e),
          Ok(first_effect) => match propose_hold(db, cid, 1, "2026-02-05T00:00:01Z") {
            Err(e) => Err(e),
            Ok(second_effect) => match act.decide(db, second_effect, 1) {
              Err(e) => Err(e),
              Ok(Blocked("dwell_or_concurrency")) => match dispose_now(db, first_effect, "2026-02-05T00:00:02Z") {
                Err(e) => Err(e),
                Ok(_) => dispose_now(db, second_effect, "2026-02-05T00:00:03Z"),
              },
              Ok(other) => Err(str.concat("expected a dwell/concurrency block, got ", act.decision_str(other))),
            },
          },
        }
      },
    },
  }
}

# A precondition mismatch — the observed signal moved between proposal
# and decision — blocks even an otherwise-qualified, otherwise-clear
# action.
fn test_precondition_mismatch_blocks() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match seed_materialised(db, fresh_company("history3"), "hold", 40, 400000) {
      Err(e) => Err(e),
      Ok(_) => {
        let cid := fresh_company("precond")
        match propose_hold(db, cid, 1, "2026-02-06T00:00:00Z") {
          Err(e) => Err(e),
          Ok(effect_id) => {
            let q := ormq.for_dialect({ sql: "INSERT INTO company_operate_signals (id, company_id, idx, kind, value, observed_at, incident_id, score_milli) VALUES (?, ?, ?, ?, ?, ?, '', 5000)", params: [PStr(str.concat(cid, "-late")), PStr(cid), PInt(2), PStr("liveness"), PStr("down (launch: http://x)"), PStr("2026-02-06T00:00:02Z")] }, db.dialect)
            match sql.exec(db.handle, q.sql, q.params) {
              Err(e) => Err(e.message),
              Ok(_) => match act.decide(db, effect_id, 1) {
                Err(e) => Err(e),
                Ok(Blocked("precondition_mismatch")) => dispose_now(db, effect_id, "2026-02-06T00:00:03Z"),
                Ok(other) => Err(str.concat("expected a precondition mismatch block, got ", act.decision_str(other))),
              },
            }
          },
        }
      },
    },
  }
}

# Two same-class, same-subsystem contracts started close together (well
# within 2x dwell) register as an oscillation pair; the same two spaced
# far apart do not add a new one. Delta-based: the store is shared
# across the whole suite.
fn test_oscillation_detection() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("osc")
      match propose_hold(db, cid, 1000, "2026-02-07T00:00:00Z") {
        Err(e) => Err(e),
        Ok(e1) => {
          let before := ledger.oscillation_pairs(db, "hold", 2)
          match propose_hold(db, cid, 1001, "2026-02-07T00:00:01Z") {
            Err(e) => Err(e),
            Ok(e2) => {
              let after_close := ledger.oscillation_pairs(db, "hold", 2)
              match propose_hold(db, cid, 5000, "2026-02-07T00:01:00Z") {
                Err(e) => Err(e),
                Ok(e3) => {
                  let after_far := ledger.oscillation_pairs(db, "hold", 2)
                  let __c1 := dispose_now(db, e1, "2026-02-07T00:02:00Z")
                  let __c2 := dispose_now(db, e2, "2026-02-07T00:02:01Z")
                  let __c3 := dispose_now(db, e3, "2026-02-07T00:02:02Z")
                  if after_close > before and after_far == after_close {
                    Ok(())
                  } else {
                    Err(str.join(["expected a close repeat to add a pair and a far one not to: ", int.to_str(before), " -> ", int.to_str(after_close), " -> ", int.to_str(after_far)], ""))
                  }
                },
              }
            },
          }
        },
      }
    },
  }
}

fn test_dossier_renders_diagnosis() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("dossier")
      match ledger.open_incident(db, cid, "errors", "2026-01-01T00:00:01", "[\"errors\"]", 1000) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.set_diagnosed_cause(db, inc, "application_error", 77) {
          Err(e) => Err(e),
          Ok(_) => {
            let text := act.dossier(db, inc)
            if str.contains(text, "application_error") and str.contains(text, "77") {
              Ok(())
            } else {
              Err(str.concat("expected the dossier to name the diagnosis, got: ", text))
            }
          },
        },
      }
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_compensatable_class_never_clears_to_auto(), test_class_with_real_record_reaches_auto(), test_circuit_breaker_trips_and_demotes(), test_dwell_lock_blocks_overlapping_action(), test_precondition_mismatch_blocks(), test_oscillation_detection(), test_dossier_renders_diagnosis()]
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

