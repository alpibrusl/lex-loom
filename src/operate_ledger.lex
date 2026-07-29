# operate_ledger.lex — the controller's record (#118/#120, CTL2).
#
# Phase 0 of the Operate loop v1: the ledger every later phase is scored
# against. Five concerns:
#
#   - content-addressed row ids (SHA-256 over canonical fields) for
#     incidents, actions, effect contracts and evidence — the same
#     convention as lex-ctl and lex-trail, so the SQL projection and the
#     trail chain agree on identity
#   - recording functions over the operate_* tables (DDL in migrate.lex)
#   - lex-trail emits (loom.operate.* kinds) — the authoritative
#     tamper-evident record; the tables are the queryable projection,
#     same dual-write pattern as sprint traces vs loom_trail
#   - backfill: derive historical incident episodes from the raw
#     company_operate_signals history (#85), so the replay corpus exists
#     before any agent does (the design's phase-0 requirement)
#   - replay: reconstruct one incident's chain in time order
#
# Numeric convention (matches lex-ctl): signal scores/thresholds are
# integer milli-units; confidence is integer percent; evidence budget is
# integer milli-units of the host's cost currency.
#
# Timestamps are passed in by callers (ISO-8601 strings, as elsewhere in
# loom) — recording functions are [sql] only; trail emits add [time].

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

# ── Content-addressed ids ─────────────────────────────────────────────────────
fn incident_id(company_id :: Str, kind :: Str, opened_at :: Str) -> Str
  examples {
    incident_id("acme", "liveness", "2026-01-01T00:00:01") => incident_id("acme", "liveness", "2026-01-01T00:00:01")
  }
{
  crypto.sha256_str(str.join(["operate.incident", company_id, kind, opened_at], "|"))
}

fn action_id(incident :: Str, class_key :: Str, executed_at :: Str) -> Str
  examples {
    action_id("i1", "restart", "2026-01-01T00:00:02") => action_id("i1", "restart", "2026-01-01T00:00:02")
  }
{
  crypto.sha256_str(str.join(["operate.action", incident, class_key, executed_at], "|"))
}

# Mirrors lex-ctl contract.compute_id's field coverage: the same logical
# prediction hashes to the same id in the kernel and in this ledger.
fn effect_id(action :: Str, signal :: Str, cmp :: Str, threshold_milli :: Int, deadline_at :: Str, confidence_pct :: Int, on_falsify :: Str) -> Str
  examples {
    effect_id("a1", "p99_ms", "below", 400000, "2026-01-01T00:04:00", 80, "rollback") => effect_id("a1", "p99_ms", "below", 400000, "2026-01-01T00:04:00", 80, "rollback")
  }
{
  crypto.sha256_str(str.join(["operate.effect", action, signal, cmp, int.to_str(threshold_milli), deadline_at, int.to_str(confidence_pct), on_falsify], "|"))
}

fn evidence_id(incident :: Str, query_text :: Str, observed_at :: Str) -> Str
  examples {
    evidence_id("i1", "docker logs", "2026-01-01T00:00:03") => evidence_id("i1", "docker logs", "2026-01-01T00:00:03")
  }
{
  crypto.sha256_str(str.join(["operate.evidence", incident, query_text, observed_at], "|"))
}

# ── Recording ─────────────────────────────────────────────────────────────────
fn open_incident(db :: conn.ConnDb, company_id :: Str, kind :: Str, opened_at :: Str, symptoms_json :: Str, cap_milli :: Int) -> [sql] Result[Str, Str] {
  let id := incident_id(company_id, kind, opened_at)
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO operate_incidents (id, company_id, opened_at, closed_at, status, symptoms_json, budget_spent_milli, budget_cap_milli, root_cause) VALUES (?, ?, ?, '', 'triage', ?, 0, ?, '')", params: [PStr(id), PStr(company_id), PStr(opened_at), PStr(symptoms_json), PInt(cap_milli)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(id),
  }
}

# Closing states only — the live FSM (lex-ctl incident.advance) owns the
# intermediate moves; the ledger records terminal outcomes.
fn close_incident(db :: conn.ConnDb, incident :: Str, status :: Str, closed_at :: Str, root_cause :: Str) -> [sql] Result[Unit, Str] {
  if status == "resolved" or status == "escalated" {
    let q := ormq.for_dialect({ sql: "UPDATE operate_incidents SET status=?, closed_at=?, root_cause=? WHERE id=?", params: [PStr(status), PStr(closed_at), PStr(root_cause), PStr(incident)] }, db.dialect)
    match sql.exec(db.handle, q.sql, q.params) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(()),
    }
  } else {
    Err(str.concat("not a terminal status: ", status))
  }
}

