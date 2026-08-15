# tests — operate ledger (#118/#120, CTL2): schema, backfill, replay,
# budget refusal, disposition semantics.
#
# Note: conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) is backed by a shared on-disk file in
# this environment (fresh per CI checkout, persistent across local runs),
# so every test uses a time-suffixed company id to stay idempotent.

import "std.sql" as sql

import "std.str" as str

import "std.crypto" as crypto

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

fn open_db() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn fresh_company(tag :: Str) -> [time] Str {
  str.join(["opltest-", tag, "-", time.now_str()], "")
}

fn seed_signal(db :: conn.ConnDb, company_id :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  let id := str.join([company_id, "-", kind, "-", at], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO company_operate_signals (id, company_id, idx, kind, value, observed_at, incident_id, score_milli) VALUES (?, ?, ?, ?, ?, ?, '', 0)", params: [PStr(id), PStr(company_id), PInt(idx), PStr(kind), PStr(value), PStr(at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# down, down, up → exactly one episode, resolved at the up reading.
fn test_backfill_groups_episode() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match tlog.open_memory() {
      Err(e) => Err(str.concat("trail open failed: ", e)),
      Ok(log) => {
        let cid := fresh_company("group")
        match seed_signal(db, cid, 1, "liveness", "up (launch: http://x)", "2026-01-01T00:00:01") {
          Err(e) => Err(str.concat("seed failed: ", e)),
          Ok(_) => {
            let __2 := seed_signal(db, cid, 2, "liveness", "down (launch: http://x)", "2026-01-01T00:00:02")
            let __3 := seed_signal(db, cid, 3, "liveness", "down (launch: http://x)", "2026-01-01T00:00:03")
            let __4 := seed_signal(db, cid, 4, "liveness", "up (launch: http://x)", "2026-01-01T00:00:04")
            match ledger.backfill_company(db, log, cid) {
              Err(e) => Err(str.concat("backfill failed: ", e)),
              Ok(n) => if n == 1 {
                if list.len(ledger.incidents_for(db, cid)) == 1 {
                  Ok(())
                } else {
                  Err("incident count for company != 1")
                }
              } else {
                Err(str.concat("expected 1 episode, got ", int.to_str(n)))
              },
            }
          },
        }
      },
    },
  }
}

fn test_backfill_idempotent() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let cid := fresh_company("idem")
        let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
        let __2 := seed_signal(db, cid, 2, "liveness", "up (launch: http://x)", "2026-01-01T00:00:02")
        match ledger.backfill_company(db, log, cid) {
          Err(e) => Err(e),
          Ok(_) => match ledger.backfill_company(db, log, cid) {
            Err(e) => Err(e),
            Ok(n2) => if n2 == 0 and list.len(ledger.incidents_for(db, cid)) == 1 {
              Ok(())
            } else {
              Err("re-run created duplicate episodes")
            },
          },
        }
      },
    },
  }
}

# #137: liveness and errors are backfilled as independent per-kind
# streams; if a company's history ends unhealthy on BOTH at once, each
# kind's walk used to leave its own incident open. reconcile_open_
# incidents must collapse that back down to exactly one, so a live
# firing after backfill unambiguously attaches to the same incident
# `sensing.open_incident_for` would pick.
fn test_backfill_merges_concurrent_open_incidents() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let cid := fresh_company("dualopen")
        let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
        let __2 := seed_signal(db, cid, 2, "errors", "Traceback boom", "2026-01-01T00:00:02")
        match ledger.backfill_company(db, log, cid) {
          Err(e) => Err(e),
          Ok(_) => {
            let opens := ledger.open_incidents_for(db, cid)
            if list.len(opens) == 1 {
              if list.len(ledger.incidents_for(db, cid)) == 2 {
                Ok(())
              } else {
                Err("expected both episodes to still exist (one resolved, one open), not deleted")
              }
            } else {
              Err(str.concat("expected exactly 1 open incident after backfill, got ", int.to_str(list.len(opens))))
            }
          },
        }
      },
    },
  }
}

