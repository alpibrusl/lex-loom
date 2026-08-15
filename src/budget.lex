# budget.lex — GOV2 (lex-loom#222): budget authority — per-role spend
# envelopes enforced from the ledger.
#
# Before this, budget was one global number (policy.budget_eur -> a
# `spend ge N` stop condition): every role spent from the same pot until the
# company-wide kill switch fired. An envelope is AUTHORITY TO SPEND UP TO X
# — declared per scope ('total', or 'role:<kind>'), integer cents always.
#
# The rules, all structural:
#
#   1. ENFORCED AT DISPATCH. Before a node runs, its role's envelope (and
#      the company 'total') is checked; an exhausted envelope REFUSES the
#      node — that subtree stops while unrelated roles continue. Before an
#      iteration starts, the 'total' envelope is checked — an exhausted
#      company stops and ESCALATES up the ORG1 reporting lines into the
#      attention queue (once), while sibling tracks in a portfolio keep
#      running. Refuse, don't downgrade — there is no overdraft.
#   2. CHARGED FROM THE LEDGER. Node cost uses the same estimate the cost
#      ledger v0 uses (artifact chars -> tokens -> cents), charged
#      atomically (spent = spent + ?) at node completion to the role scope
#      and the total scope — concurrent workers can never drive an
#      envelope negative, and utilization is always the sum of real
#      charges.
#   3. WARN BEFORE THE WALL. Crossing the soft threshold (80%) trails a
#      budget_warning (once per scope) and shows in the board report, so
#      budget pressure is something agents and the board see coming.
#   4. BOARD-ONLY CHANGES. The only writers are the launch manifest
#      ([budget.envelopes], validated, refuse-on-invalid) and the board's
#      set-envelope CLI (RESOLVER_ID required) — every change is trailed
#      with who made it. No agent code path can raise its own cap.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.sql" as sql

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "./role_kinds" as role_kinds

import "./transport" as tr

import "./org" as org

fn soft_threshold_pct() -> Int {
  80
}

# ── Model ────────────────────────────────────────────────────────────────────
type Envelope = { scope :: Str, cap_cents :: Int, spent_cents :: Int }

fn envelope_id(company_id :: Str, scope :: Str) -> Str {
  str.join([company_id, "|", scope], "")
}

fn valid_scope(scope :: Str) -> Bool {
  if scope == "total" {
    true
  } else {
    match str.strip_prefix(scope, "role:") {
      None => false,
      Some(kind) => list.fold(role_kinds.known_kinds(), false, fn (found :: Bool, k :: Str) -> Bool {
        found or k == kind
      }),
    }
  }
}

fn part_at(xs :: List[Str], i :: Int) -> Str {
  match list.head(if i == 0 {
    xs
  } else {
    if i == 1 {
      list.tail(xs)
    } else {
      list.tail(list.tail(xs))
    }
  }) {
    Some(s) => s,
    None => "",
  }
}

# ── Manifest parsing (refuse, don't downgrade) ───────────────────────────────
# "total:5000,role:build:2000" — scope:cents pairs, integer cents > 0.
fn parse_envelope_spec(spec :: Str) -> Result[List[(Str, Int)], Str] {
  let parts := list.filter(list.map(str.split(spec, ","), fn (x :: Str) -> Str {
    str.trim(x)
  }), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  list.fold(parts, Ok([]), fn (acc :: Result[List[(Str, Int)], Str], part :: Str) -> Result[List[(Str, Int)], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(seen) => {
        let pieces := str.split(part, ":")
        let n := list.len(pieces)
        let scope := if n == 2 {
          part_at(pieces, 0)
        } else {
          if n == 3 {
            str.join([part_at(pieces, 0), ":", part_at(pieces, 1)], "")
          } else {
            ""
          }
        }
        let cents_raw := if n == 2 {
          part_at(pieces, 1)
        } else {
          part_at(pieces, 2)
        }
        if not valid_scope(scope) {
          Err(str.join(["invalid envelope scope '", scope, "' in '", part, "' — use 'total' or 'role:<castable kind>'"], ""))
        } else {
          match str.to_int(cents_raw) {
            None => Err(str.join(["invalid envelope amount in '", part, "' — integer cents required"], "")),
            Some(cents) => if cents <= 0 {
              Err(str.join(["invalid envelope amount in '", part, "' — must be > 0 cents"], ""))
            } else {
              Ok(list.concat(seen, [(scope, cents)]))
            },
          }
        }
      },
    }
  })
}

