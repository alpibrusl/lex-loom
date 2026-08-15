# events.lex — HB2 (lex-loom#214): the append-only event ledger that lets the
# real world wake a dormant company.
#
# Before this, every wake condition was a time/state predicate evaluated when
# something else happened to run the company: a board note sat until the next
# Strategist iteration, an operate signal accrued silently, and an inbound
# support item had no wake path at all. This module is the missing bridge:
#
#   1. APPEND-ONLY. `events` rows are inserted, never edited, never deleted —
#      the only mutation anywhere is the one-shot consumption mark
#      (`consume_all` fills `consumed_at`/`consumed_by` exactly where they are
#      still empty). Replaying the table IS the wake history.
#   2. CLOSED VOCABULARY. `record` refuses an unknown kind instead of storing
#      it (refuse, don't downgrade) — the wake grammar below and the writers
#      share one list, so a typo'd kind can never silently exist-but-never-fire.
#   3. DATA, NEVER INSTRUCTION. An event can trigger a wake; its body is never
#      spliced into any prompt (same trust posture as #118 §2.7). Writers keep
#      caller-controlled text OUT of the ledger — a board-note event stores the
#      note's index, not its text; a support-item event stores the item id, not
#      the customer's words. The woken company reads those through the same
#      grounded paths it always used.
#   4. OPT-IN WAKES. Which kinds wake a company is declared in the manifest's
#      `wake_when` (e.g. `wake_when board_note or support_item`) — the
#      human-authored manifest stays the single source of wake policy. An
#      event of an undeclared kind is recorded but wakes nothing.
#
# The scheduler (HB1) is the reader: `has_wake_eligible` turns an unconsumed
# declared-kind event into an immediate `event_wake` run, and `consume_all`
# marks everything pending as consumed by that run the moment it starts.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "./migrate" as migrate

# ── The closed kind vocabulary ───────────────────────────────────────────────
# One list shared by writers (refuse unknown kinds) and the wake grammar
# (`wake_when board_note or incident`). Growing it is a reviewed code change,
# never a runtime write.
fn known_kinds() -> List[Str]
  examples {
    known_kinds() => ["board_note", "operate_signal", "incident", "support_item", "research_request", "content_request", "webhook"]
  }
{
  ["board_note", "operate_signal", "incident", "support_item", "research_request", "content_request", "webhook"]
}

fn is_known_kind(kind :: Str) -> Bool
  examples {
    is_known_kind("board_note") => true,
    is_known_kind("support_item") => true,
    is_known_kind("rm_rf_slash") => false,
    is_known_kind("") => false
  }
{
  list.fold(known_kinds(), false, fn (found :: Bool, k :: Str) -> Bool {
    found or k == kind
  })
}

# ── The wake grammar (pure) ──────────────────────────────────────────────────
# `wake_when` is a disjunction of atoms joined by " or ". An atom is either
# one of company.lex's grounded-ctx predicates (evaluated there) or a bare
# event kind (evaluated here, against unconsumed events). A condition that
# contains a quoted argument (`digest contains "x or y"`) is never split —
# quoted conditions stay single atoms so the quote's content can't be
# misparsed as a disjunction.
fn split_atoms(cond :: Str) -> List[Str]
  examples {
    split_atoms("board_note or incident") => ["board_note", "incident"],
    split_atoms("verdict-failed") => ["verdict-failed"],
    split_atoms("") => [],
    split_atoms("digest contains \"a or b\"") => ["digest contains \"a or b\""]
  }
{
  let c := str.trim(cond)
  if str.is_empty(c) {
    []
  } else {
    if str.contains(c, "\"") {
      [c]
    } else {
      list.filter(list.map(str.split(c, " or "), fn (a :: Str) -> Str {
        str.trim(a)
      }), fn (a :: Str) -> Bool {
        not str.is_empty(a)
      })
    }
  }
}

# The event kinds a manifest's wake_when declares — the opt-in set. A company
# whose wake_when names no event kind is untouched by the whole event system.
fn wake_kinds(wake_when :: Str) -> List[Str]
  examples {
    wake_kinds("board_note or incident") => ["board_note", "incident"],
    wake_kinds("verdict-failed or board_note") => ["board_note"],
    wake_kinds("verdict-failed") => [],
    wake_kinds("") => []
  }
{
  list.filter(split_atoms(wake_when), fn (a :: Str) -> Bool {
    is_known_kind(a)
  })
}