fn test_replay_orders_full_chain() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => match tlog.open_memory() {
      Err(e) => Err(e),
      Ok(log) => {
        let cid := fresh_company("replay")
        let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
        let __2 := seed_signal(db, cid, 2, "liveness", "up (launch: http://x)", "2026-01-01T00:00:09")
        match ledger.backfill_company(db, log, cid) {
          Err(e) => Err(e),
          Ok(_) => match list.head(ledger.incidents_for(db, cid)) {
            None => Err("no incident found"),
            Some(inc) => match ledger.record_evidence(db, inc, "docker logs", 0, "r1", "2026-01-01T00:00:02") {
              Err(e) => Err(str.concat("evidence: ", e)),
              Ok(_) => match ledger.record_action(db, inc, cid, "restart", "server", "{}", "auto", "2026-01-01T00:00:03") {
                Err(e) => Err(e),
                Ok(act) => match ledger.record_effect(db, act, inc, "liveness_latency_ms", "below", 5000000, "2026-01-01T00:00:03", "2026-01-01T00:00:07", 80, "escalate") {
                  Err(e) => Err(e),
                  Ok(eff) => match ledger.record_disposition(db, eff, "materialised", "2026-01-01T00:00:08") {
                    Err(e) => Err(e),
                    Ok(_) => check_replay_order(ledger.replay(db, inc)),
                  },
                },
              },
            },
          },
        }
      },
    },
  }
}

fn kinds_of(rows :: List[ledger.ReplayRow]) -> List[Str] {
  list.map(rows, fn (r :: ledger.ReplayRow) -> Str {
    r.kind
  })
}

fn check_replay_order(rows :: List[ledger.ReplayRow]) -> Result[Unit, Str] {
  let kinds := kinds_of(rows)
  if list.len(rows) == 7 {
    match list.head(kinds) {
      Some("incident.opened") => match list.head(list.reverse(kinds)) {
        Some("incident.closed") => Ok(()),
        _ => Err("replay does not end with incident.closed"),
      },
      _ => Err("replay does not start with incident.opened"),
    }
  } else {
    Err(str.concat("replay row count != 7, got ", int.to_str(list.len(rows))))
  }
}

fn test_budget_refuses_overrun() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("budget")
      match ledger.open_incident(db, cid, "liveness", "2026-01-01T00:00:01", "[\"liveness\"]", 1000) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.record_evidence(db, inc, "probe", 800, "r1", "2026-01-01T00:00:02") {
          Err(e) => Err(str.concat("first spend should pass: ", e)),
          Ok(_) => match ledger.record_evidence(db, inc, "probe2", 300, "r2", "2026-01-01T00:00:03") {
            Err(_) => Ok(()),
            Ok(_) => Err("budget overrun was allowed"),
          },
        },
      }
    },
  }
}

fn test_disposition_vocabulary_is_closed() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("dispo")
      let class_key := str.concat("restart-", cid)
      match ledger.open_incident(db, cid, "liveness", "2026-01-01T00:00:01", "[\"liveness\"]", 0) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.record_action(db, inc, cid, class_key, "server", "{}", "auto", "2026-01-01T00:00:02") {
          Err(e) => Err(e),
          Ok(act) => match ledger.record_effect(db, act, inc, "liveness_latency_ms", "below", 5000000, "2026-01-01T00:00:02", "2026-01-01T00:00:05", 80, "escalate") {
            Err(e) => Err(e),
            Ok(eff) => match ledger.record_disposition(db, eff, "looks-fine", "2026-01-01T00:00:06") {
              Err(_) => match ledger.record_disposition(db, eff, "ambiguous", "2026-01-01T00:00:06") {
                Err(e) => Err(e),
                Ok(_) => if ledger.class_hit_rate_pct(db, cid, class_key) == 0 {
                  Ok(())
                } else {
                  Err("ambiguous disposition inflated the hit rate")
                },
              },
              Ok(_) => Err("free-form disposition was accepted"),
            },
          },
        },
      }
    },
  }
}

fn test_effect_id_matches_content() -> Result[Unit, Str] {
  let a := ledger.effect_id("a1", "p99_ms", "below", 400000, "2026-01-01T00:04:00", 80, "rollback")
  let b := ledger.effect_id("a1", "p99_ms", "below", 400000, "2026-01-01T00:04:00", 80, "rollback")
  let c := ledger.effect_id("a1", "p99_ms", "below", 500000, "2026-01-01T00:04:00", 80, "rollback")
  if a == b and a != c {
    Ok(())
  } else {
    Err("effect id is not content-addressed")
  }
}

