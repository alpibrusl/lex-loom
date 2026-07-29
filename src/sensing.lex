# sensing.lex — residuals, not thresholds (#118/#121, CTL3).
#
# Phase 1 of the Operate loop v1: each numeric signal series gets a cheap
# baseline (EWMA mean + EWMA absolute deviation, integer math throughout),
# and what fires is the STANDARDISED RESIDUAL against that baseline in
# milli-units — one comparable currency across heterogeneous signals —
# never the raw level. Binary unhealthy readings (liveness "down", a
# non-clean error scan) hard-fire at the maximum score, so recall can
# never be worse than the v0 threshold check by construction.
#
# Firings collapse per company: while a company has an open incident,
# further firings attach to it instead of opening new ones — one episode,
# not N wake-ups. When a round produces no firing and every series is
# back below the exit threshold (asymmetric: exit < enter), the open
# incident resolves. No agent, no actions — this layer only observes,
# scores, groups and records.
#
# The one hard threshold that remains in loom is the spend-cap safety
# interlock (`STOP_WHEN` / `[policy].budget_eur`), which bypasses this
# controller entirely by design.
#
# Numeric convention (matches lex-ctl): scores in integer milli-units
# (3000 = 3 deviations from baseline).

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

import "./operate_ledger" as ledger

# ── Policy ────────────────────────────────────────────────────────────────────
type Policy = { enter_milli :: Int, exit_milli :: Int, warmup :: Int, alpha_num :: Int, alpha_den :: Int, budget_cap_milli :: Int }

# Enter at 3 deviations, exit below 1 (asymmetric by construction);
# 3 readings of warmup before a residual can fire; EWMA alpha 3/10;
# evidence budget granted to incidents this layer opens.
fn default_policy() -> Policy
  examples {
    default_policy() => { enter_milli: 3000, exit_milli: 1000, warmup: 3, alpha_num: 3, alpha_den: 10, budget_cap_milli: 100000 }
  }
{
  { enter_milli: 3000, exit_milli: 1000, warmup: 3, alpha_num: 3, alpha_den: 10, budget_cap_milli: 100000 }
}

fn absi(x :: Int) -> Int
  examples {
    absi(5) => 5,
    absi(-5) => 5,
    absi(0) => 0
  }
{
  if x < 0 {
    0 - x
  } else {
    x
  }
}

# ── Baseline: EWMA mean + EWMA absolute deviation ────────────────────────────
type Baseline = { mean :: Int, dev :: Int, n :: Int }

fn seed_baseline() -> Baseline
  examples {
    seed_baseline() => { mean: 0, dev: 0, n: 0 }
  }
{
  { mean: 0, dev: 0, n: 0 }
}

fn update_baseline(b :: Baseline, x :: Int, p :: Policy) -> Baseline
  examples {
    update_baseline(seed_baseline(), 100, default_policy()) => { mean: 100, dev: 0, n: 1 },
    update_baseline({ mean: 100, dev: 0, n: 1 }, 100, default_policy()) => { mean: 100, dev: 0, n: 2 }
  }
{
  if b.n == 0 {
    { mean: x, dev: 0, n: 1 }
  } else {
    let keep := p.alpha_den - p.alpha_num
    { mean: (keep * b.mean + p.alpha_num * x) / p.alpha_den, dev: (keep * b.dev + p.alpha_num * absi(x - b.mean)) / p.alpha_den, n: b.n + 1 }
  }
}

fn fold_baseline(values :: List[Int], p :: Policy) -> Baseline
  examples {
    fold_baseline([], default_policy()) => { mean: 0, dev: 0, n: 0 },
    fold_baseline([100, 100, 100], default_policy()) => { mean: 100, dev: 0, n: 3 }
  }
{
  list.fold(values, seed_baseline(), fn (b :: Baseline, x :: Int) -> Baseline {
    update_baseline(b, x, p)
  })
}

# Signed standardised residual in milli-units. The deviation is floored
# at 1% of |mean| (min 1) so a perfectly flat history still yields a
# finite, comparable score instead of a division blow-up.
fn residual_milli(b :: Baseline, x :: Int) -> Int
  examples {
    residual_milli({ mean: 100, dev: 10, n: 5 }, 100) => 0,
    residual_milli({ mean: 100, dev: 10, n: 5 }, 130) => 3000,
    residual_milli({ mean: 100, dev: 10, n: 5 }, 70) => -3000
  }
{
  let floor := if absi(b.mean) / 100 > 1 {
    absi(b.mean) / 100
  } else {
    1
  }
  let d := if b.dev > floor {
    b.dev
  } else {
    floor
  }
  (x - b.mean) * 1000 / d
}

