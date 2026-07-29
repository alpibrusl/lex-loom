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
# Every insert below uses `ON CONFLICT(id) DO NOTHING`, not SQLite-only
# `INSERT OR REPLACE` (#135 — the latter has no Postgres equivalent and
# throws a syntax error on that dialect). DO NOTHING is the correct
# semantics here, not just a portable substitute: every id in this file
# is content-addressed (SHA-256 over the row's own fields), so a second
# insert under the same id can only ever carry identical content —
# there is nothing to "replace".
fn open_incident(db :: conn.ConnDb, company_id :: Str, kind :: Str, opened_at :: Str, symptoms_json :: Str, cap_milli :: Int) -> [sql] Result[Str, Str] {
  let id := incident_id(company_id, kind, opened_at)
  let q := ormq.for_dialect({ sql: "INSERT INTO operate_incidents (id, company_id, opened_at, closed_at, status, symptoms_json, budget_spent_milli, budget_cap_milli, root_cause) VALUES (?, ?, ?, '', 'triage', ?, 0, ?, '') ON CONFLICT(id) DO NOTHING", params: [PStr(id), PStr(company_id), PStr(opened_at), PStr(symptoms_json), PInt(cap_milli)] }, db.dialect)
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
  let q := ormq.for_dialect({ sql: "INSERT INTO operate_actions (id, incident_id, company_id, class_key, subsystem, params_json, tier, executed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING", params: [PStr(id), PStr(incident), PStr(company_id), PStr(class_key), PStr(subsystem), PStr(params_json), PStr(tier), PStr(executed_at)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(id),
  }
}

fn record_effect(db :: conn.ConnDb, action :: Str, incident :: Str, signal :: Str, cmp :: Str, threshold_milli :: Int, contracted_at :: Str, deadline_at :: Str, confidence_pct :: Int, on_falsify :: Str) -> [sql] Result[Str, Str] {
  let id := effect_id(action, signal, cmp, threshold_milli, deadline_at, confidence_pct, on_falsify)
  let q := ormq.for_dialect({ sql: "INSERT INTO operate_effects (id, action_id, incident_id, signal, cmp, threshold_milli, contracted_at, deadline_at, confidence_pct, on_falsify, disposition, disposed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', '') ON CONFLICT(id) DO NOTHING", params: [PStr(id), PStr(action), PStr(incident), PStr(signal), PStr(cmp), PInt(threshold_milli), PStr(contracted_at), PStr(deadline_at), PInt(confidence_pct), PStr(on_falsify)] }, db.dialect)
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
        let iq := ormq.for_dialect({ sql: "INSERT INTO operate_evidence (id, incident_id, query_text, cost_milli, result_ref, observed_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING", params: [PStr(id), PStr(incident), PStr(query_text), PInt(cost_milli), PStr(result_ref), PStr(observed_at)] }, db.dialect)
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

# Every trail log is `Option[tlog.Log]` at the call sites above — the
# runner doesn't always carry one yet — and every caller (sensing.lex,
# diagnosis.lex, effects.lex) repeated the same shape near-verbatim:
# skip the emit entirely with no log, run it and propagate any error
# with one, otherwise return the SAME success value either way (#140).
# Named once here so those call sites collapse to a single expression.
fn emit_optional[S](log :: Option[tlog.Log], emit :: (tlog.Log) -> [sql, time] Result[Str, Str], on_success :: S) -> [sql, time] Result[S, Str] {
  match log {
    None => Ok(on_success),
    Some(l) => match emit(l) {
      Err(e) => Err(e),
      Ok(_) => Ok(on_success),
    },
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

type OpenIncidentRow = { id :: Str }

# Every currently-open incident for a company, oldest first.
fn open_incidents_for(db :: conn.ConnDb, company_id :: Str) -> [sql] List[OpenIncidentRow] {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_incidents WHERE company_id=? AND closed_at='' ORDER BY opened_at ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[OpenIncidentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

type LastSignalRow = { observed_at :: Str }

# The last signal actually linked to an incident — the closing
# timestamp a merge (below) uses, so a closed-as-redundant incident's
# `closed_at` reflects its own evidence, not an arbitrary "now".
fn last_signal_at(db :: conn.ConnDb, incident :: Str) -> [sql] Str {
  let q := ormq.for_dialect({ sql: "SELECT observed_at FROM company_operate_signals WHERE incident_id=? ORDER BY idx DESC LIMIT 1", params: [PStr(incident)] }, db.dialect)
  let rows :: Result[List[LastSignalRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) {
      None => "",
      Some(r) => r.observed_at,
    },
  }
}

fn close_redundant_opens(db :: conn.ConnDb, log :: tlog.Log, rows :: List[OpenIncidentRow]) -> [sql, time] Result[Int, Str] {
  match list.head(rows) {
    None => Ok(0),
    Some(r) => match close_incident(db, r.id, "resolved", last_signal_at(db, r.id), "") {
      Err(e) => Err(e),
      Ok(_) => match trail_incident_closed(log, r.id, "resolved", None) {
        Err(e) => Err(e),
        Ok(_) => match close_redundant_opens(db, log, list.tail(rows)) {
          Err(e) => Err(e),
          Ok(n) => Ok(n + 1),
        },
      },
    },
  }
}

# `backfill_kind` processes "liveness" and "errors" as fully
# independent per-kind streams, each starting its own walk with no
# incident open (#137). If a company's history ends unhealthy on BOTH
# series at once, this leaves two simultaneously-open incidents — but
# every live-sensing function (`sensing.open_incident_for`, `all_calm`,
# `sense_company`) assumes at most one open incident per company,
# picking whichever was opened most recently. Left alone, a live firing
# after backfill would attach to "whichever incident happens to be
# more recent" — possibly the wrong kind's episode entirely.
#
# Closes every open incident except the one `open_incident_for` would
# already pick (the most recently opened) as 'resolved', so after
# backfill there is unambiguously at most one — restoring the
# invariant rather than merely working around it.
# `opens` has length >= 2 here (the `<= 1` case already returned), so
# `list.reverse` is non-empty and `list.tail` drops only the most
# recently opened one (now first, after the reverse) — leaving every
# OTHER (older) open incident to be closed as redundant.
fn reconcile_open_incidents(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str) -> [sql, time] Result[Unit, Str] {
  let opens := open_incidents_for(db, company_id)
  if list.len(opens) <= 1 {
    Ok(())
  } else {
    match close_redundant_opens(db, log, list.tail(list.reverse(opens))) {
      Err(e) => Err(e),
      Ok(_) => Ok(()),
    }
  }
}

fn backfill_company(db :: conn.ConnDb, log :: tlog.Log, company_id :: Str) -> [sql, time] Result[Int, Str] {
  match backfill_kind(db, log, company_id, "liveness") {
    Err(e) => Err(e),
    Ok(a) => match backfill_kind(db, log, company_id, "errors") {
      Err(e) => Err(e),
      Ok(b) => match reconcile_open_incidents(db, log, company_id) {
        Err(e) => Err(e),
        Ok(_) => Ok(a + b),
      },
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

# Set an incident's diagnosed verdict directly (bypassing the tool
# ladder) — for tests and for a human overriding a diagnosis. The normal
# writer is `diagnosis.diagnose`.
fn set_diagnosed_cause(db :: conn.ConnDb, incident :: Str, cause :: Str, p_pct :: Int) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE operate_incidents SET diagnosed_cause=?, diagnosed_p_pct=? WHERE id=?", params: [PStr(cause), PInt(p_pct), PStr(incident)] }, db.dialect)
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

# Read the incident row propose_contract needs: which company, and what
# diagnosis (CTL4) said. cause/p_pct are '' / 0 when undiagnosed.
type IncidentDiagRow = { company_id :: Str, diagnosed_cause :: Str, diagnosed_p_pct :: Int, symptoms_json :: Str }

fn incident_diag(db :: conn.ConnDb, incident :: Str) -> [sql] Option[IncidentDiagRow] {
  let q := ormq.for_dialect({ sql: "SELECT company_id, diagnosed_cause, diagnosed_p_pct, symptoms_json FROM operate_incidents WHERE id=?", params: [PStr(incident)] }, db.dialect)
  let rows :: Result[List[IncidentDiagRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

# Persist a contract's iteration-index window (CTL5). loom has no
# wall-clock scheduler yet, so the between-iteration counter (`idx`,
# already the ordering key on every operate_* row) stands in for the
# kernel's "ms" unit — the same field name (`deadline_ms`) is reused with
# this meaning when the row is handed to lex-ctl's verifier.
fn set_effect_window(db :: conn.ConnDb, effect :: Str, contracted_at_idx :: Int, deadline_idx :: Int) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE operate_effects SET contracted_at_idx=?, deadline_idx=? WHERE id=?", params: [PInt(contracted_at_idx), PInt(deadline_idx), PStr(effect)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# The join every effect/action query below needs — named once so the
# 8 call sites can't silently drift out of sync with each other (#140).
fn join_effects_actions() -> Str {
  "operate_effects e JOIN operate_actions a ON e.action_id=a.id"
}

# Full row needed to reconstruct a lex-ctl EffectContract for judging.
type EffectFullRow = { action_id :: Str, incident_id :: Str, company_id :: Str, class_key :: Str, subsystem :: Str, signal :: Str, cmp :: Str, threshold_milli :: Int, contracted_at_idx :: Int, deadline_idx :: Int, confidence_pct :: Int, on_falsify :: Str, disposition :: Str, expected_state_hash :: Str }

fn effect_full(db :: conn.ConnDb, effect :: Str) -> [sql] Option[EffectFullRow] {
  let stmt := str.join(["SELECT a.id AS action_id, e.incident_id AS incident_id, a.company_id AS company_id, a.class_key AS class_key, a.subsystem AS subsystem, e.signal AS signal, e.cmp AS cmp, e.threshold_milli AS threshold_milli, e.contracted_at_idx AS contracted_at_idx, e.deadline_idx AS deadline_idx, e.confidence_pct AS confidence_pct, e.on_falsify AS on_falsify, e.disposition AS disposition, e.expected_state_hash AS expected_state_hash FROM ", join_effects_actions(), " WHERE e.id=?"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(effect)] }, db.dialect)
  let rows :: Result[List[EffectFullRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

# The precondition hash captured at propose time (CTL6): a content hash
# of whatever observed state motivated the action. Re-derived and
# compared at decision time; a mismatch means the world moved since
# proposal and the action must not execute.
fn set_expected_state_hash(db :: conn.ConnDb, effect :: Str, hash :: Str) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE operate_effects SET expected_state_hash=? WHERE id=?", params: [PStr(hash), PStr(effect)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type EffectIdRow = { id :: Str }

fn pending_effects(db :: conn.ConnDb) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_effects WHERE disposition='pending' ORDER BY contracted_at_idx ASC", params: [] }, db.dialect)
  let rows :: Result[List[EffectIdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: EffectIdRow) -> Str {
      r.id
    }),
  }
}

# Same as `pending_effects`, scoped to one company — the board report
# (#139) needs to know which of ITS OWN pending contracts to run
# through `actuation.decide`, not every company's.
fn pending_effects_for_company(db :: conn.ConnDb, company_id :: Str) -> [sql] List[Str] {
  let stmt := str.join(["SELECT e.id AS id FROM ", join_effects_actions(), " WHERE a.company_id=? AND e.disposition='pending' ORDER BY e.contracted_at_idx ASC"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[EffectIdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: EffectIdRow) -> Str {
      r.id
    }),
  }
}

type CountRow2 = { n :: Int }

# Other STILL-PENDING contracts on the same subsystem whose window
# overlaps this one's — the ambiguity signal the verifier needs. A
# contract's own row is excluded by id.
#
# Standard interval-overlap test (#140 — spelled out because the param
# order below does NOT match the argument list above, which reads as a
# bug until you check the SQL: `other.contracted_at_idx <= this
# window's END` needs THIS row's `deadline_idx`, and `other.deadline_idx
# >= this window's START` needs THIS row's `contracted_at_idx` — the
# two params are correctly swapped relative to their own names, not
# misordered. A "fix" that reorders them to match the argument list
# would silently invert the overlap test.
fn concurrent_on_subsystem(db :: conn.ConnDb, subsystem :: Str, exclude_effect :: Str, contracted_at_idx :: Int, deadline_idx :: Int) -> [sql] Int {
  let stmt := str.join(["SELECT COUNT(*) AS n FROM ", join_effects_actions(), " WHERE a.subsystem=? AND e.id!=? AND e.disposition='pending' AND e.contracted_at_idx<=? AND e.deadline_idx>=?"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(subsystem), PStr(exclude_effect), PInt(deadline_idx), PInt(contracted_at_idx)] }, db.dialect)
  let rows :: Result[List[CountRow2], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Verified (non-pending) sample count for a class, scoped to ONE
# company — the ≥30-samples half of the CTL6 promotion gate;
# class_hit_rate_pct is the ≥70% half. Company-scoped because a class
# key (e.g. "restart") names a KIND of remediation, not a specific
# target; company A's servers being reliably restartable says nothing
# about company B's, so the measured record must not cross that
# boundary (#134 — was previously global-by-class, letting one
# company's failures trip the breaker for every other company).
fn class_sample_count(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] Int {
  let stmt := str.join(["SELECT COUNT(*) AS n FROM ", join_effects_actions(), " WHERE a.company_id=? AND a.class_key=? AND e.disposition!='pending'"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id), PStr(class_key)] }, db.dialect)
  let rows :: Result[List[CountRow2], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# ── CTL6: real per-class history, dwell reconstruction, oscillation ──────────
type DispositionRow = { disposition :: Str }

# Every verified disposition for a class ON ONE COMPANY, in the order
# it was decided — the real record `lex-ctl/tier.record` folds into
# ClassStats. Chronological by disposed_at, so consecutive-miss
# tracking matches how the breaker actually experienced the class.
# Company-scoped for the same reason as class_sample_count (#134).
fn class_dispositions(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] List[Str] {
  let stmt := str.join(["SELECT e.disposition AS disposition FROM ", join_effects_actions(), " WHERE a.company_id=? AND a.class_key=? AND e.disposition!='pending' ORDER BY e.disposed_at ASC"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id), PStr(class_key)] }, db.dialect)
  let rows :: Result[List[DispositionRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: DispositionRow) -> Str {
      r.disposition
    }),
  }
}

type WindowRow = { subsystem :: Str, deadline_idx :: Int }

# Every STILL-PENDING contract's window on a subsystem, shaped as
# `lex-ctl/stability.DwellLock` rows (`held_until_ms` reused as the
# absolute idx the window releases at) — reconstructed from the ledger
# each call, since loom has no long-lived in-process lock table.
fn active_dwell_windows(db :: conn.ConnDb, subsystem :: Str, exclude_effect :: Str) -> [sql] List[WindowRow] {
  let stmt := str.join(["SELECT a.subsystem AS subsystem, e.deadline_idx AS deadline_idx FROM ", join_effects_actions(), " WHERE a.subsystem=? AND e.disposition='pending' AND e.id!=?"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(subsystem), PStr(exclude_effect)] }, db.dialect)
  let rows :: Result[List[WindowRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# All OTHER pending contracts system-wide, excluding the one being
# decided on — the global concurrency count the design's cap (1 during
# CTL6) is measured against, independent of how many incidents happen
# to be open. A contract's own (already-persisted) pending row must not
# count against itself.
fn pending_count(db :: conn.ConnDb, exclude_effect :: Str) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT COUNT(*) AS n FROM operate_effects WHERE disposition='pending' AND id!=?", params: [PStr(exclude_effect)] }, db.dialect)
  let rows :: Result[List[CountRow2], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Oscillation signal: pairs of same-class-key, same-subsystem contracts
# whose starts are within `window_idx` of each other — exactly what the
# dwell lock exists to prevent. Counted independent of whether either
# side ever actually executed, so the metric is meaningful the moment
# CTL5 starts proposing, not only once CTL6 has a live actuator.
fn oscillation_pairs(db :: conn.ConnDb, class_key :: Str, window_idx :: Int) -> [sql] Int {
  let stmt := "SELECT COUNT(*) AS n FROM operate_effects e1 JOIN operate_actions a1 ON e1.action_id=a1.id JOIN operate_actions a2 ON a2.class_key=a1.class_key AND a2.subsystem=a1.subsystem JOIN operate_effects e2 ON e2.action_id=a2.id WHERE a1.class_key=? AND e1.id!=e2.id AND e2.contracted_at_idx>e1.contracted_at_idx AND e2.contracted_at_idx<=e1.contracted_at_idx+?"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(class_key), PInt(window_idx)] }, db.dialect)
  let rows :: Result[List[CountRow2], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
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

# Hit rate per action class ON ONE COMPANY from verifier dispositions —
# the number the tier gate consumes. Ambiguous counts as a miss,
# structurally: only 'materialised' is in the numerator, everything
# disposed is in the denominator. Company-scoped for the same reason as
# class_sample_count (#134). COALESCE guards the same NULL-over-zero-
# rows shape already fixed on this query's CTL7 siblings (#136) — a
# company with zero dispositions for a class must read as 0/0, not
# crash on a NULL `hits`.
type HitRateRow = { hits :: Int, total :: Int }

fn class_hit_rate_pct(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] Int {
  let stmt := str.join(["SELECT COALESCE(SUM(CASE WHEN e.disposition='materialised' THEN 1 ELSE 0 END), 0) AS hits, COUNT(*) AS total FROM ", join_effects_actions(), " WHERE a.company_id=? AND a.class_key=? AND e.disposition!='pending'"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id), PStr(class_key)] }, db.dialect)
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

# ── CTL7: company-scoped controller metrics for the Strategist ──────────────
# The Strategist reads summarised numbers here, never incident narrative —
# same trust boundary as diagnosis/actuation (#118 design invariant).
fn pct_of(hits :: Int, total :: Int) -> Int
  examples {
    pct_of(7, 10) => 70,
    pct_of(0, 0) => 0
  }
{
  if total == 0 {
    0
  } else {
    hits * 100 / total
  }
}

type IncidentCountRow = { open_n :: Int, resolved_n :: Int, escalated_n :: Int }

# Open vs. terminal-resolved vs. terminal-escalated incident counts for a
# company — the "resolved (auto) vs. escalated" split CTL7 asks for.
fn incident_counts(db :: conn.ConnDb, company_id :: Str) -> [sql] IncidentCountRow {
  let stmt := "SELECT COALESCE(SUM(CASE WHEN closed_at='' THEN 1 ELSE 0 END), 0) AS open_n, COALESCE(SUM(CASE WHEN status='resolved' THEN 1 ELSE 0 END), 0) AS resolved_n, COALESCE(SUM(CASE WHEN status='escalated' THEN 1 ELSE 0 END), 0) AS escalated_n FROM operate_incidents WHERE company_id=?"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IncidentCountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => { open_n: 0, resolved_n: 0, escalated_n: 0 },
    Ok(rs) => match list.head(rs) {
      None => { open_n: 0, resolved_n: 0, escalated_n: 0 },
      Some(r) => r,
    },
  }
}

type EvidenceCostRow = { total_milli :: Int, closed_n :: Int }

# Total evidence spend (the incident budget CTL4/#85 already meters) over
# closed incidents — "evidence cost per incident resolved" is total/closed_n.
fn evidence_cost_stats(db :: conn.ConnDb, company_id :: Str) -> [sql] EvidenceCostRow {
  let stmt := "SELECT COALESCE(SUM(budget_spent_milli), 0) AS total_milli, COALESCE(SUM(CASE WHEN closed_at!='' THEN 1 ELSE 0 END), 0) AS closed_n FROM operate_incidents WHERE company_id=?"
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[EvidenceCostRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => { total_milli: 0, closed_n: 0 },
    Ok(rs) => match list.head(rs) {
      None => { total_milli: 0, closed_n: 0 },
      Some(r) => r,
    },
  }
}

type WindowHitRow = { hits :: Int, total :: Int }

# Company-wide hit rate over ALL verified (non-pending) effects — every
# class this company has ever contracted, folded together.
fn company_effect_stats(db :: conn.ConnDb, company_id :: Str) -> [sql] WindowHitRow {
  let stmt := str.join(["SELECT COALESCE(SUM(CASE WHEN e.disposition='materialised' THEN 1 ELSE 0 END), 0) AS hits, COUNT(*) AS total FROM ", join_effects_actions(), " WHERE a.company_id=? AND e.disposition!='pending'"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[WindowHitRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => { hits: 0, total: 0 },
    Ok(rs) => match list.head(rs) {
      None => { hits: 0, total: 0 },
      Some(r) => r,
    },
  }
}

# Hit rate over the `limit_n` most-recently-disposed effects, `offset_n`
# back from the newest — the two windows a trend compares.
fn company_hit_window(db :: conn.ConnDb, company_id :: Str, limit_n :: Int, offset_n :: Int) -> [sql] WindowHitRow {
  let stmt := str.join(["SELECT COALESCE(SUM(CASE WHEN disposition='materialised' THEN 1 ELSE 0 END), 0) AS hits, COUNT(*) AS total FROM (SELECT e.disposition AS disposition FROM ", join_effects_actions(), " WHERE a.company_id=? AND e.disposition!='pending' ORDER BY e.disposed_at DESC LIMIT ? OFFSET ?) w"], "")
  let q := ormq.for_dialect({ sql: stmt, params: [PStr(company_id), PInt(limit_n), PInt(offset_n)] }, db.dialect)
  let rows :: Result[List[WindowHitRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => { hits: 0, total: 0 },
    Ok(rs) => match list.head(rs) {
      None => { hits: 0, total: 0 },
      Some(r) => r,
    },
  }
}

fn trend_window_size() -> Int
  examples {
    trend_window_size() => 10
  }
{
  10
}

# Pure comparison: recent window's hit rate against the one before it. A
# window under 4 verified effects is too thin to call a direction on, so
# both windows must clear that floor before "improving"/"declining" is said.
fn hit_rate_trend_str(recent :: WindowHitRow, older :: WindowHitRow) -> Str
  examples {
    hit_rate_trend_str({ hits: 1, total: 2 }, { hits: 0, total: 1 }) => "insufficient data",
    hit_rate_trend_str({ hits: 9, total: 10 }, { hits: 5, total: 10 }) => "improving (50% -> 90%)",
    hit_rate_trend_str({ hits: 5, total: 10 }, { hits: 9, total: 10 }) => "declining (90% -> 50%)",
    hit_rate_trend_str({ hits: 7, total: 10 }, { hits: 7, total: 10 }) => "steady (~70%)"
  }
{
  if recent.total < 4 or older.total < 4 {
    "insufficient data"
  } else {
    let r_pct := pct_of(recent.hits, recent.total)
    let o_pct := pct_of(older.hits, older.total)
    let diff := r_pct - o_pct
    if diff > 5 {
      str.join(["improving (", int.to_str(o_pct), "% -> ", int.to_str(r_pct), "%)"], "")
    } else {
      if diff < -5 {
        str.join(["declining (", int.to_str(o_pct), "% -> ", int.to_str(r_pct), "%)"], "")
      } else {
        str.join(["steady (~", int.to_str(r_pct), "%)"], "")
      }
    }
  }
}

fn company_hit_rate_trend(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  let w := trend_window_size()
  hit_rate_trend_str(company_hit_window(db, company_id, w, 0), company_hit_window(db, company_id, w, w))
}

# The Strategist-facing rollup: everything CTL7 asks for in one call —
# open/resolved/escalated incidents, verified-action hit rate + trend,
# average evidence cost per closed incident. No incident narrative.
type OperateMetrics = { open_incidents :: Int, resolved_count :: Int, escalated_count :: Int, verified_effects :: Int, hit_rate_pct :: Int, hit_rate_trend :: Str, avg_evidence_cost_milli :: Int }

fn operate_metrics(db :: conn.ConnDb, company_id :: Str) -> [sql] OperateMetrics {
  let ic := incident_counts(db, company_id)
  let overall := company_effect_stats(db, company_id)
  let ec := evidence_cost_stats(db, company_id)
  { open_incidents: ic.open_n, resolved_count: ic.resolved_n, escalated_count: ic.escalated_n, verified_effects: overall.total, hit_rate_pct: pct_of(overall.hits, overall.total), hit_rate_trend: company_hit_rate_trend(db, company_id), avg_evidence_cost_milli: if ec.closed_n == 0 {
    0
  } else {
    ec.total_milli / ec.closed_n
  } }
}

