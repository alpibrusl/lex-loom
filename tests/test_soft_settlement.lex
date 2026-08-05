# tests/test_soft_settlement.lex — SA3 (lex-loom#180): unit tests for
# soft_settlement.lex's record/verify pipeline.
#
# This is the promotion criterion's own mechanism under test: "a settlement
# event soft produced is the one board_report cites, and it survives an
# independent re-verification (soft's own evidence re-derivation)." The
# live, reachable-REVENUE_URL happy path through check_and_record_revenue
# is proved separately (demo/sa3-settlement-roundtrip.sh, PR description) —
# env vars are process-global and lex test runs every file in one process,
# so REVENUE_URL can't be scoped to a single test without risking leakage
# into others; everything provably deterministic without touching env is
# unit-tested here instead, same discipline as test_cx_tool.lex.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-soft/src/settlement" as settlement

import "../src/migrate" as migrate

import "../src/soft_settlement" as ss

import "../src/company" as company

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn get_int(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => -1,
  }
}

fn get_bool(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

# ── record + verify round trip ─────────────────────────────────────────────────
fn test_honest_claim_verifies() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let log := settlement.trail_on(db)
        match ss.record_revenue_claim(log, "acme", 3400, "revenue_url") {
          Err(e) => Err(str.concat("record failed: ", e)),
          Ok(tid) => {
            let v := ss.verify_revenue_claim(log, tid)
            if v.verified and v.intact and v.linked and v.legal {
              Ok(())
            } else {
              Err(str.concat("honest non-negative claim should fully verify, reason=", v.reason))
            }
          },
        }
      },
    },
  }
}

fn test_negative_claim_is_illegal() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let log := settlement.trail_on(db)
        match ss.record_revenue_claim(log, "acme", 0 - 500, "revenue_url") {
          Err(e) => Err(str.concat("record failed: ", e)),
          Ok(tid) => {
            let v := ss.verify_revenue_claim(log, tid)
            if v.intact and v.linked and not v.legal and not v.verified {
              Ok(())
            } else {
              Err(str.concat("a negative revenue claim should be legal:false -> verified:false, reason=", v.reason))
            }
          },
        }
      },
    },
  }
}

fn test_tampered_trail_fails_re_verification() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => {
        let log := settlement.trail_on(db)
        match ss.record_revenue_claim(log, "acme", 3400, "revenue_url") {
          Err(e) => Err(str.concat("record failed: ", e)),
          Ok(tid) => {
            let __m := sql.exec(db, str.concat("UPDATE events SET payload_json='{\"revenue_cents\":3400,\"x\":1}' WHERE id='", str.concat(tid, "'")), [])
            let v := ss.verify_revenue_claim(log, tid)
            if not v.intact and not v.verified {
              Ok(())
            } else {
              Err("a tampered settlement trail must report intact:false -> verified:false on re-derivation")
            }
          },
        }
      },
    },
  }
}

# ── settle_revenue orchestration ────────────────────────────────────────────────
fn conn_open() -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(":memory:") {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn test_settle_revenue_returns_trail_id_and_verified_verdict() -> [sql, fs_write, time] Result[Unit, Str] {
  match conn_open() {
    Err(e) => Err(e),
    Ok(db) => match ss.settle_revenue(db, "acme", 1200, "revenue_url") {
      Err(e) => Err(str.concat("settle_revenue failed: ", e)),
      Ok(settled) => if str.is_empty(settled.trail_id) {
        Err("expected a non-empty trail_id")
      } else {
        if settled.verdict.verified {
          Ok(())
        } else {
          Err(str.concat("expected the settled claim to verify, reason=", settled.verdict.reason))
        }
      },
    },
  }
}

fn test_settled_signal_json_round_trips() -> [sql, fs_write, time] Result[Unit, Str] {
  match conn_open() {
    Err(e) => Err(e),
    Ok(db) => match ss.settle_revenue(db, "acme", 5600, "revenue_url") {
      Err(e) => Err(e),
      Ok(settled) => {
        let body := ss.settled_signal_json(settled, 5600)
        match jv.parse(body) {
          Err(_) => Err(str.concat("settled_signal_json did not produce valid JSON: ", body)),
          Ok(j) => if get_int(j, "revenue_cents") == 5600 {
            if get_str(j, "trail_id") == settled.trail_id {
              if get_bool(j, "verified") {
                Ok(())
              } else {
                Err(str.concat("expected verified:true in the signal JSON: ", body))
              }
            } else {
              Err(str.concat("trail_id mismatch in signal JSON: ", body))
            }
          } else {
            Err(str.concat("revenue_cents mismatch in signal JSON: ", body))
          },
        }
      },
    },
  }
}

# ── company.lex's supporting pure helpers ───────────────────────────────────────
fn test_parse_revenue_cents_unreachable_is_none() -> Result[Unit, Str] {
  match company.parse_revenue_cents("(unreachable)") {
    None => Ok(()),
    Some(_) => Err("expected None for an unreachable reading"),
  }
}

fn test_parse_revenue_cents_malformed_is_none() -> Result[Unit, Str] {
  match company.parse_revenue_cents("not json") {
    None => Ok(()),
    Some(_) => Err("expected None for malformed JSON"),
  }
}

fn test_parse_revenue_cents_valid_is_some() -> Result[Unit, Str] {
  match company.parse_revenue_cents("{\"revenue_cents\": 4200}") {
    Some(4200) => Ok(()),
    Some(n) => Err(str.concat("unexpected parsed value: ", int.to_str(n))),
    None => Err("expected Some(4200) for a valid reading"),
  }
}

fn test_settlement_citation_shows_trail_id_when_present() -> Result[Unit, Str] {
  let cite := company.settlement_citation("{\"revenue_cents\":3400,\"trail_id\":\"abc123\",\"verified\":true}")
  if str.contains(cite, "abc123") {
    if str.contains(cite, "verified") {
      Ok(())
    } else {
      Err(str.concat("expected the citation to say verified: ", cite))
    }
  } else {
    Err(str.concat("expected the citation to include the trail_id: ", cite))
  }
}

fn test_settlement_citation_empty_when_no_trail_id() -> Result[Unit, Str] {
  let cite := company.settlement_citation("{\"revenue_cents\":3400}")
  if str.is_empty(cite) {
    Ok(())
  } else {
    Err(str.concat("expected an empty citation for a reading with no trail_id: ", cite))
  }
}

fn suite() -> [sql, fs_read, fs_write, time] List[Result[Unit, Str]] {
  [test_honest_claim_verifies(), test_negative_claim_is_illegal(), test_tampered_trail_fails_re_verification(), test_settle_revenue_returns_trail_id_and_verified_verdict(), test_settled_signal_json_round_trips(), test_parse_revenue_cents_unreachable_is_none(), test_parse_revenue_cents_malformed_is_none(), test_parse_revenue_cents_valid_is_some(), test_settlement_citation_shows_trail_id_when_present(), test_settlement_citation_empty_when_no_trail_id()]
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := suite()
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