# ── Storage ──────────────────────────────────────────────────────────────────
fn set_envelope(db :: conn.ConnDb, company_id :: Str, scope :: Str, cap_cents :: Int, actor :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  if not valid_scope(scope) {
    Err(str.join(["invalid envelope scope '", scope, "'"], ""))
  } else {
    if cap_cents <= 0 {
      Err("envelope cap must be > 0 cents")
    } else {
      let now := time.now_str()
      let q := ormq.for_dialect({ sql: "INSERT INTO budget_envelopes (id, company_id, scope, cap_cents, spent_cents, created_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?) ON CONFLICT(id) DO UPDATE SET cap_cents=excluded.cap_cents, updated_at=excluded.updated_at", params: [PStr(envelope_id(company_id, scope)), PStr(company_id), PStr(scope), PInt(cap_cents), PStr(now), PStr(now)] }, db.dialect)
      match sql.exec(db.handle, q.sql, q.params) {
        Err(e) => Err(e.message),
        Ok(_) => {
          let __t := tr.trail(db, company_id, "budget_envelope_set", str.join(["{\"scope\":\"", scope, "\",\"cap_cents\":", int.to_str(cap_cents), ",\"by\":\"", actor, "\"}"], ""))
          Ok(())
        },
      }
    }
  }
}