# ── The ledger ───────────────────────────────────────────────────────────────
type Event = { id :: Str, company_id :: Str, kind :: Str, source :: Str, body_json :: Str, created_at :: Str, consumed_at :: Str, consumed_by :: Str }

type EventRow = { id :: Str, company_id :: Str, kind :: Str, source :: Str, body_json :: Str, created_at :: Str, consumed_at :: Str, consumed_by :: Str }

# Append one event under a caller-chosen deterministic id (INSERT OR IGNORE —
# writers that observe the same fact twice, like a support-item poll, dedupe
# by construction instead of flooding the ledger). Refuses unknown kinds.
fn record_once(db :: conn.ConnDb, id :: Str, company_id :: Str, kind :: Str, source :: Str, body_json :: Str) -> [sql, fs_write, time] Result[Str, Str] {
  if not is_known_kind(kind) {
    Err(str.join(["unknown event kind '", kind, "' — known kinds: ", str.join(known_kinds(), ", ")], ""))
  } else {
    let q := ormq.for_dialect({ sql: "INSERT OR IGNORE INTO company_events (id, company_id, kind, source, body_json, created_at, consumed_at, consumed_by) VALUES (?, ?, ?, ?, ?, ?, '', '')", params: [PStr(id), PStr(company_id), PStr(kind), PStr(source), PStr(body_json), PStr(time.now_str())] }, db.dialect)
    match sql.exec(db.handle, q.sql, q.params) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(id),
    }
  }
}

# Append one event with a fresh random id — for genuinely new occurrences
# (a webhook delivery, an inbound A2A request) that have no natural identity.
fn record(db :: conn.ConnDb, company_id :: Str, kind :: Str, source :: Str, body_json :: Str) -> [sql, fs_write, time, random, crypto] Result[Str, Str] {
  record_once(db, str.join(["ev-", kind, "-", crypto.random_str_hex(8)], ""), company_id, kind, source, body_json)
}

# Writers that live outside a process holding the company DB (the A2A skill
# servers): open + migrate + append in one call, against the ledger path the
# server was configured with.
fn record_inbound(db_path :: Str, company_id :: Str, kind :: Str, source :: Str, body_json :: Str) -> [sql, fs_write, time, random, crypto] Result[Str, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("cannot open event ledger: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => record(db, company_id, kind, source, body_json),
    },
  }
}

fn record_inbound_once(db_path :: Str, id :: Str, company_id :: Str, kind :: Str, source :: Str, body_json :: Str) -> [sql, fs_write, time] Result[Str, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("cannot open event ledger: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => record_once(db, id, company_id, kind, source, body_json),
    },
  }
}

fn unconsumed(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Event] {
  let q := ormq.for_dialect({ sql: "SELECT id, company_id, kind, source, body_json, created_at, consumed_at, consumed_by FROM company_events WHERE company_id=? AND consumed_at='' ORDER BY created_at ASC, id ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[EventRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: EventRow) -> Event {
      { id: r.id, company_id: r.company_id, kind: r.kind, source: r.source, body_json: r.body_json, created_at: r.created_at, consumed_at: r.consumed_at, consumed_by: r.consumed_by }
    }),
  }
}

# The scheduler's question: does an unconsumed event of a kind this company's
# manifest opted into exist right now?
fn has_wake_eligible(db :: conn.ConnDb, company_id :: Str, wake_when :: Str) -> [sql, fs_read] Bool {
  let kinds := wake_kinds(wake_when)
  if list.is_empty(kinds) {
    false
  } else {
    list.fold(unconsumed(db, company_id), false, fn (found :: Bool, e :: Event) -> Bool {
      found or list.fold(kinds, false, fn (m :: Bool, k :: Str) -> Bool {
        m or k == e.kind
      })
    })
  }
}

