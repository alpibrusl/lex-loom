# tests — shadow effect contracts + counterfactual verifier (#118/#123,
# CTL5): propose over a diagnosed incident, judge materialised /
# falsified / ambiguous (ambiguous = miss), sensing-gap incidents cannot
# be contracted, the confabulator guard, and hit-rate/sample exposure.
#
# Uses time-suffixed company ids (see test_operate_ledger.lex for why);
# "now_idx" is loom's own clock (the between-iteration counter), not
# wall time — see effects.lex's header comment.

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
  str.join(["efftest-", tag, "-", time.now_str()], "")
}

fn seed_signal(db :: conn.ConnDb, company_id :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  let id := str.join([company_id, "-", kind, "-", int.to_str(idx), "-", at], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO company_operate_signals (id, company_id, idx, kind, value, observed_at, incident_id, score_milli) VALUES (?, ?, ?, ?, ?, ?, '', 0)", params: [PStr(id), PStr(company_id), PInt(idx), PStr(kind), PStr(value), PStr(at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn round(db :: conn.ConnDb, cid :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql, time] Result[Int, Str] {
  match seed_signal(db, cid, idx, kind, value, at) {
    Err(e) => Err(str.concat("seed: ", e)),
    Ok(_) => sensing.sense_company(db, None, cid, sensing.default_policy()),
  }
}

type CountRow = { n :: Int }

# Raw materialised-hit count for a class, independent of
# class_hit_rate_pct's rounding — the store is shared/cumulative across
# the whole suite (see test_operate_ledger.lex's header note), so
# assertions here are delta-based rather than absolute.
fn materialised_count(db :: conn.ConnDb, class_key :: Str) -> [sql] Int {
  let stmt := "SELECT COUNT(*) AS n FROM operate_effects e JOIN operate_actions a ON e.action_id=a.id WHERE a.class_key=? AND e.disposition='materialised'"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(class_key)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Build + diagnose the canonical down-down-up outage episode, returning
# its incident id. Diagnosed via diag.diagnose so diagnosed_cause is set
# (propose_contract requires a diagnosis).
fn build_diagnosed_outage(db :: conn.ConnDb, cid :: Str) -> [sql, fs_write, time] Result[Str, Str] {
  match tlog.open_memory() {
    Err(e) => Err(e),
    Ok(log) => {
      let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
      let __2 := seed_signal(db, cid, 2, "liveness", "down (launch: http://x)", "2026-01-01T00:00:02")
      let __3 := seed_signal(db, cid, 3, "liveness", "up (launch: http://x)", "2026-01-01T00:00:03")
      match ledger.backfill_company(db, log, cid) {
        Err(e) => Err(e),
        Ok(_) => match sensing.backfill_score(db, cid, sensing.default_policy()) {
          Err(e) => Err(str.concat("backfill_score: ", e)),
          Ok(_) => match list.head(ledger.incidents_for(db, cid)) {
            None => Err("no incident from backfill"),
            Some(inc) => match diag.diagnose(db, None, inc, 60, 1000, "2026-01-01T00:01:00") {
              Err(e) => Err(e),
              Ok(_) => Ok(inc),
            },
          },
        },
      }
    },
  }
}

# Propose+verify end to end: the outage's remediation ("restart",
# predicate on "liveness") observes the ALREADY-RECOVERED signal
# (score_milli 0 after backfill's healthy "up" reading) once the
# deadline idx is reached -> Materialised.
fn test_contract_materialises_on_recovered_signal() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match build_diagnosed_outage(db, fresh_company("materialise")) {
      Err(e) => Err(e),
      Ok(inc) => match eff.propose_contract(db, None, inc, 10, "2026-01-01T00:01:00") {
        Err(e) => Err(str.concat("propose: ", e)),
        Ok(effect_id) => match eff.verify_contract(db, None, effect_id, 20, "2026-01-01T00:02:00") {
          Err(e) => Err(str.concat("verify: ", e)),
          Ok(Materialised) => Ok(()),
          Ok(_) => Err("expected the recovered-server contract to materialise"),
        },
      },
    },
  }
}