fn link_signal(db :: conn.ConnDb, signal_row_id :: Str, incident :: Str) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE company_operate_signals SET incident_id=? WHERE id=?", params: [PStr(incident), PStr(signal_row_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn record_action(db :: conn.ConnDb, incident :: Str, company_id :: Str, class_key :: Str, subsystem :: Str, params_json :: Str, tier :: Str, executed_at :: Str) -> [sql] Result[Str, Str] {
  let id := action_id(incident, class_key, executed_at)
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO operate_actions (id, incident_id, company_id, class_key, subsystem, params_json, tier, executed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(incident), PStr(company_id), PStr(class_key), PStr(subsystem), PStr(params_json), PStr(tier), PStr(executed_at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(id),
  }
}

fn record_effect(db :: conn.ConnDb, action :: Str, incident :: Str, signal :: Str, cmp :: Str, threshold_milli :: Int, contracted_at :: Str, deadline_at :: Str, confidence_pct :: Int, on_falsify :: Str) -> [sql] Result[Str, Str] {
  let id := effect_id(action, signal, cmp, threshold_milli, deadline_at, confidence_pct, on_falsify)
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO operate_effects (id, action_id, incident_id, signal, cmp, threshold_milli, contracted_at, deadline_at, confidence_pct, on_falsify, disposition, disposed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '')", params: [PStr(id), PStr(action), PStr(incident), PStr(signal), PStr(cmp), PInt(threshold_milli), PStr(contracted_at), PStr(deadline_at), PInt(confidence_pct), PStr(on_falsify)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(id),
  }
}

# Verifier dispositions only; ambiguous is recorded as its own word so the
# hit-rate query can (and must) count it as a miss.
fn record_disposition(db :: conn.ConnDb, effect :: Str, disposition :: Str, disposed_at :: Str) -> [sql] Result[Unit, Str] {
  if disposition == "materialised" or disposition == "falsified" or disposition == "ambiguous" {
    let q := ormq.for_dialect({ sql: "UPDATE operate_effects SET disposition=?, disposed_at=? WHERE id=?", params: [PStr(disposition), PStr(disposed_at), PStr(effect)] }, db.dialect)
    match sql.exec(db.handle, q.sql, q.params) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(()),
    }
  } else {
    Err(str.concat("not a verifier disposition: ", disposition))
  }
}

type BudgetRow = { budget_spent_milli :: Int, budget_cap_milli :: Int }

# Append an evidence record, paying its cost from the incident's budget.
# Refuses overruns — budget exhaustion is the caller's cue to escalate and
# log a sensing gap, mirroring lex-ctl incident.spend.
fn record_evidence(db :: conn.ConnDb, incident :: Str, query_text :: Str, cost_milli :: Int, result_ref :: Str, observed_at :: Str) -> [sql] Result[Str, Str] {
  let bq := ormq.for_dialect({ sql: "SELECT budget_spent_milli, budget_cap_milli FROM operate_incidents WHERE id=?", params: [PStr(incident)] }, db.dialect)
  let rows :: Result[List[BudgetRow], SqlError] := sql.query(db.handle, bq.sql, bq.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => match list.head(rs) {
      None => Err(str.concat("no such incident: ", incident)),
      Some(b) => if b.budget_spent_milli + cost_milli > b.budget_cap_milli {
        Err("evidence budget exhausted")
      } else {
        let id := evidence_id(incident, query_text, observed_at)
        let iq := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO operate_evidence (id, incident_id, query_text, cost_milli, result_ref, observed_at) VALUES (?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(incident), PStr(query_text), PInt(cost_milli), PStr(result_ref), PStr(observed_at)] }, db.dialect)
        match sql.exec(db.handle, iq.sql, iq.params) {
          Err(e) => Err(e.message),
          Ok(_) => {
            let uq := ormq.for_dialect({ sql: "UPDATE operate_incidents SET budget_spent_milli=? WHERE id=?", params: [PInt(b.budget_spent_milli + cost_milli), PStr(incident)] }, db.dialect)
            match sql.exec(db.handle, uq.sql, uq.params) {
              Err(e) => Err(e.message),
              Ok(_) => Ok(id),
            }
          },
        }
      },
    },
  }
}