# ── CTL7 (#118/#125): controller metrics rollup ─────────────────────────────
fn seed_closed_incident(db :: conn.ConnDb, cid :: Str, tag :: Str, status :: Str, disposition :: Str, evidence_milli :: Int, at :: Str) -> [sql] Result[Unit, Str] {
  match ledger.open_incident(db, cid, "liveness", str.concat(at, tag), "[\"liveness\"]", 100000) {
    Err(e) => Err(e),
    Ok(inc) => match ledger.record_evidence(db, inc, "probe", evidence_milli, "", at) {
      Err(e) => Err(e),
      Ok(_) => match ledger.record_action(db, inc, cid, "restart", cid, "{}", "auto", at) {
        Err(e) => Err(e),
        Ok(act_id) => match ledger.record_effect(db, act_id, inc, "liveness", "below", 1000, at, at, 90, "rollback") {
          Err(e) => Err(e),
          Ok(eff_id) => match ledger.record_disposition(db, eff_id, disposition, at) {
            Err(e) => Err(e),
            Ok(_) => ledger.close_incident(db, inc, status, at, ""),
          },
        },
      },
    },
  }
}

fn check_operate_metrics(m :: ledger.OperateMetrics) -> Result[Unit, Str] {
  if m.open_incidents != 1 {
    Err(str.concat("wrong open count: ", int.to_str(m.open_incidents)))
  } else {
    if m.resolved_count != 1 {
      Err(str.concat("wrong resolved count: ", int.to_str(m.resolved_count)))
    } else {
      if m.escalated_count != 1 {
        Err(str.concat("wrong escalated count: ", int.to_str(m.escalated_count)))
      } else {
        if m.verified_effects != 2 {
          Err(str.concat("wrong verified count: ", int.to_str(m.verified_effects)))
        } else {
          if m.hit_rate_pct != 50 {
            Err(str.concat("wrong hit rate: ", int.to_str(m.hit_rate_pct)))
          } else {
            if m.avg_evidence_cost_milli != 400 {
              Err(str.concat("wrong avg evidence cost: ", int.to_str(m.avg_evidence_cost_milli)))
            } else {
              Ok(())
            }
          }
        }
      }
    }
  }
}

# One resolved incident (materialised, cost 500), one escalated incident
# (falsified, cost 300), one still-open incident with no effect yet —
# operate_metrics must fold all three into the right shape.
fn test_operate_metrics_aggregates_incidents_and_effects() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("metrics")
      let t := time.now_str()
      match seed_closed_incident(db, cid, "-r", "resolved", "materialised", 500, t) {
        Err(e) => Err(e),
        Ok(_) => match seed_closed_incident(db, cid, "-e", "escalated", "falsified", 300, t) {
          Err(e) => Err(e),
          Ok(_) => match ledger.open_incident(db, cid, "liveness", str.concat(t, "-open"), "[\"liveness\"]", 100000) {
            Err(e) => Err(e),
            Ok(_) => check_operate_metrics(ledger.operate_metrics(db, cid)),
          },
        },
      }
    },
  }
}

fn test_operate_metrics_empty_for_untouched_company() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let m := ledger.operate_metrics(db, fresh_company("untouched"))
      if m.open_incidents == 0 and m.resolved_count == 0 and m.escalated_count == 0 and m.verified_effects == 0 and m.avg_evidence_cost_milli == 0 {
        Ok(())
      } else {
        Err("expected all-zero metrics for a company with no operate history")
      }
    },
  }
}

