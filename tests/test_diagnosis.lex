# tests — shadow diagnosis (#118/#122, CTL4): correct verdicts on the two
# canonical episode shapes, budget-exhaustion sensing gap, corpus scoring,
# calibration accounting, and trail/evidence reconstructability.
#
# Uses time-suffixed company ids (see test_operate_ledger.lex for why);
# scoring assertions are delta-based so a persistent local store cannot
# skew them.

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
  str.join(["diagtest-", tag, "-", time.now_str()], "")
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

# Build the canonical down-down-up outage episode and return its id.
fn build_down_episode(db :: conn.ConnDb, cid :: Str) -> [sql, fs_write, time] Result[Str, Str] {
  match tlog.open_memory() {
    Err(e) => Err(e),
    Ok(log) => {
      let __1 := seed_signal(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
      let __2 := seed_signal(db, cid, 2, "liveness", "down (launch: http://x)", "2026-01-01T00:00:02")
      let __3 := seed_signal(db, cid, 3, "liveness", "up (launch: http://x)", "2026-01-01T00:00:03")
      match ledger.backfill_company(db, log, cid) {
        Err(e) => Err(e),
        Ok(_) => match list.head(ledger.incidents_for(db, cid)) {
          None => Err("no incident from backfill"),
          Some(inc) => Ok(inc),
        },
      }
    },
  }
}

# An outage episode (hard downs, sustained) diagnoses as server_down,
# confidently, within budget — and every probe is an evidence row.
fn test_outage_diagnosed_server_down() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("outage")
      match build_down_episode(db, cid) {
        Err(e) => Err(e),
        Ok(inc) => match diag.diagnose(db, None, inc, 60, 1000, "2026-01-02T00:00:00") {
          Err(e) => Err(str.concat("diagnose: ", e)),
          Ok(d) => if d.cause == "server_down" and d.p_pct >= 60 and not d.gap {
            let ev := list.fold(ledger.replay(db, inc), 0, fn (n :: Int, r :: ledger.ReplayRow) -> Int {
              if r.kind == "evidence" {
                n + 1
              } else {
                n
              }
            })
            if ev >= 2 {
              Ok(())
            } else {
              Err("diagnosis left no evidence rows to reconstruct from")
            }
          } else {
            Err(str.join(["expected confident server_down, got ", d.cause, " p=", int.to_str(d.p_pct)], ""))
          },
        },
      }
    },
  }
}

# A latency-spike-on-an-up-server episode (the degraded case sensing
# caught in CTL3) diagnoses as degraded_latency.
fn test_degraded_episode_diagnosed() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("degraded")
      let __1 := round(db, cid, 1, "latency_ms", "100", "2026-01-01T00:00:01")
      let __2 := round(db, cid, 2, "latency_ms", "110", "2026-01-01T00:00:02")
      let __3 := round(db, cid, 3, "latency_ms", "95", "2026-01-01T00:00:03")
      let __4 := round(db, cid, 4, "latency_ms", "105", "2026-01-01T00:00:04")
      let __5 := round(db, cid, 5, "latency_ms", "5000", "2026-01-01T00:00:05")
      match list.head(ledger.incidents_for(db, cid)) {
        None => Err("latency spike did not open an incident"),
        Some(inc) => match diag.diagnose(db, None, inc, 60, 1000, "2026-01-02T00:00:00") {
          Err(e) => Err(e),
          Ok(d) => if d.cause == "degraded_latency" and d.p_pct >= 60 and not d.gap {
            Ok(())
          } else {
            Err(str.join(["expected degraded_latency, got ", d.cause, " p=", int.to_str(d.p_pct)], ""))
          },
        },
      }
    },
  }
}

# A budget too small for the tool ladder ends as a sensing gap, recorded
# as such — not silently, and not as a made-up confident verdict.
fn test_budget_exhaustion_is_a_sensing_gap() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("gap")
      match build_down_episode(db, cid) {
        Err(e) => Err(e),
        Ok(inc) => match diag.diagnose(db, None, inc, 99, 150, "2026-01-02T00:00:00") {
          Err(e) => Err(e),
          Ok(d) => if d.gap {
            Ok(())
          } else {
            Err("exhausted budget did not record a sensing gap")
          },
        },
      }
    },
  }
}

# Corpus scoring and calibration move by exactly the labeled episodes we
# add, and the calibration bins account for every labeled row.
fn test_scoring_and_calibration() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let before := diag.score_corpus(db)
      let cid := fresh_company("score")
      match build_down_episode(db, cid) {
        Err(e) => Err(e),
        Ok(inc) => match ledger.label_root_cause(db, inc, "server_down") {
          Err(e) => Err(e),
          Ok(_) => match diag.diagnose(db, None, inc, 60, 1000, "2026-01-02T00:00:00") {
            Err(e) => Err(e),
            Ok(_) => {
              let after := diag.score_corpus(db)
              if after.labeled == before.labeled + 1 and after.correct == before.correct + 1 {
                let bins := diag.calibration(db)
                let binned := list.fold(bins, 0, fn (n :: Int, b :: diag.CalBin) -> Int {
                  n + b.n
                })
                if binned == after.labeled {
                  Ok(())
                } else {
                  Err("calibration bins do not account for every labeled row")
                }
              } else {
                Err("labeled/correct did not advance by the new episode")
              }
            },
          },
        },
      }
    },
  }
}

# diagnose_all sweeps whatever is undiagnosed and is idempotent.
fn test_diagnose_all_sweeps_once() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("sweep")
      match build_down_episode(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match diag.diagnose_all(db, None, 60, 1000, "2026-01-02T00:00:00") {
          Err(e) => Err(e),
          Ok(n1) => match diag.diagnose_all(db, None, 60, 1000, "2026-01-02T00:00:01") {
            Err(e) => Err(e),
            Ok(n2) => if n1 >= 1 and n2 == 0 {
              Ok(())
            } else {
              Err(str.join(["expected one-pass sweep, got ", int.to_str(n1), " then ", int.to_str(n2)], ""))
            },
          },
        },
      }
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_outage_diagnosed_server_down(), test_degraded_episode_diagnosed(), test_budget_exhaustion_is_a_sensing_gap(), test_scoring_and_calibration(), test_diagnose_all_sweeps_once()]
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