fn hard_fire_milli() -> Int
  examples {
    hard_fire_milli() => 10000
  }
{
  10000
}

# Score one reading given its numeric history (chronological, excluding
# the reading itself). Warmup readings score 0 — no baseline, no opinion.
fn score_value(history :: List[Int], x :: Int, p :: Policy) -> Int
  examples {
    score_value([], 100, default_policy()) => 0,
    score_value([100], 100, default_policy()) => 0,
    score_value([100, 100, 100], 100, default_policy()) => 0,
    score_value([100, 110, 90, 105], 5000, default_policy()) => residual_milli(fold_baseline([100, 110, 90, 105], default_policy()), 5000)
  }
{
  let b := fold_baseline(history, p)
  if b.n < p.warmup {
    0
  } else {
    residual_milli(b, x)
  }
}

# Score any reading: an unhealthy binary reading (liveness "down", error
# scan with content) hard-fires regardless of history — this is what
# guarantees recall ≥ the v0 binary check. Healthy numeric readings get
# the residual; healthy non-numeric readings score 0.
fn score_reading(kind :: Str, value :: Str, history :: List[Int], p :: Policy) -> Int
  examples {
    score_reading("liveness", "down (launch: http://x)", [], default_policy()) => 10000,
    score_reading("liveness", "up (launch: http://x)", [], default_policy()) => 0,
    score_reading("errors", "Traceback (most recent call last)", [], default_policy()) => 10000,
    score_reading("latency_ms", "100", [100, 100, 100], default_policy()) => 0
  }
{
  if not ledger.is_healthy(kind, value) {
    hard_fire_milli()
  } else {
    match str.to_int(str.trim(value)) {
      None => 0,
      Some(x) => score_value(history, x, p),
    }
  }
}

fn fires(score_milli :: Int, p :: Policy) -> Bool
  examples {
    fires(3000, default_policy()) => true,
    fires(-3500, default_policy()) => true,
    fires(2999, default_policy()) => false
  }
{
  absi(score_milli) >= p.enter_milli
}

fn calm(score_milli :: Int, p :: Policy) -> Bool
  examples {
    calm(0, default_policy()) => true,
    calm(999, default_policy()) => true,
    calm(1000, default_policy()) => false,
    calm(2000, default_policy()) => false
  }
{
  absi(score_milli) < p.exit_milli
}

# ── Pipeline over the ledger ──────────────────────────────────────────────────
type SigRow = { id :: Str, value :: Str, observed_at :: Str }

type ValRow = { value :: Str }

type ScoreRow = { value :: Str, score_milli :: Int }