# #138: hit_rate_trend_str's own examples{} prove the pure comparison,
# but nothing exercised company_hit_window's actual SQL windowing — an
# off-by-one in its LIMIT/OFFSET or a wrong ORDER BY direction would
# have gone undetected. Fixed literal, minute-apart timestamps (not
# time.now_str()) so the two windows partition deterministically: an
# all-falsified older window (0%) and an all-materialised recent one
# (100%) must read as "improving".
fn seed_disposition_at(db :: conn.ConnDb, cid :: Str, disposition :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  match ledger.open_incident(db, cid, "liveness", str.concat(at, "-trend"), "[\"liveness\"]", 0) {
    Err(e) => Err(e),
    Ok(inc) => match ledger.record_action(db, inc, cid, "restart", cid, "{}", "auto", at) {
      Err(e) => Err(e),
      Ok(act) => match ledger.record_effect(db, act, inc, "liveness", "below", 1000, at, at, 90, "rollback") {
        Err(e) => Err(e),
        Ok(eff) => ledger.record_disposition(db, eff, disposition, at),
      },
    },
  }
}

fn seed_disposition_list(db :: conn.ConnDb, cid :: Str, disposition :: Str, times :: List[Str]) -> [sql] Result[Unit, Str] {
  match list.head(times) {
    None => Ok(()),
    Some(t) => match seed_disposition_at(db, cid, disposition, t) {
      Err(e) => Err(e),
      Ok(_) => seed_disposition_list(db, cid, disposition, list.tail(times)),
    },
  }
}

fn test_company_hit_rate_trend_reflects_actual_windowing() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("trend")
      let older_times := ["2026-03-01T00:00:01", "2026-03-01T00:00:02", "2026-03-01T00:00:03", "2026-03-01T00:00:04", "2026-03-01T00:00:05", "2026-03-01T00:00:06", "2026-03-01T00:00:07", "2026-03-01T00:00:08", "2026-03-01T00:00:09", "2026-03-01T00:00:10"]
      let recent_times := ["2026-03-01T00:01:01", "2026-03-01T00:01:02", "2026-03-01T00:01:03", "2026-03-01T00:01:04", "2026-03-01T00:01:05", "2026-03-01T00:01:06", "2026-03-01T00:01:07", "2026-03-01T00:01:08", "2026-03-01T00:01:09", "2026-03-01T00:01:10"]
      match seed_disposition_list(db, cid, "falsified", older_times) {
        Err(e) => Err(e),
        Ok(_) => match seed_disposition_list(db, cid, "materialised", recent_times) {
          Err(e) => Err(e),
          Ok(_) => {
            let trend := ledger.company_hit_rate_trend(db, cid)
            if trend == "improving (0% -> 100%)" {
              Ok(())
            } else {
              Err(str.concat("expected 'improving (0% -> 100%)', got ", trend))
            }
          },
        },
      }
    },
  }
}

# tier_state has no prior row for a fresh (company, class) pair, set_tier_state
# upserts it, and a second set_tier_state with a different tier overwrites
# rather than duplicating — the ON CONFLICT DO UPDATE the transition
# detector in actuation.lex relies on to tell a real move from a
# steady-state read.
fn test_tier_state_roundtrips() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("tierstate")
      match ledger.tier_state(db, cid, "restart") {
        Some(t) => Err(str.concat("expected no prior state, got ", t)),
        None => match ledger.set_tier_state(db, cid, "restart", "propose", "2026-01-01T00:00:01") {
          Err(e) => Err(e),
          Ok(_) => match ledger.tier_state(db, cid, "restart") {
            None => Err("expected a state after set_tier_state"),
            Some(t1) => if t1 != "propose" {
              Err(str.concat("expected 'propose', got ", t1))
            } else {
              match ledger.set_tier_state(db, cid, "restart", "auto", "2026-01-01T00:00:02") {
                Err(e) => Err(e),
                Ok(_) => match ledger.tier_state(db, cid, "restart") {
                  None => Err("expected a state after the second set_tier_state"),
                  Some(t2) => if t2 == "auto" {
                    Ok(())
                  } else {
                    Err(str.concat("expected upsert to overwrite to 'auto', got ", t2))
                  },
                },
              }
            },
          },
        },
      }
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_backfill_groups_episode(), test_backfill_idempotent(), test_backfill_merges_concurrent_open_incidents(), test_replay_orders_full_chain(), test_budget_refuses_overrun(), test_disposition_vocabulary_is_closed(), test_effect_id_matches_content(), test_operate_metrics_aggregates_incidents_and_effects(), test_operate_metrics_empty_for_untouched_company(), test_company_hit_rate_trend_reflects_actual_windowing(), test_tier_state_roundtrips()]
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