fn load_envelopes(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Envelope] {
  let q := ormq.for_dialect({ sql: "SELECT scope, cap_cents, spent_cents FROM budget_envelopes WHERE company_id=? ORDER BY scope ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[Envelope], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn envelope_for(db :: conn.ConnDb, company_id :: Str, scope :: Str) -> [sql, fs_read] Option[Envelope] {
  list.fold(load_envelopes(db, company_id), None, fn (acc :: Option[Envelope], e :: Envelope) -> Option[Envelope] {
    match acc {
      Some(_) => acc,
      None => if e.scope == scope {
        Some(e)
      } else {
        None
      },
    }
  })
}

# ── Charging (atomic; can never go negative) ─────────────────────────────────
# Charges land on the role scope AND the total scope; a scope with no
# declared envelope is simply not tracked (no phantom rows). The UPDATE is a
# single atomic increment, so concurrent workers serialize in the DB and the
# spent counter is always the exact sum of charges.
fn charge(db :: conn.ConnDb, company_id :: Str, role :: Str, cents :: Int) -> [sql, fs_read, fs_write, time] Unit {
  if cents <= 0 {
    ()
  } else {
    let now := time.now_str()
    let __each := list.map(["total", str.concat("role:", role)], fn (scope :: Str) -> [sql, fs_write, time] Unit {
      let q := ormq.for_dialect({ sql: "UPDATE budget_envelopes SET spent_cents = spent_cents + ?, updated_at=? WHERE id=?", params: [PInt(cents), PStr(now), PStr(envelope_id(company_id, scope))] }, db.dialect)
      let __r := sql.exec(db.handle, q.sql, q.params)
      ()
    })
    ()
  }
}

# The same cost estimate the ledger v0 uses: chars -> tokens (/4) -> cents.
fn artifact_cost_cents(content_len :: Int) -> Int {
  content_len / 4 * 30 / 1000
}

# ── State checks ─────────────────────────────────────────────────────────────
type EnvelopeState = Headroom | Warned(Int) | Exhausted

fn state_of(e :: Envelope) -> EnvelopeState {
  if e.spent_cents >= e.cap_cents {
    Exhausted
  } else {
    let pct := e.spent_cents * 100 / e.cap_cents
    if pct >= soft_threshold_pct() {
      Warned(pct)
    } else {
      Headroom
    }
  }
}

fn check_scope(db :: conn.ConnDb, company_id :: Str, scope :: Str) -> [sql, fs_read] EnvelopeState {
  match envelope_for(db, company_id, scope) {
    None => Headroom,
    Some(e) => state_of(e),
  }
}

# A role dispatch consults both its own envelope and the total.
fn check_role(db :: conn.ConnDb, company_id :: Str, role :: Str) -> [sql, fs_read] EnvelopeState {
  match check_scope(db, company_id, "total") {
    Exhausted => Exhausted,
    _ => check_scope(db, company_id, str.concat("role:", role)),
  }
}

# Soft-threshold warning, trailed at most once per scope.
fn warn_if_needed(db :: conn.ConnDb, company_id :: Str, scope :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  match check_scope(db, company_id, scope) {
    Warned(pct) => if tr.trail_contains(db, company_id, "budget_warning", str.join(["\"scope\":\"", scope, "\""], "")) {
      ()
    } else {
      tr.trail(db, company_id, "budget_warning", str.join(["{\"scope\":\"", scope, "\",\"used_pct\":", int.to_str(pct), "}"], ""))
    },
    _ => (),
  }
}

# Hard-cap escalation: an attention item for the board plus a trail event
# carrying the ORG1 escalation chain — at most once per scope. The company
# does not silently overdraft; it stops and asks upward.
fn escalate_exhausted(db :: conn.ConnDb, company_id :: Str, scope :: Str, role_hint :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  if tr.trail_contains(db, company_id, "budget_escalated", str.join(["\"scope\":\"", scope, "\""], "")) {
    ()
  } else {
    let chain := org.escalation_chain(org.load_org(db, company_id), role_hint)
    let chain_str := if list.is_empty(chain) {
      "(flat — no reporting line)"
    } else {
      str.join(chain, " -> ")
    }
    let __a := tr.push_attention(db, str.concat(company_id, "/budget"), scope, str.concat("budget envelope exhausted: ", scope), "board", "")
    let __t := tr.trail(db, company_id, "budget_escalated", str.join(["{\"scope\":\"", scope, "\",\"chain\":\"", chain_str, "\"}"], ""))
    ()
  }
}

# ── Reporting ────────────────────────────────────────────────────────────────
fn utilization_line(e :: Envelope) -> Str {
  let pct := if e.cap_cents > 0 {
    e.spent_cents * 100 / e.cap_cents
  } else {
    0
  }
  let flag := match state_of(e) {
    Exhausted => " EXHAUSTED",
    Warned(_) => " WARNING",
    Headroom => "",
  }
  str.join(["- ", e.scope, ": ", int.to_str(e.spent_cents), "c of ", int.to_str(e.cap_cents), "c (", int.to_str(pct), "%)", flag], "")
}

# Appended to the board report by main.lex (kept out of company.lex to
# avoid an import cycle — company never needs to know about envelopes).
fn report_section(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  let es := load_envelopes(db, company_id)
  if list.is_empty(es) {
    ""
  } else {
    str.join(["\nBudget envelopes (authority to spend, integer cents; hard caps refuse, never overdraft):\n", str.join(list.map(es, fn (e :: Envelope) -> Str {
      utilization_line(e)
    }), "\n")], "")
  }
}

# One-line balance for a role — what ORG3 managers see in their context.
fn remaining_line(db :: conn.ConnDb, company_id :: Str, role :: Str) -> [sql, fs_read] Str {
  match envelope_for(db, company_id, str.concat("role:", role)) {
    None => "",
    Some(e) => str.join([" [envelope role:", role, ": ", int.to_str(if e.cap_cents > e.spent_cents {
      e.cap_cents - e.spent_cents
    } else {
      0
    }), "c remaining of ", int.to_str(e.cap_cents), "c]"], ""),
  }
}