# Numeric history for a series, chronological, excluding the latest row.
fn numeric_history(db :: conn.ConnDb, company_id :: Str, kind :: Str, limit :: Int) -> [sql] List[Int] {
  let q := ormq.for_dialect({ sql: "SELECT value FROM company_operate_signals WHERE company_id=? AND kind=? ORDER BY idx DESC, observed_at DESC LIMIT ? OFFSET 1", params: [PStr(company_id), PStr(kind), PInt(limit)] }, db.dialect)
  let rows :: Result[List[ValRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(list.reverse(rs), [], fn (acc :: List[Int], r :: ValRow) -> List[Int] {
      match str.to_int(str.trim(r.value)) {
        None => acc,
        Some(x) => list.concat(acc, [x]),
      }
    }),
  }
}

fn latest_row(db :: conn.ConnDb, company_id :: Str, kind :: Str) -> [sql] Option[SigRow] {
  let q := ormq.for_dialect({ sql: "SELECT id, value, observed_at FROM company_operate_signals WHERE company_id=? AND kind=? ORDER BY idx DESC, observed_at DESC LIMIT 1", params: [PStr(company_id), PStr(kind)] }, db.dialect)
  let rows :: Result[List[SigRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn store_score(db :: conn.ConnDb, signal_row_id :: Str, score_milli :: Int) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE company_operate_signals SET score_milli=? WHERE id=?", params: [PInt(score_milli), PStr(signal_row_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type IdRow = { id :: Str }

# The company's currently-open incident, if any — the grouping key that
# collapses correlated firings into one episode.
fn open_incident_for(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_incidents WHERE company_id=? AND closed_at='' ORDER BY opened_at DESC LIMIT 1", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.id),
    },
  }
}

# Score the latest reading of one series, persist the score, and route a
# firing into the company's open incident (or open one). Returns the
# score. The trail log is optional until the runner carries one (CTL4
# wires it); when present, incident opens land on the trail.
fn sense_kind(db :: conn.ConnDb, log :: Option[tlog.Log], company_id :: Str, kind :: Str, p :: Policy) -> [sql, time] Result[Int, Str] {
  match latest_row(db, company_id, kind) {
    None => Ok(0),
    Some(row) => {
      let score := score_reading(kind, row.value, numeric_history(db, company_id, kind, 20), p)
      match store_score(db, row.id, score) {
        Err(e) => Err(e),
        Ok(_) => if fires(score, p) {
          match open_incident_for(db, company_id) {
            Some(inc) => match ledger.link_signal(db, row.id, inc) {
              Err(e) => Err(e),
              Ok(_) => Ok(score),
            },
            None => match ledger.open_incident(db, company_id, kind, row.observed_at, str.join(["[\"", kind, "\"]"], ""), p.budget_cap_milli) {
              Err(e) => Err(e),
              Ok(inc) => match ledger.link_signal(db, row.id, inc) {
                Err(e) => Err(e),
                Ok(_) => match log {
                  None => Ok(score),
                  Some(l) => match ledger.trail_incident_opened(l, inc, company_id, kind, None) {
                    Err(e) => Err(e),
                    Ok(_) => Ok(score),
                  },
                },
              },
            },
          }
        } else {
          Ok(score)
        },
      }
    },
  }
}

fn sensed_kinds() -> List[Str]
  examples {
    sensed_kinds() => ["liveness", "latency_ms", "errors", "error_count"]
  }
{
  ["liveness", "latency_ms", "errors", "error_count"]
}

fn sense_kinds(db :: conn.ConnDb, log :: Option[tlog.Log], company_id :: Str, kinds :: List[Str], p :: Policy, fired :: Int, last_at :: Str) -> [sql, time] Result[{ fired :: Int, last_at :: Str }, Str] {
  match list.head(kinds) {
    None => Ok({ fired: fired, last_at: last_at }),
    Some(kind) => {
      let at := match latest_row(db, company_id, kind) {
        None => last_at,
        Some(row) => if row.observed_at > last_at {
          row.observed_at
        } else {
          last_at
        },
      }
      match sense_kind(db, log, company_id, kind, p) {
        Err(e) => Err(e),
        Ok(score) => sense_kinds(db, log, company_id, list.tail(kinds), p, if fires(score, p) {
          fired + 1
        } else {
          fired
        }, at),
      }
    },
  }
}

# Are all series calm (healthy reading, |score| below the exit bar)?
fn all_calm(db :: conn.ConnDb, company_id :: Str, kinds :: List[Str], p :: Policy) -> [sql] Bool {
  match list.head(kinds) {
    None => true,
    Some(kind) => {
      let q := ormq.for_dialect({ sql: "SELECT value, score_milli FROM company_operate_signals WHERE company_id=? AND kind=? ORDER BY idx DESC, observed_at DESC LIMIT 1", params: [PStr(company_id), PStr(kind)] }, db.dialect)
      let rows :: Result[List[ScoreRow], SqlError] := sql.query(db.handle, q.sql, q.params)
      let this_calm := match rows {
        Err(_) => true,
        Ok(rs) => match list.head(rs) {
          None => true,
          Some(r) => ledger.is_healthy(kind, r.value) and calm(r.score_milli, p),
        },
      }
      if this_calm {
        all_calm(db, company_id, list.tail(kinds), p)
      } else {
        false
      }
    },
  }
}

# One sensing round for a company: score every series' latest reading,
# group firings into (at most) one open incident, and resolve the open
# incident once a round fires nothing and every series is back under the
# exit bar. Returns the number of series that fired.
fn sense_company(db :: conn.ConnDb, log :: Option[tlog.Log], company_id :: Str, p :: Policy) -> [sql, time] Result[Int, Str] {
  match sense_kinds(db, log, company_id, sensed_kinds(), p, 0, "") {
    Err(e) => Err(e),
    Ok(r) => if r.fired == 0 {
      match open_incident_for(db, company_id) {
        None => Ok(0),
        Some(inc) => if all_calm(db, company_id, sensed_kinds(), p) {
          match ledger.close_incident(db, inc, "resolved", r.last_at, "") {
            Err(e) => Err(e),
            Ok(_) => match log {
              None => Ok(0),
              Some(l) => match ledger.trail_incident_closed(l, inc, "resolved", None) {
                Err(e) => Err(e),
                Ok(_) => Ok(0),
              },
            },
          }
        } else {
          Ok(0)
        },
      }
    } else {
      Ok(r.fired)
    },
  }
}