# Before the deadline idx is reached, verification is Pending and leaves
# the row untouched (idempotent re-check).
fn test_contract_pending_before_deadline() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match build_diagnosed_outage(db, fresh_company("pending")) {
      Err(e) => Err(e),
      Ok(inc) => match eff.propose_contract(db, None, inc, 10, "2026-01-01T00:01:00") {
        Err(e) => Err(e),
        Ok(effect_id) => match eff.verify_contract(db, None, effect_id, 11, "2026-01-01T00:01:30") {
          Err(e) => Err(e),
          Ok(Pending) => Ok(()),
          Ok(_) => Err("expected Pending before the deadline idx"),
        },
      },
    },
  }
}

# A server that never recovers (still "down" at verify time) falsifies
# the same restart contract.
fn test_contract_falsifies_on_unrecovered_signal() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("falsify")
      match tlog.open_memory() {
        Err(e) => Err(e),
        Ok(log) => {
          let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
          let __2 := seed_signal(db, cid, 2, "liveness", "down (launch: http://x)", "2026-01-01T00:00:02")
          match ledger.backfill_company(db, log, cid) {
            Err(e) => Err(e),
            Ok(_) => match sensing.backfill_score(db, cid, sensing.default_policy()) {
              Err(e) => Err(str.concat("backfill_score: ", e)),
              Ok(_) => match list.head(ledger.incidents_for(db, cid)) {
                None => Err("no incident opened"),
                Some(inc) => match diag.diagnose(db, None, inc, 60, 1000, "2026-01-01T00:00:30") {
                  Err(e) => Err(e),
                  Ok(_) => match eff.propose_contract(db, None, inc, 10, "2026-01-01T00:01:00") {
                    Err(e) => Err(e),
                    Ok(effect_id) => match eff.verify_contract(db, None, effect_id, 20, "2026-01-01T00:02:00") {
                      Err(e) => Err(e),
                      Ok(Falsified) => Ok(()),
                      Ok(_) => Err("expected the still-down server's contract to be falsified"),
                    },
                  },
                },
              },
            },
          }
        },
      }
    },
  }
}

# Two proposals on the SAME subsystem with overlapping windows: judging
# the first one while the second is still pending on the same subsystem
# must be Ambiguous, not Materialised — and Ambiguous must NOT count as
# a hit for the class's rate.
fn test_overlapping_actions_are_ambiguous_and_a_miss() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match build_diagnosed_outage(db, fresh_company("ambiguous")) {
      Err(e) => Err(e),
      Ok(inc) => match eff.propose_contract(db, None, inc, 10, "2026-01-01T00:01:00") {
        Err(e) => Err(e),
        Ok(effect_a) => match eff.propose_contract(db, None, inc, 12, "2026-01-01T00:01:10") {
          Err(e) => Err(e),
          Ok(_) => {
            let before := materialised_count(db, "restart")
            match eff.verify_contract(db, None, effect_a, 20, "2026-01-01T00:02:00") {
              Err(e) => Err(e),
              Ok(Ambiguous) => if materialised_count(db, "restart") == before {
                Ok(())
              } else {
                Err("ambiguous disposition was counted as a materialised hit")
              },
              Ok(_) => Err("expected the overlapping contract to be judged Ambiguous"),
            }
          },
        },
      },
    },
  }
}

# A sensing-gap incident (no diagnosed cause) has nothing to remediate —
# proposing a contract on it must be refused, not silently defaulted.
fn test_no_contract_without_a_diagnosis() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("nodiag")
      match ledger.open_incident(db, cid, "liveness", "2026-01-01T00:00:01", "[\"liveness\"]", 1000) {
        Err(e) => Err(e),
        Ok(inc) => match eff.propose_contract(db, None, inc, 1, "2026-01-01T00:00:02") {
          Err(_) => Ok(()),
          Ok(_) => Err("a contract was proposed for an undiagnosed incident"),
        },
      }
    },
  }
}

