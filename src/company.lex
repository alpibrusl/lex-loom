# company.lex — the layer above a single sprint (#53).
#
# A Company is a *persistent goal* that produces a *series of iterating looms*.
# Each iteration is one sprint (`<company>/iter-N`); the Digest→Improve spine
# carries learning between iterations, the agent pool is the company's staff,
# and the four-layer verifier (#51) keeps every iteration provable.
#
# This module owns:
#   C1 — the CompanyCfg / CompanyIteration records + their persistence.
#   C2 — a tiny grounded condition DSL (stop-when + node activate-when) evaluated
#        against an IterCtx derived from the prior iteration. Deterministic, not
#        an LLM prompt — the same philosophy as the gate DSL (gates.lex).

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.crypto" as crypto

import "std.time" as time

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

# ── C1: types ─────────────────────────────────────────────────────────────────
# The persistent mission. `stop_when` is a C2 condition (e.g. "iter ge 3");
# `max_iterations` is the hard ceiling regardless of the condition.
type CompanyCfg = { id :: Str, goal :: Str, model :: Str, max_iterations :: Int, stop_when :: Str }

# One realized iteration of a company — a sprint with lineage to its parent.
type CompanyIteration = { company_id :: Str, idx :: Int, sprint_id :: Str, parent_sprint_id :: Str, status :: Str }

# The context a condition is evaluated against, derived from the iteration that
# just finished. `last_verdict` is normalized by the runner to "passed"/"failed".
type IterCtx = { idx :: Int, last_verdict :: Str, digest_summary :: Str, accepted_count :: Int, bounced_count :: Int }

type CompanyRow = { id :: Str, goal :: Str, model :: Str, max_iterations :: Int, stop_when :: Str }

type IterRow = { idx :: Int, sprint_id :: Str, parent_sprint_id :: Str, status :: Str }

# ── C1: persistence ───────────────────────────────────────────────────────────
fn save_company(db :: conn.ConnDb, c :: CompanyCfg) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO companies (id, goal, model, max_iterations, stop_when, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", params: [PStr(c.id), PStr(c.goal), PStr(c.model), PInt(c.max_iterations), PStr(c.stop_when), PStr("active"), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_company(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[CompanyCfg] {
  let q := ormq.for_dialect({ sql: "SELECT id, goal, model, max_iterations, stop_when FROM companies WHERE id=?", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[CompanyRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some({ id: r.id, goal: r.goal, model: r.model, max_iterations: r.max_iterations, stop_when: r.stop_when }),
    },
  }
}

# Open an iteration row (status "running").
fn record_iteration(db :: conn.ConnDb, it :: CompanyIteration) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO company_iterations (company_id, idx, sprint_id, parent_sprint_id, status, started_at, ended_at) VALUES (?, ?, ?, ?, ?, ?, '')", params: [PStr(it.company_id), PInt(it.idx), PStr(it.sprint_id), PStr(it.parent_sprint_id), PStr(it.status), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Close an iteration row with a terminal status.
fn finish_iteration(db :: conn.ConnDb, company_id :: Str, idx :: Int, status :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "UPDATE company_iterations SET status=?, ended_at=? WHERE company_id=? AND idx=?", params: [PStr(status), PStr(now), PStr(company_id), PInt(idx)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_iterations(db :: conn.ConnDb, company_id :: Str) -> [sql] List[CompanyIteration] {
  let q := ormq.for_dialect({ sql: "SELECT idx, sprint_id, parent_sprint_id, status FROM company_iterations WHERE company_id=? ORDER BY idx", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IterRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: IterRow) -> CompanyIteration {
      { company_id: company_id, idx: r.idx, sprint_id: r.sprint_id, parent_sprint_id: r.parent_sprint_id, status: r.status }
    }),
  }
}

# Highest iteration index recorded so far (0 if none).
fn latest_iteration_idx(db :: conn.ConnDb, company_id :: Str) -> [sql] Int {
  list.fold(load_iterations(db, company_id), 0, fn (acc :: Int, it :: CompanyIteration) -> Int {
    if it.idx > acc {
      it.idx
    } else {
      acc
    }
  })
}

# Stable per-iteration sprint id, e.g. "acme/iter-2".
fn iteration_sprint_id(company_id :: Str, idx :: Int) -> Str {
  str.join([company_id, "/iter-", int.to_str(idx)], "")
}

fn new_company_id(prefix :: Str) -> [random] Str {
  str.join([prefix, "-", crypto.random_str_hex(6)], "")
}

# ── C3 support: derive an IterCtx + bridge learning between iterations ─────────
type CountRow = { c :: Int }

type SummaryRow = { summary_text :: Str }

type SpecCarryRow = { node_role :: Str, spec_src :: Str, reason :: Str }

# How many trail events of a kind a sprint emitted (e.g. node_accepted).
fn count_events(db :: conn.ConnDb, sprint_id :: Str, kind :: Str) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT COUNT(*) AS c FROM traces WHERE agent_id=? AND event_kind=?", params: [PStr(sprint_id), PStr(kind)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.c,
    },
  }
}

