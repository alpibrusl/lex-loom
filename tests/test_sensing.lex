# tests — sensing layer (#118/#121, CTL3): recall vs the binary check,
# degraded-but-responding detection, firing collapse, warmup, hysteresis
# resolution, and the condensed Strategist operate view.
#
# Uses time-suffixed company ids (see test_operate_ledger.lex for why).

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

import "../src/migrate" as migrate

import "../src/operate_ledger" as ledger

import "../src/sensing" as sensing

import "../src/company" as company

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
  str.join(["senstest-", tag, "-", time.now_str()], "")
}

fn seed_signal(db :: conn.ConnDb, company_id :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql] Result[Unit, Str] {
  let id := str.join([company_id, "-", kind, "-", int.to_str(idx), "-", at], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO company_operate_signals (id, company_id, idx, kind, value, observed_at, incident_id, score_milli) VALUES (?, ?, ?, ?, ?, ?, '', 0)", params: [PStr(id), PStr(company_id), PInt(idx), PStr(kind), PStr(value), PStr(at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# One sensing round: seed a reading, then run sense_company — the same
# shape as the live between-iteration hook.
fn round(db :: conn.ConnDb, cid :: Str, idx :: Int, kind :: Str, value :: Str, at :: Str) -> [sql, time] Result[Int, Str] {
  match seed_signal(db, cid, idx, kind, value, at) {
    Err(e) => Err(str.concat("seed: ", e)),
    Ok(_) => sensing.sense_company(db, None, cid, sensing.default_policy()),
  }
}

fn open_incident_count(db :: conn.ConnDb, cid :: Str) -> [sql] Int {
  list.len(list.fold(ledger.recent_incidents(db, cid, 10), [], fn (acc :: List[Str], i :: ledger.IncidentRow) -> List[Str] {
    if str.is_empty(i.closed_at) {
      list.concat(acc, [i.id])
    } else {
      acc
    }
  }))
}

# A "down" reading fires on the first round, history or not — recall can
# never be below the v0 binary check.
fn test_down_always_fires() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("down")
      match round(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01") {
        Err(e) => Err(e),
        Ok(fired) => if fired == 1 and list.len(ledger.incidents_for(db, cid)) == 1 {
          Ok(())
        } else {
          Err("down reading did not open an incident")
        },
      }
    },
  }
}

# The acceptance case the binary check is structurally blind to: the
# server answers every probe ("up" throughout) but latency explodes.
# The residual fires; an incident opens with zero "down" readings.
fn test_degraded_but_responding_fires() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("degraded")
      let __1 := round(db, cid, 1, "latency_ms", "100", "2026-01-01T00:00:01")
      let __2 := round(db, cid, 2, "latency_ms", "110", "2026-01-01T00:00:02")
      let __3 := round(db, cid, 3, "latency_ms", "95", "2026-01-01T00:00:03")
      let __4 := round(db, cid, 4, "latency_ms", "105", "2026-01-01T00:00:04")
      if list.len(ledger.incidents_for(db, cid)) == 0 {
        match round(db, cid, 5, "latency_ms", "5000", "2026-01-01T00:00:05") {
          Err(e) => Err(e),
          Ok(fired) => if fired == 1 and list.len(ledger.incidents_for(db, cid)) == 1 {
            Ok(())
          } else {
            Err("latency spike on an up server did not fire")
          },
        }
      } else {
        Err("stable latency opened an incident during warmup")
      }
    },
  }
}

# While an incident is open, further firings attach to it — one episode,
# not one incident per noisy series.
fn test_firings_collapse_into_open_incident() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("collapse")
      let __1 := round(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
      match round(db, cid, 2, "errors", "Traceback (most recent call last)", "2026-01-01T00:00:02") {
        Err(e) => Err(e),
        Ok(_) => if list.len(ledger.incidents_for(db, cid)) == 1 {
          Ok(())
        } else {
          Err("second firing opened a second incident")
        },
      }
    },
  }
}

# Warmup readings carry no baseline and must not fire on level alone.
fn test_warmup_does_not_fire() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("warmup")
      let __1 := round(db, cid, 1, "latency_ms", "100", "2026-01-01T00:00:01")
      match round(db, cid, 2, "latency_ms", "9000", "2026-01-01T00:00:02") {
        Err(e) => Err(e),
        Ok(_) => if list.len(ledger.incidents_for(db, cid)) == 0 {
          Ok(())
        } else {
          Err("fired during warmup with no baseline")
        },
      }
    },
  }
}

# After the series recovers below the exit bar, the open incident
# resolves on a quiet round (asymmetric enter/exit).
fn test_calm_round_resolves_incident() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("resolve")
      let __1 := round(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
      if open_incident_count(db, cid) == 1 {
        match round(db, cid, 2, "liveness", "up (launch: http://x)", "2026-01-01T00:00:02") {
          Err(e) => Err(e),
          Ok(_) => if open_incident_count(db, cid) == 0 and list.len(ledger.incidents_for(db, cid)) == 1 {
            Ok(())
          } else {
            Err("recovered series did not resolve the open incident")
          },
        }
      } else {
        Err("down reading did not open an incident")
      }
    },
  }
}

# The Strategist view shows grouped incidents + the latest reading, not
# the raw check history — volume down, live problems more visible.
fn test_operate_section_shows_incidents_not_raw_history() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := fresh_company("section")
      let __1 := round(db, cid, 1, "liveness", "down (launch: http://x)", "2026-01-01T00:00:01")
      let __2 := round(db, cid, 2, "liveness", "down (launch: http://x)", "2026-01-01T00:00:02")
      let __3 := round(db, cid, 3, "liveness", "down (launch: http://x)", "2026-01-01T00:00:03")
      let section := company.operate_section(db, cid)
      if str.contains(section, "Incidents (operate ledger") {
        if str.contains(section, "2026-01-01T00:00:01") and not str.contains(section, "2026-01-01T00:00:02: down") {
          Ok(())
        } else {
          Err(str.concat("expected latest reading + incident summary, got: ", section))
        }
      } else {
        Err(str.concat("expected incident summary in operate_section, got: ", section))
      }
    },
  }
}

fn run_all() -> [sql, fs_write, concurrent, crypto, fs_read, io, net, random, time] Unit {
  let results := [test_down_always_fires(), test_degraded_but_responding_fires(), test_firings_collapse_into_open_incident(), test_warmup_does_not_fire(), test_calm_round_resolves_incident(), test_operate_section_shows_incidents_not_raw_history()]
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