# ── lex-trail emits — the authoritative record ────────────────────────────────
# Payloads carry the content-addressed row id, so trail chain and SQL
# projection agree on identity and an audit is a hash comparison.
fn trail_incident_opened(log :: tlog.Log, incident :: Str, company_id :: Str, kind :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.incident.opened", parent, str.join(["{\"incident_id\":\"", incident, "\",\"company_id\":\"", company_id, "\",\"kind\":\"", kind, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn trail_incident_closed(log :: tlog.Log, incident :: Str, status :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.incident.closed", parent, str.join(["{\"incident_id\":\"", incident, "\",\"status\":\"", status, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn trail_action_executed(log :: tlog.Log, action :: Str, incident :: Str, class_key :: Str, tier :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.action.executed", parent, str.join(["{\"action_id\":\"", action, "\",\"incident_id\":\"", incident, "\",\"class_key\":\"", class_key, "\",\"tier\":\"", tier, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn trail_effect_contracted(log :: tlog.Log, effect :: Str, action :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.effect.contracted", parent, str.join(["{\"effect_id\":\"", effect, "\",\"action_id\":\"", action, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn trail_effect_disposed(log :: tlog.Log, effect :: Str, disposition :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.effect.disposed", parent, str.join(["{\"effect_id\":\"", effect, "\",\"disposition\":\"", disposition, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn trail_evidence_recorded(log :: tlog.Log, evidence :: Str, incident :: Str, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.evidence.recorded", parent, str.join(["{\"evidence_id\":\"", evidence, "\",\"incident_id\":\"", incident, "\"}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

# ── Backfill — the phase-0 replay corpus ──────────────────────────────────────
#
# Derives incident episodes from the raw signal history #85 has been
# accumulating: consecutive unhealthy readings of one kind form an episode;
# the next healthy reading resolves it. Only signals not already linked to
# an incident are considered, so re-running is safe. Historical episodes
# get no evidence budget (cap 0) — they predate the controller.
fn is_healthy(kind :: Str, value :: Str) -> Bool
  examples {
    is_healthy("liveness", "up (launch: http://x)") => true,
    is_healthy("liveness", "down (launch: http://x)") => false,
    is_healthy("errors", "clean") => true,
    is_healthy("errors", "Traceback (most recent call last)") => false,
    is_healthy("other", "anything") => true
  }
{
  if kind == "liveness" {
    str.starts_with(value, "up")
  } else {
    if kind == "errors" {
      str.starts_with(value, "clean")
    } else {
      true
    }
  }
}

type BackfillSignalRow = { id :: Str, value :: Str, observed_at :: Str }

fn backfill_walk(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str, kind :: Str, rows :: List[BackfillSignalRow], open :: Option[Str], opened :: Int) -> [sql, time] Result[Int, Str] {
  match list.head(rows) {
    None => Ok(opened),
    Some(r) => {
      let rest := list.tail(rows)
      if is_healthy(kind, r.value) {
        match open {
          None => backfill_walk(db, log, company_id, kind, rest, None, opened),
          Some(inc) => match close_incident(db, inc, "resolved", r.observed_at, "") {
            Err(e) => Err(e),
            Ok(_) => match trail_incident_closed(log, inc, "resolved", None) {
              Err(e) => Err(e),
              Ok(_) => backfill_walk(db, log, company_id, kind, rest, None, opened),
            },
          },
        }
      } else {
        match open {
          Some(inc) => match link_signal(db, r.id, inc) {
            Err(e) => Err(e),
            Ok(_) => backfill_walk(db, log, company_id, kind, rest, Some(inc), opened),
          },
          None => match open_incident(db, company_id, kind, r.observed_at, str.join(["[\"", kind, "\"]"], ""), 0) {
            Err(e) => Err(e),
            Ok(inc) => match link_signal(db, r.id, inc) {
              Err(e) => Err(e),
              Ok(_) => match trail_incident_opened(log, inc, company_id, kind, None) {
                Err(e) => Err(e),
                Ok(_) => backfill_walk(db, log, company_id, kind, rest, Some(inc), opened + 1),
              },
            },
          },
        }
      }
    },
  }
}

# Backfill one signal kind for one company. Returns the number of episodes
# opened. An episode still unhealthy at the end of history stays open in
# 'triage' — history ran out, not the incident.
fn backfill_kind(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str, kind :: Str) -> [sql, time] Result[Int, Str] {
  let q := ormq.for_dialect({ sql: "SELECT id, value, observed_at FROM company_operate_signals WHERE company_id=? AND kind=? AND incident_id='' ORDER BY idx ASC", params: [PStr(company_id), PStr(kind)] }, db.dialect)
  let rows :: Result[List[BackfillSignalRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => backfill_walk(db, log, company_id, kind, rs, None, 0),
  }
}

fn backfill_company(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str) -> [sql, time] Result[Int, Str] {
  match backfill_kind(db, log, company_id, "liveness") {
    Err(e) => Err(e),
    Ok(a) => match backfill_kind(db, log, company_id, "errors") {
      Err(e) => Err(e),
      Ok(b) => Ok(a + b),
    },
  }
}

type CompanyIdRow = { company_id :: Str }

fn backfill_all(db :: conn.ConnDb, log :: tlog.Log) -> [sql, time] Result[Int, Str] {
  let q := ormq.for_dialect({ sql: "SELECT DISTINCT company_id FROM company_operate_signals", params: [] }, db.dialect)
  let rows :: Result[List[CompanyIdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => backfill_companies(db, log, rs, 0),
  }
}

fn backfill_companies(db :: conn.ConnDb, log :: tlog.Log, rows :: List[CompanyIdRow], acc :: Int) -> [sql, time] Result[Int, Str] {
  match list.head(rows) {
    None => Ok(acc),
    Some(r) => match backfill_company(db, log, r.company_id) {
      Err(e) => Err(e),
      Ok(n) => backfill_companies(db, log, list.tail(rows), acc + n),
    },
  }
}

# ── Replay + corpus queries ───────────────────────────────────────────────────
type ReplayRow = { at :: Str, kind :: Str, ref_id :: Str, detail :: Str }

# One incident's chain in time order:
#   incident.opened → signals → evidence → actions → effect.contracted
#   → effect.disposed → incident.closed
fn replay(db :: conn.ConnDb, incident :: Str) -> [sql] List[ReplayRow] {
  let stmt := "SELECT opened_at AS at, 'incident.opened' AS kind, id AS ref_id, status AS detail FROM operate_incidents WHERE id=? UNION ALL SELECT observed_at, 'signal', id, value FROM company_operate_signals WHERE incident_id=? UNION ALL SELECT observed_at, 'evidence', id, query_text FROM operate_evidence WHERE incident_id=? UNION ALL SELECT executed_at, 'action', id, class_key FROM operate_actions WHERE incident_id=? UNION ALL SELECT contracted_at, 'effect.contracted', id, signal FROM operate_effects WHERE incident_id=? UNION ALL SELECT disposed_at, 'effect.disposed', id, disposition FROM operate_effects WHERE incident_id=? AND disposition!='pending' UNION ALL SELECT closed_at, 'incident.closed', id, status FROM operate_incidents WHERE id=? AND closed_at!='' ORDER BY at ASC"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(incident), PStr(incident), PStr(incident), PStr(incident), PStr(incident), PStr(incident), PStr(incident)] }, db.dialect)
  let rows :: Result[List[ReplayRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

type CountRow = { n :: Int }

fn corpus_size(db :: conn.ConnDb) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT COUNT(*) AS n FROM operate_incidents", params: [] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Grant an evidence budget to an incident that has none (cap 0) — used
# before shadow-diagnosing backfilled episodes, which predate budgets.
# Never shrinks an existing cap.
fn ensure_budget_cap(db :: conn.ConnDb, incident :: Str, cap_milli :: Int) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE operate_incidents SET budget_cap_milli=? WHERE id=? AND budget_cap_milli=0", params: [PInt(cap_milli), PStr(incident)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Ground-truth label for corpus scoring (CTL4): a human (or a test) names
# the incident's actual root cause; diagnosis accuracy is measured only
# over labeled incidents.
fn label_root_cause(db :: conn.ConnDb, incident :: Str, cause :: Str) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE operate_incidents SET root_cause=? WHERE id=?", params: [PStr(cause), PStr(incident)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type IncidentRow = { id :: Str, status :: Str, symptoms_json :: Str, opened_at :: Str, closed_at :: Str }

fn recent_incidents(db :: conn.ConnDb, company_id :: Str, limit :: Int) -> [sql] List[IncidentRow] {
  let q := ormq.for_dialect({ sql: "SELECT id, status, symptoms_json, opened_at, closed_at FROM operate_incidents WHERE company_id=? ORDER BY opened_at DESC LIMIT ?", params: [PStr(company_id), PInt(limit)] }, db.dialect)
  let rows :: Result[List[IncidentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

type IncidentIdRow = { id :: Str }

fn incidents_for(db :: conn.ConnDb, company_id :: Str) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_incidents WHERE company_id=? ORDER BY opened_at ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IncidentIdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: IncidentIdRow) -> Str {
      r.id
    }),
  }
}

# Hit rate per action class from verifier dispositions — the number the
# tier gate consumes. Ambiguous counts as a miss, structurally: only
# 'materialised' is in the numerator, everything disposed is in the
# denominator.
type HitRateRow = { hits :: Int, total :: Int }

fn class_hit_rate_pct(db :: conn.ConnDb, class_key :: Str) -> [sql] Int {
  let stmt := "SELECT SUM(CASE WHEN e.disposition='materialised' THEN 1 ELSE 0 END) AS hits, COUNT(*) AS total FROM operate_effects e JOIN operate_actions a ON e.action_id=a.id WHERE a.class_key=? AND e.disposition!='pending'"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(class_key)] }, db.dialect)
  let rows :: Result[List[HitRateRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => if r.total == 0 {
        0
      } else {
        r.hits * 100 / r.total
      },
    },
  }
}

