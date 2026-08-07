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

import "std.fs" as fs

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/operate_ledger" as ledger

import "../src/sensing" as sensing

import "../src/diagnosis" as diag

import "../src/effects" as eff

import "../src/actuation" as act

fn open_db() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[conn.ConnDb, Str] {
  let __clean :: Result[Unit, Str] := fs.remove("sqlite::memory:")
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
# precondition clears all the way to Auto. The record is seeded on the
# SAME company being decided (#134 — tier state is company-scoped, so
# a record on any other company must NOT be able to promote this one).
fn test_class_with_real_record_reaches_auto() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("live")
      match seed_materialised(db, cid, "hold", 40, 100000) {
        Err(e) => Err(e),
        Ok(_) => match propose_hold(db, cid, 500000, "2026-02-03T00:00:00Z") {
          Err(e) => Err(e),
          Ok(effect_id) => match act.decide(db, effect_id, 500000) {
            Err(e) => Err(e),
            Ok(Cleared(Auto)) => dispose_now(db, effect_id, "2026-02-03T00:00:01Z"),
            Ok(other) => Err(str.concat("expected Cleared(Auto), got ", act.decision_str(other))),
          },
        },
      }
    },
  }
}

# The kill test: 3 consecutive falsified dispositions trip the breaker
# and demote the class to Propose — even though the lifetime hit rate
# (40 hits, 3 misses ≈ 93%) is still comfortably above the 70% bar. The
# breaker is a SEPARATE gate from the aggregate rate. The record is
# seeded on the SAME company being decided (#134): the breaker must
# trip that company's own class, not merely exist somewhere in the
# store — seeding it on a different company would (after the #134 fix)
# leave the decided company's own record empty, passing this assertion
# for the wrong reason (insufficient samples, not a tripped breaker).
fn test_circuit_breaker_trips_and_demotes() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("breaker-live")
      match seed_materialised(db, cid, "hold", 40, 200000) {
        Err(e) => Err(e),
        Ok(_) => match seed_falsified(db, cid, "hold", 3, 240000) {
          Err(e) => Err(e),
          Ok(_) => match propose_hold(db, cid, 900000, "2026-02-04T00:00:00Z") {
            Err(e) => Err(e),
            Ok(effect_id) => match act.decide(db, effect_id, 900000) {
              Err(e) => Err(e),
              Ok(Cleared(Propose)) => dispose_now(db, effect_id, "2026-02-04T00:00:01Z"),
              Ok(other) => Err(str.concat("expected the tripped breaker to demote to Propose, got ", act.decision_str(other))),
            },
          },
        },
      }
    },
  }
}

# #158: lex-ctl's own breaker only ever demotes Auto -> Propose — a class
# that structurally ceilings at Propose (Compensatable/Service, e.g.
# application_error's rollback_release) has NO breaker applied to it at
# all, so it can fail forever without ever reaching a human. This is
# loom's own floor on top of lex-ctl's tier model: double the breaker's
# consecutive-miss threshold (6, vs. the breaker's 3) forces Escalate
# regardless of the structural ceiling. 6 consecutive falsified
# dispositions on rollback_release must escalate, not stay at Propose.
fn test_sustained_failures_on_propose_ceiling_escalates() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("escalate-propose")
      match seed_falsified(db, cid, "rollback_release", 6, 1200000) {
        Err(e) => Err(e),
        Ok(_) => match ledger.open_incident(db, cid, "errors", "2026-02-06T00:00:00Z", "[\"errors\"]", 1000) {
          Err(e) => Err(e),
          Ok(inc) => match ledger.set_diagnosed_cause(db, inc, "application_error", 90) {
            Err(e) => Err(e),
            Ok(_) => match eff.propose_contract(db, None, inc, 1300000, "2026-02-06T00:00:01Z") {
              Err(e) => Err(e),
              Ok(effect_id) => match act.decide(db, effect_id, 1300000) {
                Err(e) => Err(e),
                Ok(Cleared(Escalate)) => dispose_now(db, effect_id, "2026-02-06T00:00:02Z"),
                Ok(other) => Err(str.concat("expected 6 consecutive falsifications to force Escalate, got ", act.decision_str(other))),
              },
            },
          },
        },
      }
    },
  }
}

# The same floor also applies on top of an Auto-ceiling class whose
# breaker already tripped it to Propose (#158): the breaker alone caps
# it at Propose forever, but 6 consecutive misses (double the breaker's
# 3) must still escalate — the ladder has a terminal rung, not just an
# Auto<->Propose oscillation.
fn test_sustained_failures_on_auto_ceiling_escalates() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("escalate-auto")
      match seed_materialised(db, cid, "hold", 40, 1400000) {
        Err(e) => Err(e),
        Ok(_) => match seed_falsified(db, cid, "hold", 6, 1440000) {
          Err(e) => Err(e),
          Ok(_) => match propose_hold(db, cid, 1500000, "2026-02-06T00:01:00Z") {
            Err(e) => Err(e),
            Ok(effect_id) => match act.decide(db, effect_id, 1500000) {
              Err(e) => Err(e),
              Ok(Cleared(Escalate)) => dispose_now(db, effect_id, "2026-02-06T00:01:01Z"),
              Ok(other) => Err(str.concat("expected 6 consecutive misses to escalate past Propose, got ", act.decision_str(other))),
            },
          },
        },
      }
    },
  }
}