# A missing signal at verify time (the series was never recorded) is a
# falsification, not a crash or a silent Pending.
fn test_missing_signal_is_falsified() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("missing")
      match ledger.open_incident(db, cid, "errors", "2026-01-01T00:00:01", "[\"errors\"]", 1000) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.set_diagnosed_cause(db, inc, "application_error", 80) {
          Err(e) => Err(e),
          Ok(_) => match eff.propose_contract(db, None, inc, 1, "2026-01-01T00:00:02") {
            Err(e) => Err(e),
            Ok(effect_id) => match eff.verify_contract(db, None, effect_id, 10, "2026-01-01T00:01:00") {
              Err(e) => Err(e),
              Ok(Falsified) => Ok(()),
              Ok(_) => Err("expected an unobserved signal to falsify the contract"),
            },
          },
        },
      }
    },
  }
}

# verify_pending sweeps every contract whose deadline has arrived and is
# idempotent (a second sweep with no new pending work finalises nothing).
# The suite shares one ledger, so verify_pending's FIRST sweep may also
# finalise stray pending contracts left by other tests (an unverified
# second proposal, an unresolvable window elsewhere) — assert only that
# THIS test's own contract gets swept (n1 >= 1) and that a second sweep
# at the same now_idx, immediately after, finds nothing new (n2 == 0),
# which holds regardless of what else the first sweep touched.
fn test_verify_pending_sweeps_and_is_idempotent() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match build_diagnosed_outage(db, fresh_company("sweep")) {
      Err(e) => Err(e),
      Ok(inc) => match eff.propose_contract(db, None, inc, 10, "2026-01-01T00:01:00") {
        Err(e) => Err(e),
        Ok(effect_id) => match eff.verify_pending(db, None, 20, "2026-01-01T00:02:00") {
          Err(e) => Err(e),
          Ok(n1) => match eff.verify_contract(db, None, effect_id, 20, "2026-01-01T00:02:00") {
            Err(e) => Err(e),
            Ok(own_outcome) => match eff.verify_pending(db, None, 20, "2026-01-01T00:02:01") {
              Err(e) => Err(e),
              Ok(n2) => if n1 >= 1 and n2 == 0 and own_outcome != Pending {
                Ok(())
              } else {
                Err(str.join(["expected >=1 then 0 across the two sweeps, got ", int.to_str(n1), " then ", int.to_str(n2)], ""))
              },
            },
          },
        },
      },
    },
  }
}

# Structural ceiling: "scale" (Compensatable/Service) can never exceed
# Propose regardless of any measured record — a class the design says
# must never be `promotable` for Auto, no matter its hit rate.
fn test_compensatable_class_ceiling_is_propose() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let status := eff.class_promotion_status(db, "scale")
      match status.ceiling {
        Propose => if not status.promotable {
          Ok(())
        } else {
          Err("a Propose-ceiling class must never be promotable")
        },
        _ => Err("expected the scale class's ceiling to be Propose"),
      }
    },
  }
}

# Structural ceiling: "restart" (Idempotent/Instance) reaches Auto — the
# highest ceiling any class in this vocabulary can earn. Promotion
# itself (CTL6) depends on the measured record, which this test does not
# assume anything about (the ledger accumulates samples across the whole
# suite; only the classification-derived ceiling is structural/fixed).
fn test_idempotent_class_ceiling_is_auto() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let status := eff.class_promotion_status(db, "restart")
      match status.ceiling {
        Auto => Ok(()),
        _ => Err("expected the restart class's ceiling to be Auto"),
      }
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_contract_materialises_on_recovered_signal(), test_contract_pending_before_deadline(), test_contract_falsifies_on_unrecovered_signal(), test_overlapping_actions_are_ambiguous_and_a_miss(), test_no_contract_without_a_diagnosis(), test_missing_signal_is_falsified(), test_verify_pending_sweeps_and_is_idempotent(), test_compensatable_class_ceiling_is_propose(), test_idempotent_class_ceiling_is_auto()]
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