# The ONE mutation: fill the consumption mark on every still-pending event,
# attributing it to the run that absorbed them. Already-consumed rows are
# untouched by the WHERE clause — a mark, once written, is permanent.
# Returns how many events this call consumed.
fn consume_all(db :: conn.ConnDb, company_id :: Str, consumed_by :: Str) -> [sql, fs_read, fs_write, time] Int {
  let pending := unconsumed(db, company_id)
  if list.is_empty(pending) {
    0
  } else {
    let q := ormq.for_dialect({ sql: "UPDATE company_events SET consumed_at=?, consumed_by=? WHERE company_id=? AND consumed_at=''", params: [PStr(time.now_str()), PStr(consumed_by), PStr(company_id)] }, db.dialect)
    match sql.exec(db.handle, q.sql, q.params) {
      Err(_) => 0,
      Ok(_) => list.len(pending),
    }
  }
}

# The full ledger for one company, chronological — replaying this is the wake
# history the issue's acceptance criteria ask for.
fn history(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id, company_id, kind, source, body_json, created_at, consumed_at, consumed_by FROM company_events WHERE company_id=? ORDER BY created_at ASC, id ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[EventRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: EventRow) -> Str {
      let mark := if str.is_empty(r.consumed_at) {
        "PENDING"
      } else {
        str.join(["consumed by ", r.consumed_by, " at ", r.consumed_at], "")
      }
      str.join(["[", r.created_at, "] ", r.kind, " (", r.source, ") ", r.id, " — ", mark], "")
    }),
  }
}

# ── Operate-side sync bridges (run from the scheduler's monitor pass) ────────
# The operate subsystem already persists its facts (incidents, signal
# readings); these bridges project the wake-relevant ones into the ledger
# under deterministic ids, so each real-world fact becomes at most ONE event
# no matter how many monitor passes observe it.
type IncRow = { id :: Str }

fn sync_incident_events(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read, fs_write, time] Int {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_incidents WHERE company_id=? AND closed_at=''", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IncRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => list.fold(rs, 0, fn (n :: Int, r :: IncRow) -> [sql, fs_write, time] Int {
      match record_once(db, str.concat("ev-incident-", r.id), company_id, "incident", "operate", str.join(["{\"incident\":\"", r.id, "\"}"], "")) {
        Err(_) => n,
        Ok(_) => n + 1,
      }
    }),
  }
}

# Parse a revenue reading's cents out of a raw signal value — either a bare
# integer string or a JSON object carrying `revenue_cents` (both shapes are
# what company.record_operate_signal actually stores).
fn parse_reading_cents(value :: Str) -> Option[Int]
  examples {
    parse_reading_cents("{\"revenue_cents\": 100}") => Some(100),
    parse_reading_cents("250") => Some(250),
    parse_reading_cents("unreachable") => None
  }
{
  match str.to_int(str.trim(value)) {
    Some(n) => Some(n),
    None => match jv.parse(value) {
      Err(_) => None,
      Ok(j) => match jv.get_field(j, "revenue_cents") {
        Some(JInt(n)) => Some(n),
        _ => None,
      },
    },
  }
}

type SigRow = { id :: Str, value :: Str }

# "Revenue moved": the latest revenue reading differs from the one before it
# (a first-ever non-zero reading counts as moving from 0). Keyed on the
# signal row's id, so a changed reading events exactly once.
fn sync_revenue_events(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read, fs_write, time] Int {
  let q := ormq.for_dialect({ sql: "SELECT id, value FROM company_operate_signals WHERE company_id=? AND kind='revenue_cents' ORDER BY observed_at DESC, id DESC LIMIT 2", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[SigRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(latest) => match parse_reading_cents(latest.value) {
        None => 0,
        Some(now_cents) => {
          let prev_cents := match list.head(list.tail(rs)) {
            None => 0,
            Some(p) => match parse_reading_cents(p.value) {
              None => 0,
              Some(c) => c,
            },
          }
          if now_cents == prev_cents {
            0
          } else {
            match record_once(db, str.concat("ev-rev-", latest.id), company_id, "operate_signal", "operate", str.join(["{\"signal\":\"revenue_cents\",\"from\":", int.to_str(prev_cents), ",\"to\":", int.to_str(now_cents), "}"], "")) {
              Err(_) => 0,
              Ok(_) => 1,
            }
          }
        },
      },
    },
  }
}

fn sync_operate_events(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read, fs_write, time] Int {
  sync_incident_events(db, company_id) + sync_revenue_events(db, company_id)
}