# Latest digest summary for a sprint ("" if none).
fn digest_summary(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Str {
  let q := ormq.for_dialect({ sql: "SELECT summary_text FROM digests WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[SummaryRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) {
      None => "",
      Some(r) => r.summary_text,
    },
  }
}

# Build the condition context from a finished iteration.
fn derive_ctx(db :: conn.ConnDb, sprint_id :: Str, idx :: Int, success :: Bool) -> [sql] IterCtx {
  let verdict := if success {
    "passed"
  } else {
    "failed"
  }
  { idx: idx, last_verdict: verdict, digest_summary: digest_summary(db, sprint_id), accepted_count: count_events(db, sprint_id, "node_accepted"), bounced_count: count_events(db, sprint_id, "node_bounced") }
}

# Copy a prior iteration's tightened specs onto the next iteration's sprint id,
# so its Architect loads them (the digest saves under "<id>-next"; the next
# sprint loads by its own id — this bridges the two). Returns rows carried.
fn carry_specs_forward(db :: conn.ConnDb, from_sprint :: Str, to_sprint :: Str) -> [sql, fs_write, time, random] Int {
  let q := ormq.for_dialect({ sql: "SELECT node_role, spec_src, reason FROM tightened_specs WHERE sprint_id=? ORDER BY created_at", params: [PStr(from_sprint)] }, db.dialect)
  let rows :: Result[List[SpecCarryRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => list.fold(rs, 0, fn (n :: Int, r :: SpecCarryRow) -> [sql, fs_write, time, random] Int {
      let id := crypto.random_str_hex(16)
      let now := time.now_str()
      let ins := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO tightened_specs (id, sprint_id, node_role, spec_src, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(to_sprint), PStr(r.node_role), PStr(r.spec_src), PStr(r.reason), PStr(now)] }, db.dialect)
      match sql.exec(db.handle, ins.sql, ins.params) {
        Err(_) => n,
        Ok(_) => n + 1,
      }
    }),
  }
}

# ── C2: condition DSL ─────────────────────────────────────────────────────────
# Grammar (deterministic predicate over IterCtx):
#   always | never
#   iter (lt|ge|eq) N
#   verdict-passed | verdict-failed
#   digest contains "<substr>"
#   accepted (ge|lt) N
#   bounced  (ge|lt) N
# An empty condition means "always" (back-compat for ungated nodes).
fn part_at(xs :: List[Str], i :: Int) -> Str {
  if i <= 0 {
    match list.head(xs) {
      None => "",
      Some(h) => h,
    }
  } else {
    part_at(list.tail(xs), i - 1)
  }
}

fn parse_int_or(s :: Str, default :: Int) -> Int {
  match str.to_int(s) {
    None => default,
    Some(n) => n,
  }
}

fn cmp_int(op :: Str, a :: Int, b :: Int) -> Bool {
  if op == "lt" {
    a < b
  } else {
    if op == "ge" {
      a >= b
    } else {
      if op == "eq" {
        a == b
      } else {
        false
      }
    }
  }
}

# Substring inside the first pair of double quotes, "" if none.
fn quoted_arg(c :: Str) -> Str {
  let segs := str.split(c, "\"")
  if list.len(segs) >= 2 {
    part_at(segs, 1)
  } else {
    ""
  }
}

fn eval_condition(cond :: Str, ctx :: IterCtx) -> Bool {
  let c := str.trim(cond)
  if str.is_empty(c) {
    true
  } else {
    let parts := str.split(c, " ")
    let head := part_at(parts, 0)
    if head == "always" {
      true
    } else {
      if head == "never" {
        false
      } else {
        if head == "iter" {
          cmp_int(part_at(parts, 1), ctx.idx, parse_int_or(part_at(parts, 2), 0))
        } else {
          if head == "verdict-passed" {
            ctx.last_verdict == "passed"
          } else {
            if head == "verdict-failed" {
              ctx.last_verdict == "failed"
            } else {
              if head == "digest" {
                str.contains(ctx.digest_summary, quoted_arg(c))
              } else {
                if head == "accepted" {
                  cmp_int(part_at(parts, 1), ctx.accepted_count, parse_int_or(part_at(parts, 2), 0))
                } else {
                  if head == "bounced" {
                    cmp_int(part_at(parts, 1), ctx.bounced_count, parse_int_or(part_at(parts, 2), 0))
                  } else {
                    false
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# Whether a condition is recognized & structurally valid (for graph validation).
fn is_well_formed_condition(cond :: Str) -> Bool {
  let c := str.trim(cond)
  if str.is_empty(c) {
    true
  } else {
    let parts := str.split(c, " ")
    let head := part_at(parts, 0)
    if head == "always" {
      true
    } else {
      if head == "never" {
        true
      } else {
        if head == "verdict-passed" {
          true
        } else {
          if head == "verdict-failed" {
            true
          } else {
            if head == "digest" {
              part_at(parts, 1) == "contains"
            } else {
              if head == "iter" {
                valid_cmp(part_at(parts, 1), part_at(parts, 2))
              } else {
                if head == "accepted" {
                  valid_cmp(part_at(parts, 1), part_at(parts, 2))
                } else {
                  if head == "bounced" {
                    valid_cmp(part_at(parts, 1), part_at(parts, 2))
                  } else {
                    false
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn valid_cmp(op :: Str, n :: Str) -> Bool {
  let op_ok := if op == "lt" {
    true
  } else {
    if op == "ge" {
      true
    } else {
      op == "eq"
    }
  }
  if op_ok {
    match str.to_int(n) {
      None => false,
      Some(_) => true,
    }
  } else {
    false
  }
}