# #134: a tripped breaker on one company must never leak into another
# company's decision for the same class_key. "noisy" trips the breaker
# for its own "hold" class; "cid" independently earns a clean 40-sample
# healthy record for the SAME class_key and must still reach Auto —
# proving the measured record is scoped per company, not global.
fn test_tier_state_is_isolated_per_company() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let noisy := fresh_company("isolation-noisy")
      match seed_falsified(db, noisy, "hold", 3, 600000) {
        Err(e) => Err(e),
        Ok(_) => {
          let cid := fresh_company("isolation-clean")
          match seed_materialised(db, cid, "hold", 40, 700000) {
            Err(e) => Err(e),
            Ok(_) => match propose_hold(db, cid, 1100000, "2026-02-05T00:00:00Z") {
              Err(e) => Err(e),
              Ok(effect_id) => match act.decide(db, effect_id, 1100000) {
                Err(e) => Err(e),
                Ok(Cleared(Auto)) => dispose_now(db, effect_id, "2026-02-05T00:00:01Z"),
                Ok(other) => Err(str.concat("another company's tripped breaker must not affect this company's decision, got ", act.decision_str(other))),
              },
            },
          }
        },
      }
    },
  }
}

# A qualified class is Blocked, not Auto, while a prior contract on the
# SAME subsystem is still pending and its window overlaps. The healthy
# record is seeded on the SAME company (#134 — tier state is company-
# scoped), or this company would never reach Auto-eligibility to test
# the structural block against in the first place.
fn test_dwell_lock_blocks_overlapping_action() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("dwell")
      match seed_materialised(db, cid, "hold", 40, 300000) {
        Err(e) => Err(e),
        Ok(_) => match propose_hold(db, cid, 1, "2026-02-05T00:00:00Z") {
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
        },
      }
    },
  }
}

# A precondition mismatch — the observed signal moved between proposal
# and decision — blocks even an otherwise-qualified, otherwise-clear
# action. The healthy record is seeded on the SAME company (#134).
fn test_precondition_mismatch_blocks() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("precond")
      match seed_materialised(db, cid, "hold", 40, 400000) {
        Err(e) => Err(e),
        Ok(_) => match propose_hold(db, cid, 1, "2026-02-06T00:00:00Z") {
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
        },
      }
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

# End-to-end for #126's trail-integration gap: a class's first-ever tier
# read seeds `operate_tier_state` silently (no event — there is no prior
# tier to report a move FROM), a later disposition-driven promotion to
# Auto emits exactly one `loom.operate.tier.changed` event, and a third
# call with no new dispositions emits no further event — the trail
# reflects state CHANGES, not every sweep.
fn tier_changed_events(log :: tlog.Log) -> [sql] Result[List[Str], Str] {
  match tlog.range(log, 0, 9999999999999) {
    Err(e) => Err(e),
    Ok(evts) => Ok(list.map(list.filter(evts, fn (e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> Bool {
      e.kind == "loom.operate.tier.changed"
    }), fn (e :: { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }) -> Str {
      e.payload_json
    })),
  }
}

fn test_tier_promotion_emits_trail_event_once() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let cid := fresh_company("tiertrail")
        match act.record_all_tier_transitions(db, Some(log), cid, "2026-02-06T00:00:00Z") {
          Err(e) => Err(e),
          Ok(_) => match ledger.tier_state(db, cid, "restart") {
            None => Err("expected the first sweep to seed a tier state"),
            Some(seeded) => if seeded != "propose" {
              Err(str.concat("expected the class to seed at 'propose', got ", seeded))
            } else {
              match tier_changed_events(log) {
                Err(e) => Err(e),
                Ok(before) => if list.len(before) != 0 {
                  Err("expected no trail event from the seeding sweep")
                } else {
                  match seed_materialised(db, cid, "restart", 30, 200000) {
                    Err(e) => Err(e),
                    Ok(_) => match act.record_all_tier_transitions(db, Some(log), cid, "2026-02-06T00:01:00Z") {
                      Err(e) => Err(e),
                      Ok(_) => match ledger.tier_state(db, cid, "restart") {
                        None => Err("expected a tier state after promotion"),
                        Some(promoted) => if promoted != "auto" {
                          Err(str.concat("expected promotion to 'auto', got ", promoted))
                        } else {
                          match tier_changed_events(log) {
                            Err(e) => Err(e),
                            Ok(after_promo) => if list.len(after_promo) != 1 {
                              Err(str.concat("expected exactly 1 tier.changed event, got ", int.to_str(list.len(after_promo))))
                            } else {
                              match list.head(after_promo) {
                                None => Err("expected a payload"),
                                Some(payload) => if str.contains(payload, "\"from\":\"propose\"") and str.contains(payload, "\"to\":\"auto\"") {
                                  match act.record_all_tier_transitions(db, Some(log), cid, "2026-02-06T00:02:00Z") {
                                    Err(e) => Err(e),
                                    Ok(_) => match tier_changed_events(log) {
                                      Err(e) => Err(e),
                                      Ok(steady) => if list.len(steady) == 1 {
                                        Ok(())
                                      } else {
                                        Err(str.concat("expected no NEW event on a steady-state sweep, count is now ", int.to_str(list.len(steady))))
                                      },
                                    },
                                  }
                                } else {
                                  Err(str.concat("unexpected payload: ", payload))
                                },
                              }
                            },
                          }
                        },
                      },
                    },
                  }
                },
              }
            },
          },
        }
      },
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_compensatable_class_never_clears_to_auto(), test_class_with_real_record_reaches_auto(), test_circuit_breaker_trips_and_demotes(), test_sustained_failures_on_propose_ceiling_escalates(), test_sustained_failures_on_auto_ceiling_escalates(), test_tier_state_is_isolated_per_company(), test_dwell_lock_blocks_overlapping_action(), test_precondition_mismatch_blocks(), test_oscillation_detection(), test_dossier_renders_diagnosis(), test_tier_promotion_emits_trail_event_once()]
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

