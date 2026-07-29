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

import "std.io" as io

import "std.process" as proc

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.crypto" as crypto

import "std.time" as time

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "lex-trail/src/log" as tlog

import "./operate_ledger" as oledger

import "./sensing" as sensing

import "lex-agent/src/memory" as mem

# ── C1: types ─────────────────────────────────────────────────────────────────
# The persistent mission. `stop_when` is a C2 condition (e.g. "iter ge 3");
# `max_iterations` is the hard ceiling regardless of the condition.
# `pmf_when`/`maintenance_when` (C9, #62) are grounded conditions that advance
# the lifecycle stage — PMF is an oracle passing, not a calendar date.
# `wake_when` (C10, #62) is the dormancy trigger: while the company is in the
# Maintenance stage, an iteration only runs if wake_when holds against the last
# result (empty => never dormant, always iterate — back-compat).
type CompanyCfg = { id :: Str, goal :: Str, model :: Str, max_iterations :: Int, stop_when :: Str, pmf_when :: Str, maintenance_when :: Str, wake_when :: Str }

# One realized iteration of a company — a sprint with lineage to its parent.
# `goal` (#80) is the goal this iteration actually ran — kept so the strategist
# can be shown a "shipped so far" manifest and stop proposing duplicate work.
type CompanyIteration = { company_id :: Str, idx :: Int, sprint_id :: Str, parent_sprint_id :: Str, status :: Str, goal :: Str }

# The context a condition is evaluated against, derived from the iteration that
# just finished. `last_verdict` is normalized by the runner to "passed"/"failed".
type IterCtx = { idx :: Int, last_verdict :: Str, digest_summary :: Str, accepted_count :: Int, bounced_count :: Int, spend_cents :: Int }

type CompanyRow = { id :: Str, goal :: Str, model :: Str, max_iterations :: Int, stop_when :: Str, pmf_when :: Str, maintenance_when :: Str, wake_when :: Str }

type IterRow = { idx :: Int, sprint_id :: Str, parent_sprint_id :: Str, status :: Str, goal :: Str }

type ContentRow = { content :: Str }

# ── C1: persistence ───────────────────────────────────────────────────────────
# Upsert: a company is re-saved on every invocation (its mutable knobs — goal,
# conditions — may have been re-supplied), but `stage`/`status`/`created_at`
# must survive across invocations (C10, #62) so a dormant company resumes where
# it left off instead of resetting to Ideation every time it's re-run.
fn save_company(db :: conn.ConnDb, c :: CompanyCfg) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "INSERT INTO companies (id, goal, model, max_iterations, stop_when, pmf_when, maintenance_when, wake_when, status, stage, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET goal=excluded.goal, model=excluded.model, max_iterations=excluded.max_iterations, stop_when=excluded.stop_when, pmf_when=excluded.pmf_when, maintenance_when=excluded.maintenance_when, wake_when=excluded.wake_when", params: [PStr(c.id), PStr(c.goal), PStr(c.model), PInt(c.max_iterations), PStr(c.stop_when), PStr(c.pmf_when), PStr(c.maintenance_when), PStr(c.wake_when), PStr("active"), PStr("ideation"), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_company(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[CompanyCfg] {
  let q := ormq.for_dialect({ sql: "SELECT id, goal, model, max_iterations, stop_when, pmf_when, maintenance_when, wake_when FROM companies WHERE id=?", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[CompanyRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some({ id: r.id, goal: r.goal, model: r.model, max_iterations: r.max_iterations, stop_when: r.stop_when, pmf_when: r.pmf_when, maintenance_when: r.maintenance_when, wake_when: r.wake_when }),
    },
  }
}

# Open an iteration row (status "running").
fn record_iteration(db :: conn.ConnDb, it :: CompanyIteration) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO company_iterations (company_id, idx, sprint_id, parent_sprint_id, status, goal, started_at, ended_at) VALUES (?, ?, ?, ?, ?, ?, ?, '')", params: [PStr(it.company_id), PInt(it.idx), PStr(it.sprint_id), PStr(it.parent_sprint_id), PStr(it.status), PStr(it.goal), PStr(now)] }, db.dialect)
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
  let q := ormq.for_dialect({ sql: "SELECT idx, sprint_id, parent_sprint_id, status, goal FROM company_iterations WHERE company_id=? ORDER BY idx", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[IterRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: IterRow) -> CompanyIteration {
      { company_id: company_id, idx: r.idx, sprint_id: r.sprint_id, parent_sprint_id: r.parent_sprint_id, status: r.status, goal: r.goal }
    }),
  }
}

# A human-readable "what's already shipped" manifest — every SUCCESSFUL
# iteration's goal, oldest first. Fed into the strategist's prompt (#80) so it
# stops proposing/re-proposing something the company already built; a company
# with no successful iterations yet gets "(nothing shipped yet)".
fn shipped_summary(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  let lines := list.fold(load_iterations(db, company_id), [], fn (acc :: List[Str], it :: CompanyIteration) -> List[Str] {
    if it.status == "success" {
      list.concat(acc, [str.join(["- iter ", int.to_str(it.idx), ": ", it.goal], "")])
    } else {
      acc
    }
  })
  if list.is_empty(lines) {
    "(nothing shipped yet)"
  } else {
    str.join(lines, "\n")
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

# ── Cost ledger v0 (#84/#87) ──────────────────────────────────────────────────
# Nothing in loom tracks what a company actually costs to run — a real
# business would kill an unprofitable line on cost grounds alone, but nothing
# in the Strategist's or a stop_when condition's context reflects LLM spend.
# v0 is a rough proxy, not real billing data: total characters of every
# artifact a sprint produced, ÷4 as a chars-per-token estimate, × an assumed
# blended $/1K-token rate. This undercounts real spend (retries, prompts, and
# failed-node output aren't in `artifacts`) but it's cheap, requires no
# provider-side change, and is enough to give the Strategist and a
# stop_when="spend ge N" condition SOME real cost signal instead of none.
# Tracked as integer CENTS (not a Float) so it reuses the exact same
# comparator/parser machinery as `iter`/`accepted`/`bounced` below.
fn cents_per_1k_tokens() -> Int {
  30
}

fn char_estimate_iteration_cost_cents(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT COALESCE(SUM(LENGTH(content)), 0) AS c FROM artifacts WHERE sprint_id=?", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => {
        let tokens := r.c / 4
        tokens * cents_per_1k_tokens() / 1000
      },
    },
  }
}

type UsageRow = { data_json :: Str }

fn tokens_to_cents(tokens :: Int) -> Int {
  tokens * cents_per_1k_tokens() / 1000
}

# Real per-owner token usage (#94) -- sums every runner.step call's reported
# UsageDelta tagged under `owner_id` (a sprint_id, or a strategist_cost_owner
# id -- see below), via the same traces table op_grant/node_started already
# use with agent_id-as-owner. 0 iff no LLM call under this owner ever reported
# usage (either none ran yet, or every provider involved doesn't report it).
fn real_usage_tokens(db :: conn.ConnDb, owner_id :: Str) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT data_json FROM traces WHERE agent_id=? AND event_kind='llm_usage'", params: [PStr(owner_id)] }, db.dialect)
  let rows :: Result[List[UsageRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => list.fold(rs, 0, fn (acc :: Int, r :: UsageRow) -> Int {
      match jv.parse(r.data_json) {
        Err(_) => acc,
        Ok(j) => acc + json_int_field(j, "total_tokens"),
      }
    }),
  }
}

fn json_int_field(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(v)) => v,
    _ => 0,
  }
}

# Prefers real token usage (real_usage_tokens) when any runner.step call under
# this sprint reported it; falls back to the old char-count proxy for
# providers that don't report usage, so cost tracking never silently drops to
# zero just because one call in the chain used a non-reporting provider.
fn estimate_iteration_cost_cents(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Int {
  let real_tokens := real_usage_tokens(db, sprint_id)
  if real_tokens > 0 {
    tokens_to_cents(real_tokens)
  } else {
    char_estimate_iteration_cost_cents(db, sprint_id)
  }
}

# The strategist runs between iterations, outside any sprint -- tag its
# usage under a per-iteration id (not the bare company_id) so summing it is
# idempotent: calling this once per iteration never re-counts a prior
# iteration's strategist usage, the way reusing company_id directly would.
fn strategist_cost_owner(company_id :: Str, idx :: Int) -> Str {
  str.join([company_id, "-strategist-", int.to_str(idx)], "")
}

# Adds this iteration's strategist call's real cost to the company's running
# total (a no-op if the provider didn't report usage). Call exactly once per
# iteration, alongside record_iteration_cost.
fn record_strategist_cost(db :: conn.ConnDb, company_id :: Str, idx :: Int) -> [sql] Result[Int, Str] {
  let tokens := real_usage_tokens(db, strategist_cost_owner(company_id, idx))
  if tokens == 0 {
    Ok(get_company_cost_cents(db, company_id))
  } else {
    match add_company_cost_cents(db, company_id, tokens_to_cents(tokens)) {
      Err(e) => Err(e),
      Ok(_) => Ok(get_company_cost_cents(db, company_id)),
    }
  }
}

fn get_company_cost_cents(db :: conn.ConnDb, company_id :: Str) -> [sql] Int {
  let q := ormq.for_dialect({ sql: "SELECT total_cost_cents AS c FROM companies WHERE id=?", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.c,
    },
  }
}

fn add_company_cost_cents(db :: conn.ConnDb, company_id :: Str, delta_cents :: Int) -> [sql] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE companies SET total_cost_cents = total_cost_cents + ? WHERE id=?", params: [PInt(delta_cents), PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Record this iteration's estimated cost against the company's running total.
# Called regardless of success/failure — a failed iteration still cost real
# LLM calls. Returns the NEW running total so callers (derive_ctx) don't need
# a second query.
fn record_iteration_cost(db :: conn.ConnDb, company_id :: Str, sprint_id :: Str) -> [sql] Result[Int, Str] {
  let delta := estimate_iteration_cost_cents(db, sprint_id)
  match add_company_cost_cents(db, company_id, delta) {
    Err(e) => Err(e),
    Ok(_) => Ok(get_company_cost_cents(db, company_id)),
  }
}

fn format_cents(cents :: Int) -> Str {
  str.join(["$", int.to_str(cents / 100), ".", pad2(cents_mod_100(cents))], "")
}

fn cents_mod_100(cents :: Int) -> Int {
  let r := cents - cents / 100 * 100
  if r < 0 {
    0 - r
  } else {
    r
  }
}

fn pad2(n :: Int) -> Str {
  if n < 10 {
    str.concat("0", int.to_str(n))
  } else {
    int.to_str(n)
  }
}

# Build the condition context from a finished iteration.
fn derive_ctx(db :: conn.ConnDb, company_id :: Str, sprint_id :: Str, idx :: Int, success :: Bool) -> [sql] IterCtx {
  let verdict := if success {
    "passed"
  } else {
    "failed"
  }
  { idx: idx, last_verdict: verdict, digest_summary: digest_summary(db, sprint_id), accepted_count: count_events(db, sprint_id, "node_accepted"), bounced_count: count_events(db, sprint_id, "node_bounced"), spend_cents: get_company_cost_cents(db, company_id) }
}

# ── C5: cross-sprint agent memory ─────────────────────────────────────────────
# The company's staff should *remember* across iterations. After an iteration we
# persist its distilled digest lessons into agent_memory for every agent that
# ran (identified via the op_grant trail, P1). The runner already recalls an
# agent's memory into its system prompt (mem.recall_all), so the next iteration's
# agents start informed. Keyed (overwrite) so memory stays bounded to one fresh
# lesson per agent rather than growing every iteration.
type GrantAgentRow = { data_json :: Str }

type LessonRow = { lessons :: Str }

fn str_in(xs :: List[Str], s :: Str) -> Bool {
  list.fold(xs, false, fn (found :: Bool, x :: Str) -> Bool {
    if found {
      true
    } else {
      x == s
    }
  })
}

# Distinct agent ids that ran in a sprint, from its op_grant events.
fn agent_ids_for_sprint(db :: conn.ConnDb, sprint_id :: Str) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT data_json FROM traces WHERE agent_id=? AND event_kind='op_grant'", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[GrantAgentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(rs, [], fn (acc :: List[Str], row :: GrantAgentRow) -> List[Str] {
      match jv.parse(row.data_json) {
        Err(_) => acc,
        Ok(j) => {
          let a := match jv.get_field(j, "agent") {
            Some(JStr(s)) => s,
            _ => "",
          }
          if str.is_empty(a) {
            acc
          } else {
            if str_in(acc, a) {
              acc
            } else {
              list.concat(acc, [a])
            }
          }
        },
      }
    }),
  }
}

fn digest_lessons(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Str {
  let q := ormq.for_dialect({ sql: "SELECT lessons FROM digests WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[LessonRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => "",
    Ok(rs) => match list.head(rs) {
      None => "",
      Some(r) => r.lessons,
    },
  }
}

# Persist the iteration's lessons to every participating agent's memory.
# Returns how many agents were updated.
fn persist_iteration_memory(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read, fs_write, time, crypto, random] Int {
  let lessons := digest_lessons(db, sprint_id)
  if str.is_empty(str.trim(lessons)) {
    0
  } else {
    list.fold(agent_ids_for_sprint(db, sprint_id), 0, fn (n :: Int, a :: Str) -> [sql, fs_read, fs_write, time, crypto, random] Int {
      let __s := mem.store(db, a, "lesson", "company-lesson", lessons)
      n + 1
    })
  }
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

# Parse a dollars-and-cents string ("5", "5.00", "5.5", "0.30") into integer
# cents, so config stays human-friendly ("spend ge 5.00") while everything
# downstream is plain Int arithmetic. Malformed input parses as 0.
fn parse_dollars_to_cents(s :: Str) -> Int {
  let segs := str.split(str.trim(s), ".")
  let whole := parse_int_or(part_at(segs, 0), 0)
  let frac_raw := part_at(segs, 1)
  let frac := if str.len(frac_raw) == 0 {
    0
  } else {
    if str.len(frac_raw) == 1 {
      parse_int_or(frac_raw, 0) * 10
    } else {
      parse_int_or(str.slice(frac_raw, 0, 2), 0)
    }
  }
  whole * 100 + frac
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
                    if head == "spend" {
                      cmp_int(part_at(parts, 1), ctx.spend_cents, parse_dollars_to_cents(part_at(parts, 2)))
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
                    if head == "spend" {
                      valid_cmp_dollars(part_at(parts, 1), part_at(parts, 2))
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

# Same op-validity check as valid_cmp, but for a dollars string ("5.00") that
# str.to_int would reject outright — used only by "spend ge <dollars>".
fn valid_cmp_dollars(op :: Str, n :: Str) -> Bool {
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
    let segs := str.split(str.trim(n), ".")
    match str.to_int(part_at(segs, 0)) {
      None => false,
      Some(_) => true,
    }
  } else {
    false
  }
}

# ── C8: goal-evolution meta-loop (strategist) ─────────────────────────────────
# The strategist agent (the agent-first "board", roles.strategist_agent) returns
# a decision after each iteration. This is the pure parse + normalization of its
# JSON reply — the LLM call itself lives in the company runner.
type StrategistDecision = { decision :: Str, goal :: Str, reason :: Str }

fn json_str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# Board-report trail events store "iter" as a JSON NUMBER (int.to_str feeds a
# bare int into the hand-built JSON, not a quoted string) — json_str_field only
# matches JStr and silently returns "" for it. This reads either shape.
fn json_int_field_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JInt(n)) => int.to_str(n),
    Some(JStr(s)) => s,
    _ => "?",
  }
}

# Make a free-text field safe to embed in a hand-built JSON string literal.
fn json_escape(s :: Str) -> Str {
  str.replace(str.replace(str.replace(s, "\\", "/"), "\"", "'"), "\n", " ")
}

# Normalize an arbitrary decision string to one of continue|revise|add|stop.
# Anything unrecognized (incl. a parse failure) is the safe default "continue".
fn norm_decision(s :: Str) -> Str {
  let d := str.to_lower(str.trim(s))
  if d == "revise" {
    "revise"
  } else {
    if d == "stop" {
      "stop"
    } else {
      if d == "add" {
        "add"
      } else {
        "continue"
      }
    }
  }
}

# Whether a decision carries a goal payload (revise pivots to it; add queues it
# to the backlog, #75).
fn decision_needs_goal(decision :: Str) -> Bool {
  if decision == "revise" {
    true
  } else {
    decision == "add"
  }
}

# Parse the strategist's JSON reply. A revise/add with an empty goal degrades
# to continue (nothing to pivot to / nothing to queue). Unparseable -> STOP:
# an unparseable reply correlates with a degraded/failing model, and defaulting
# to "continue" re-runs the same (often already-failing) goal, thrashing into
# repeated failures until max_iterations — observed live on linksnap iters 11-12,
# ~$5 of wasted spend. "stop" is safe: it graduates the next backlog item if one
# is queued, else halts cleanly, instead of burning iterations on garbage.
# Found live (pdfx2 company run, iter-19): the Strategist returned an
# unparseable reply twice in a row late in a long run and the company
# stopped immediately -- with zero retry, unlike every other role in this
# codebase (Architect gets max_design_retries, build/qa/etc. get
# max_node_retries). A single transient glitch (the same kind the Architect
# recovered from via retry multiple times in this very run) permanently
# ended the company. This does NOT change the "stop" fallback itself (see
# the rationale above, backed by real evidence from linksnap) -- it only
# gives the model a bounded chance to recover first, exactly like every
# other role already gets.
fn strategist_reply_is_parseable(reply :: Str) -> Bool {
  match jv.parse(reply) {
    Err(_) => false,
    Ok(_) => true,
  }
}

fn parse_strategist_decision(reply :: Str) -> StrategistDecision {
  match jv.parse(reply) {
    Err(_) => { decision: "stop", goal: "", reason: "unparseable strategist reply — stopping to avoid thrashing the current goal" },
    Ok(j) => {
      let decision := norm_decision(json_str_field(j, "decision"))
      let goal := str.trim(json_str_field(j, "goal"))
      let reason := json_str_field(j, "reason")
      if decision_needs_goal(decision) {
        if str.is_empty(goal) {
          { decision: "continue", goal: "", reason: str.concat(decision, str.concat(" with no goal; kept current goal. ", reason)) }
        } else {
          { decision: decision, goal: goal, reason: reason }
        }
      } else {
        { decision: decision, goal: "", reason: reason }
      }
    },
  }
}

# ── C9: lifecycle FSM + value gates ────────────────────────────────────────────
# Explicit product-lifecycle stages, each transition guarded by a GROUNDED
# condition (the C2 DSL) — not a calendar date. "PMF" is `pmf_when` evaluating
# true against a real iteration's result, not a milestone someone declared.
#   Ideation   -> Validation : always (iteration 1 begins validating the mission)
#   Validation -> Growth     : pmf_when holds (empty pmf_when never auto-advances)
#   Growth     -> Maintenance: maintenance_when holds (empty never auto-advances)
#   any        -> Sunset     : the strategist (C8) decides "stop", or stop_when
# Maintenance and Sunset are terminal from this FSM's perspective (no more
# auto-advance) — Maintenance is where a dormant/event-triggered loom (C10)
# would live.
type LifecycleStage = Ideation | Validation | Growth | Maintenance | Sunset

fn stage_to_str(s :: LifecycleStage) -> Str {
  match s {
    Ideation => "ideation",
    Validation => "validation",
    Growth => "growth",
    Maintenance => "maintenance",
    Sunset => "sunset",
  }
}

fn stage_from_str(s :: Str) -> LifecycleStage {
  if s == "validation" {
    Validation
  } else {
    if s == "growth" {
      Growth
    } else {
      if s == "maintenance" {
        Maintenance
      } else {
        if s == "sunset" {
          Sunset
        } else {
          Ideation
        }
      }
    }
  }
}

# Pure stage transition: given the current stage and the finished iteration's
# context, what stage comes next. `sunset_now` is true when an out-of-band
# reason to sunset fired (the strategist said "stop", or stop_when held) —
# checked BEFORE the ordinary ladder so it can fire from any stage.
fn next_stage(current :: LifecycleStage, ctx :: IterCtx, cfg :: CompanyCfg, sunset_now :: Bool) -> LifecycleStage {
  if sunset_now {
    Sunset
  } else {
    match current {
      Sunset => Sunset,
      Maintenance => Maintenance,
      Growth => if str.is_empty(str.trim(cfg.maintenance_when)) {
        Growth
      } else {
        if eval_condition(cfg.maintenance_when, ctx) {
          Maintenance
        } else {
          Growth
        }
      },
      _ => if str.is_empty(str.trim(cfg.pmf_when)) {
        Validation
      } else {
        if eval_condition(cfg.pmf_when, ctx) {
          Growth
        } else {
          Validation
        }
      },
    }
  }
}

type StageRow = { stage :: Str }

fn save_stage(db :: conn.ConnDb, company_id :: Str, stage :: LifecycleStage) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE companies SET stage=? WHERE id=?", params: [PStr(stage_to_str(stage)), PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_stage(db :: conn.ConnDb, company_id :: Str) -> [sql] LifecycleStage {
  let q := ormq.for_dialect({ sql: "SELECT stage FROM companies WHERE id=?", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[StageRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => Ideation,
    Ok(rs) => match list.head(rs) {
      None => Ideation,
      Some(r) => stage_from_str(r.stage),
    },
  }
}

# ── C10: dormancy + event triggers ─────────────────────────────────────────────
# A company in Maintenance should mostly do nothing: invoked repeatedly (e.g. by
# cron), each call is a cheap check, not a sprint. Only when `wake_when` fires
# against the last iteration's grounded result does it actually run. This is
# the event-driven generalization of C4's per-node `activate_when` to the whole
# company.
fn is_dormant(stage :: LifecycleStage, wake_when :: Str, ctx :: IterCtx) -> Bool {
  if stage == Maintenance {
    if str.is_empty(str.trim(wake_when)) {
      false
    } else {
      not eval_condition(wake_when, ctx)
    }
  } else {
    false
  }
}

# Where a resumed invocation should pick up: one past the last recorded
# iteration (1 if none yet), the sprint id to chain lineage from, and the
# context of that last iteration (a default "nothing happened yet" ctx if this
# is the company's first invocation).
# `last_goal` (found bug, discovered live) is what the most recent iteration
# actually attempted — regardless of whether it succeeded. Without it, resuming
# a company always fell back to the top-level MISSION text, silently discarding
# whatever the strategist had revised the goal to (or a failed attempt that
# should be retried) and re-running an already-shipped feature from scratch.
# Empty only for a company with no iterations yet (a genuinely fresh start).
type ResumePoint = { start_idx :: Int, parent_sprint :: Str, prev_ctx :: IterCtx, last_goal :: Str }

fn last_iteration(its :: List[CompanyIteration]) -> Option[CompanyIteration] {
  list.fold(its, None, fn (acc :: Option[CompanyIteration], it :: CompanyIteration) -> Option[CompanyIteration] {
    Some(it)
  })
}

# A process kill (session teardown, a manual `kill`) leaves the last iteration
# row permanently at status='running' — it never transitions to a terminal
# status on its own. Harmless functionally (only the highest-idx row is ever
# read), but cosmetically wrong in board_report, which otherwise shows a
# company "still running" an iteration from days ago. Fix on resume, right
# where we already read that row (#84/#90 — OP6 item 3).
fn resume_point(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_write, time] ResumePoint {
  match last_iteration(load_iterations(db, company_id)) {
    None => { start_idx: 1, parent_sprint: "", prev_ctx: { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0, spend_cents: 0 }, last_goal: "" },
    Some(it) => {
      let __fix := if it.status == "running" {
        let __f := finish_iteration(db, company_id, it.idx, "interrupted")
        ()
      } else {
        ()
      }
      { start_idx: it.idx + 1, parent_sprint: it.sprint_id, prev_ctx: derive_ctx(db, company_id, it.sprint_id, it.idx, it.status == "success"), last_goal: it.goal }
    },
  }
}

# ── Backlog (#75): the company accretes features instead of only revising ────
# its current goal. The strategist's "add" decision queues a new goal here
# without interrupting the iteration in progress; its "stop" decision (C8)
# first checks for a pending item and GRADUATES to it instead of halting the
# company — this is what turns "iterate on one goal" into "grow a feature set."
type BacklogItem = { company_id :: Str, idx :: Int, goal :: Str, status :: Str }

type BacklogRow = { idx :: Int, goal :: Str, status :: Str }

# Append a new backlog entry (status "pending"). idx is one past the highest
# existing idx for this company (0 if none yet).
fn append_backlog(db :: conn.ConnDb, company_id :: Str, goal :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let next_idx := list.fold(load_backlog(db, company_id), 0, fn (acc :: Int, it :: BacklogItem) -> Int {
    if it.idx > acc {
      it.idx
    } else {
      acc
    }
  }) + 1
  let q := ormq.for_dialect({ sql: "INSERT INTO company_backlog (company_id, idx, goal, status, created_at) VALUES (?, ?, ?, 'pending', ?)", params: [PStr(company_id), PInt(next_idx), PStr(goal), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_backlog(db :: conn.ConnDb, company_id :: Str) -> [sql] List[BacklogItem] {
  let q := ormq.for_dialect({ sql: "SELECT idx, goal, status FROM company_backlog WHERE company_id=? ORDER BY idx", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[BacklogRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: BacklogRow) -> BacklogItem {
      { company_id: company_id, idx: r.idx, goal: r.goal, status: r.status }
    }),
  }
}

# The currently "active" backlog item, if any (#84/#90 — OP6 item 4:
# graduate_backlog used to advance the NEXT item to "active" without ever
# marking the PREVIOUS one "done", so a fully-shipped backlog item sat at
# "active" forever — functionally harmless (next_backlog_item only looks for
# "pending") but confusing in board_report).
fn active_backlog_item(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[BacklogItem] {
  list.fold(load_backlog(db, company_id), None, fn (acc :: Option[BacklogItem], it :: BacklogItem) -> Option[BacklogItem] {
    match acc {
      Some(_) => acc,
      None => if it.status == "active" {
        Some(it)
      } else {
        None
      },
    }
  })
}

# Earliest still-pending backlog item, if any.
fn next_backlog_item(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[BacklogItem] {
  list.fold(load_backlog(db, company_id), None, fn (acc :: Option[BacklogItem], it :: BacklogItem) -> Option[BacklogItem] {
    match acc {
      Some(_) => acc,
      None => if it.status == "pending" {
        Some(it)
      } else {
        None
      },
    }
  })
}

fn mark_backlog_status(db :: conn.ConnDb, company_id :: Str, idx :: Int, status :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE company_backlog SET status=? WHERE company_id=? AND idx=?", params: [PStr(status), PStr(company_id), PInt(idx)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── C7: portfolio — one company, N concurrent product tracks (#78) ───────────
# A track IS a company: its id is the composite "<portfolio_id>/<track_id>", so
# it gets the full FSM/backlog/dormancy/resume machinery for free — no new
# execution logic here, just the portfolio's bookkeeping of which tracks exist.
# Every track shares the SAME agent_pool/agent_memory (keyed by agent id, not
# by company/track id), so staff reputation and lessons-learned already carry
# across tracks for free — the point of a "shared pool" portfolio.
type Track = { portfolio_id :: Str, track_id :: Str, goal :: Str, status :: Str }

type TrackRow = { track_id :: Str, goal :: Str, status :: Str }

fn track_company_id(portfolio_id :: Str, track_id :: Str) -> Str {
  str.join([portfolio_id, "/", track_id], "")
}

# Idempotent: re-seeding an existing track id is a no-op (its goal/status are
# left as they are — a re-invoked portfolio doesn't reset in-progress tracks).
fn add_track(db :: conn.ConnDb, portfolio_id :: Str, track_id :: Str, goal :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := ormq.for_dialect({ sql: "INSERT OR IGNORE INTO portfolio_tracks (portfolio_id, track_id, goal, status, created_at) VALUES (?, ?, ?, 'active', ?)", params: [PStr(portfolio_id), PStr(track_id), PStr(goal), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_tracks(db :: conn.ConnDb, portfolio_id :: Str) -> [sql] List[Track] {
  let q := ormq.for_dialect({ sql: "SELECT track_id, goal, status FROM portfolio_tracks WHERE portfolio_id=? ORDER BY track_id", params: [PStr(portfolio_id)] }, db.dialect)
  let rows :: Result[List[TrackRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: TrackRow) -> Track {
      { portfolio_id: portfolio_id, track_id: r.track_id, goal: r.goal, status: r.status }
    }),
  }
}

fn active_tracks(db :: conn.ConnDb, portfolio_id :: Str) -> [sql] List[Track] {
  list.fold(load_tracks(db, portfolio_id), [], fn (acc :: List[Track], t :: Track) -> List[Track] {
    if t.status == "active" {
      list.concat(acc, [t])
    } else {
      acc
    }
  })
}

fn mark_track_status(db :: conn.ConnDb, portfolio_id :: Str, track_id :: Str, status :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE portfolio_tracks SET status=? WHERE portfolio_id=? AND track_id=?", params: [PStr(status), PStr(portfolio_id), PStr(track_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Board layer (#82): advisory reporting + notes for the human board member ──
# The company runs unattended; a human board member gets a read-only report
# (synthesized from data already in the trail — no new execution logic) and can
# leave advisory notes the strategist reads on its NEXT decision. Notes are
# one-shot (consumed after being shown once) and never block a run — if none
# exist, the company behaves exactly as it does today.
type BoardNote = { company_id :: Str, idx :: Int, note :: Str, status :: Str }

type BoardNoteRow = { idx :: Int, note :: Str, status :: Str }

fn add_board_note(db :: conn.ConnDb, company_id :: Str, note :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let next_idx := list.fold(load_board_notes(db, company_id), 0, fn (acc :: Int, n :: BoardNote) -> Int {
    if n.idx > acc {
      n.idx
    } else {
      acc
    }
  }) + 1
  let q := ormq.for_dialect({ sql: "INSERT INTO company_board_notes (company_id, idx, note, status, created_at) VALUES (?, ?, ?, 'pending', ?)", params: [PStr(company_id), PInt(next_idx), PStr(note), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn load_board_notes(db :: conn.ConnDb, company_id :: Str) -> [sql] List[BoardNote] {
  let q := ormq.for_dialect({ sql: "SELECT idx, note, status FROM company_board_notes WHERE company_id=? ORDER BY idx", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[BoardNoteRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: BoardNoteRow) -> BoardNote {
      { company_id: company_id, idx: r.idx, note: r.note, status: r.status }
    }),
  }
}

fn pending_board_notes(db :: conn.ConnDb, company_id :: Str) -> [sql] List[Str] {
  list.fold(load_board_notes(db, company_id), [], fn (acc :: List[Str], n :: BoardNote) -> List[Str] {
    if n.status == "pending" {
      list.concat(acc, [n.note])
    } else {
      acc
    }
  })
}

fn mark_board_notes_consumed(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE company_board_notes SET status='consumed' WHERE company_id=? AND status='pending'", params: [PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Board report ───────────────────────────────────────────────────────────
type TraceDataRow = { data_json :: Str }

# Most recent `limit` events of a kind for this company, chronological order.
fn recent_events(db :: conn.ConnDb, company_id :: Str, kind :: Str, limit :: Int) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT data_json FROM traces WHERE agent_id=? AND event_kind=? ORDER BY id DESC LIMIT ?", params: [PStr(company_id), PStr(kind), PInt(limit)] }, db.dialect)
  let rows :: Result[List[TraceDataRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(rs, [], fn (acc :: List[Str], r :: TraceDataRow) -> List[Str] {
      list.concat([r.data_json], acc)
    }),
  }
}

fn format_decision(data_json :: Str) -> Str {
  match jv.parse(data_json) {
    Err(_) => "",
    Ok(j) => str.join(["- iter ", json_int_field_str(j, "iter"), ": ", json_str_field(j, "decision"), " — ", json_str_field(j, "reason")], ""),
  }
}

fn format_stage_transition(data_json :: Str) -> Str {
  match jv.parse(data_json) {
    Err(_) => "",
    Ok(j) => str.join(["- iter ", json_int_field_str(j, "iter"), ": ", json_str_field(j, "from"), " -> ", json_str_field(j, "to")], ""),
  }
}

fn lines_or(lines :: List[Str], placeholder :: Str) -> Str {
  if list.is_empty(lines) {
    placeholder
  } else {
    str.join(lines, "\n")
  }
}

fn backlog_section(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  let items := load_backlog(db, company_id)
  lines_or(list.map(items, fn (it :: BacklogItem) -> Str {
    str.join(["- [", it.status, "] ", it.goal], "")
  }), "(empty)")
}

# A human-readable, read-only board update: mission, stage, what's shipped,
# what's queued, and the company's own recent reasoning — all derived from
# the trail, not a separate claim the company makes about itself.
# Find the largest artifact from this sprint's real build node(s) (role
# build/py_build) so it can be synced to the company's workspace directory.
# The largest one is picked because a dynamic-extension round re-runs build
# multiple times within one sprint, and later/bigger outputs supersede
# earlier ones.
#
# Node ids are NOT a fixed convention -- the Architect names them freely per
# sprint (e.g. "py-impl" instead of "build"), so matching by substring on the
# node_id text (the original approach) is unreliable: a real sprint (#pdfx
# iter-9, found live) silently failed to sync anything because its build
# node happened to be named "py-impl", which contains neither "build" nor
# "py_build". The graph itself (sprint_graphs.graph_json) records each
# node's actual `role`, which is the ground truth -- match against that
# first, and fall back to the old substring heuristic only if the graph
# lookup finds nothing (e.g. a malformed/missing graph row).
fn find_build_artifact(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[Str] {
  let ids := build_role_node_ids(db, sprint_id)
  if list.is_empty(ids) {
    find_build_artifact_by_name_heuristic(db, sprint_id)
  } else {
    find_build_artifact_by_ids(db, sprint_id, ids)
  }
}

type GraphRow = { graph_json :: Str }

# node_ids from the sprint's most recent recorded graph whose role is
# "build" or "py_build" -- the real build node(s), by ground truth, not a
# guess from the node_id string.
fn build_role_node_ids(db :: conn.ConnDb, sprint_id :: Str) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT graph_json FROM sprint_graphs WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => match list.head(rs) {
      None => [],
      Some(r) => match jv.parse(r.graph_json) {
        Err(_) => [],
        Ok(j) => match jv.get_field(j, "nodes") {
          Some(JList(nodes)) => list.fold(nodes, [], fn (acc :: List[Str], n :: jv.Json) -> List[Str] {
            let role := json_str_field(n, "role")
            if role == "build" {
              list.concat(acc, [json_str_field(n, "id")])
            } else {
              if role == "py_build" {
                list.concat(acc, [json_str_field(n, "id")])
              } else {
                acc
              }
            }
          }),
          _ => [],
        },
      },
    },
  }
}

fn placeholders(n :: Int) -> Str {
  str.join(list.map(list.range(0, n), fn (_i :: Int) -> Str {
    "?"
  }), ",")
}

fn find_build_artifact_by_ids(db :: conn.ConnDb, sprint_id :: Str, ids :: List[Str]) -> [sql] Option[Str] {
  let sql_text := str.join(["SELECT content FROM artifacts WHERE sprint_id=? AND node_id IN (", placeholders(list.len(ids)), ") ORDER BY length(content) DESC LIMIT 1"], "")
  let params := list.concat([PStr(sprint_id)], list.map(ids, fn (id :: Str) -> SqlParam {
    PStr(id)
  }))
  let q := ormq.for_dialect({ sql: sql_text, params: params }, db.dialect)
  let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => find_build_artifact_by_name_heuristic(db, sprint_id),
    Ok(rs) => match list.head(rs) {
      None => find_build_artifact_by_name_heuristic(db, sprint_id),
      Some(r) => Some(r.content),
    },
  }
}

# Fallback for a missing/malformed graph row: the original substring guess.
# Kept as a safety net, not the primary path -- see find_build_artifact.
fn find_build_artifact_by_name_heuristic(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[Str] {
  let q := ormq.for_dialect({ sql: "SELECT content FROM artifacts WHERE sprint_id=? AND (node_id LIKE '%py_build%' OR node_id LIKE '%build%') ORDER BY length(content) DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.content),
    },
  }
}

# ── Lex-build mission-coverage signal (found live in the pdfx company run) ────
# The pdfx mission text explicitly called for a Lex HTTP server behind an
# x402 payment gate (main.lex/payments.lex, the lex-x402-api stack path's
# pre-wired scaffold), with a Python helper shelled out to via std.proc. The
# Strategist reads that mission text every single iteration, yet across all
# 9 iterations the Architect only ever scoped py_build/py_qa/demo/scribe
# nodes for the standalone Python script -- no sprint graph, ever, contained
# a "build" (Lex) role node, and main.lex's priced endpoint stayed the
# original placeholder stub the whole time. The Strategist still declared
# "stop -- mission fully achieved". This is a real, ground-truth-checkable
# fact (unlike "did the LLM read the mission carefully") -- so give the
# Strategist an explicit, unavoidable signal instead of relying on it to
# notice this itself.
type NodeResultRow = { accepted :: Int }

fn graph_node_ids_with_exact_role(db :: conn.ConnDb, sprint_id :: Str, role :: Str) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT graph_json FROM sprint_graphs WHERE sprint_id=? ORDER BY created_at DESC LIMIT 1", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => match list.head(rs) {
      None => [],
      Some(r) => match jv.parse(r.graph_json) {
        Err(_) => [],
        Ok(j) => match jv.get_field(j, "nodes") {
          Some(JList(nodes)) => list.fold(nodes, [], fn (acc :: List[Str], n :: jv.Json) -> List[Str] {
            if json_str_field(n, "role") == role {
              list.concat(acc, [json_str_field(n, "id")])
            } else {
              acc
            }
          }),
          _ => [],
        },
      },
    },
  }
}

fn node_accepted(db :: conn.ConnDb, sprint_id :: Str, node_id :: Str) -> [sql] Bool {
  let q := ormq.for_dialect({ sql: "SELECT accepted FROM node_results WHERE sprint_id=? AND node_id=? AND accepted=1 LIMIT 1", params: [PStr(sprint_id), PStr(node_id)] }, db.dialect)
  let rows :: Result[List[NodeResultRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => false,
    Ok(rs) => if list.is_empty(rs) {
      false
    } else {
      true
    },
  }
}

# Has a Lex ("build" role, NOT py_build) node ever been accepted across ANY
# sprint this company has ever run? A ground-truth fact from sprint_graphs +
# node_results, not an LLM's self-report.
fn has_shipped_build_node(db :: conn.ConnDb, company_id :: Str) -> [sql] Bool {
  let sprint_ids := list.map(load_iterations(db, company_id), fn (it :: CompanyIteration) -> Str {
    it.sprint_id
  })
  list.fold(sprint_ids, false, fn (acc :: Bool, sid :: Str) -> [sql] Bool {
    if acc {
      true
    } else {
      let ids := graph_node_ids_with_exact_role(db, sid, "build")
      list.fold(ids, false, fn (acc2 :: Bool, nid :: Str) -> [sql] Bool {
        if acc2 {
          true
        } else {
          node_accepted(db, sid, nid)
        }
      })
    }
  })
}

# Found live (pdfx2 company run): a lifetime-ever check isn't enough. Iter-6
# shipped a real Lex build node; iter-8's Architect then quietly dropped Lex
# entirely and shipped a Flask/Python server instead (literally named
# lex_server.py, but `from flask import Flask` inside) -- and because
# has_shipped_build_node only asks "ever, across all of history", it stayed
# true and gave the Strategist no signal that the CURRENT direction had
# drifted away from Lex. The Strategist's own summary ("the minimal Lex
# server is shipped") was simply wrong as a result. What matters for a
# revise/stop decision is the MOST RECENT iteration, not lifetime history.
fn most_recent_iteration(db :: conn.ConnDb, company_id :: Str) -> [sql] Option[CompanyIteration] {
  list.head(list.reverse(load_iterations(db, company_id)))
}

fn most_recent_iteration_has_build_node(db :: conn.ConnDb, company_id :: Str) -> [sql] Bool {
  match most_recent_iteration(db, company_id) {
    None => false,
    Some(it) => {
      let ids := graph_node_ids_with_exact_role(db, it.sprint_id, "build")
      list.fold(ids, false, fn (acc :: Bool, nid :: Str) -> [sql] Bool {
        if acc {
          true
        } else {
          node_accepted(db, it.sprint_id, nid)
        }
      })
    },
  }
}

# One line, fed into the strategist prompt every iteration alongside OPERATE
# SIGNALS -- inert for companies whose mission never mentions a Lex/x402
# integration (the strategist rule that reacts to this is conditioned on the
# mission text itself), but a hard, checkable fact for companies (like the
# lex-x402-api stack path) where it does. Distinguishes "drifted away from
# Lex after shipping it once" from "never shipped it at all" -- the two
# call for different responses (bring it back vs. build it for the first
# time), and conflating them (as the old lifetime-only check did) let a
# real regression go unnoticed.
fn build_status_section(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  if most_recent_iteration_has_build_node(db, company_id) {
    "A Lex ('build' role) node was accepted in the MOST RECENT iteration -- the current direction is actively using Lex."
  } else {
    if has_shipped_build_node(db, company_id) {
      "NO Lex ('build' role) node was accepted in the MOST RECENT iteration, even though one shipped earlier in this company's history. That earlier success does NOT carry forward -- the current direction has drifted away from Lex."
    } else {
      "NO Lex ('build' role) node has EVER been accepted for this company, across every iteration so far."
    }
  }
}

# ── Company-level brand persistence (#20) ─────────────────────────────────────
# Brand identity (visual tokens + positioning/voice) drifted every iteration:
# each sprint's brand_designer/brand_strategist started from nothing, so a
# company that ran 3 iterations could ship 3 unrelated colour palettes and 3
# different voices for the "same" product. Every OTHER cross-iteration signal
# in this file (shipped_summary, tightened_specs, agent lessons) is threaded
# forward deliberately; brand was the one gap the C5 agent-memory mechanism
# didn't cover, because it only persists lessons, never a role's actual
# artifact content.
#
# Reuses mem.store/mem.recall_all exactly as C5 already does for lessons —
# runner.step already injects EVERY memory kind an agent has into its next
# prompt (build_system_prompt -> mem.to_context), so writing a "brand" kind
# entry here needs no new prompt-wiring at all; it rides the existing rail.
fn find_brand_artifacts(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Str {
  let q := ormq.for_dialect({ sql: "SELECT content FROM artifacts WHERE sprint_id=? AND node_id LIKE '%brand%' ORDER BY created_at", params: [PStr(sprint_id)] }, db.dialect)
  let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => "",
    Ok(rs) => str.join(list.map(rs, fn (r :: ContentRow) -> Str {
      r.content
    }), "\n\n"),
  }
}

# The fixed set of agent ids that read brand memory back on their next run —
# both roles that PRODUCE brand identity (so they extend it, not reinvent it)
# and content_designer, which should write copy in the SAME established voice.
fn brand_reader_agent_ids() -> List[Str] {
  ["loom-brand-designer", "loom-brand-strategist", "loom-content-designer"]
}

# Call only after a sprint SUCCEEDS (unlike lessons, which are worth keeping
# even from a failure) — a botched sprint's half-finished tokens/positioning
# are not a brand identity worth persisting over a real one from an earlier
# iteration. Overwrites (kind="brand", key="identity" is a fixed key per
# agent), so brand memory stays bounded to the latest established identity
# rather than growing every iteration the way a log would.
fn persist_brand_memory(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_write, time, crypto, random] Int {
  let brand := find_brand_artifacts(db, sprint_id)
  if str.is_empty(str.trim(brand)) {
    0
  } else {
    list.fold(brand_reader_agent_ids(), 0, fn (n :: Int, a :: Str) -> [sql, fs_write, time, crypto, random] Int {
      let __s := mem.store(db, a, "brand", "identity", brand)
      n + 1
    })
  }
}

# After a successful iteration, materialize the winning build artifact's fenced
# code blocks into ONE canonical, ever-growing directory for the company —
# in a workspace OUTSIDE the loom repo ($LOOM_WORKSPACE/<company_id>/, default
# ~/loom-companies/<company_id>/). loom is a generic tool; a company's product
# code is its OUTPUT and must never pollute the tool's own repo (earlier this
# wrote to ./projects/<id>, which accumulated random product code + stray files
# in the loom working tree). Without a single canonical dir at all, each
# iteration's build tool writes to its own throwaway scratch dir with
# self-invented filenames — no coherent source tree by the time the company
# stops (see: dataforge extraction, 2026-07-06). bash resolves LOOM_WORKSPACE
# (so $HOME/~ expand correctly and no `env` effect is needed here); the
# extract_fenced.py path stays relative to loom's cwd (the runner's working dir).
fn sync_project_dir(company_id :: Str, sprint_id :: Str, content :: Str) -> [io, proc] Result[Unit, Str] {
  let art := str.join(["/tmp/loom-project-sync-", str.replace(sprint_id, "/", "-"), "-art.txt"], "")
  let __w := io.write(art, content)
  let script := str.join(["WS=\"${LOOM_WORKSPACE:-$HOME/loom-companies}\"; DIR=\"$WS/", company_id, "\"; mkdir -p \"$DIR\" && python3 bin/extract_fenced.py '", art, "' \"$DIR\" >/dev/null 2>&1 && echo SYNC_OK"], "")
  match proc.run("bash", ["-c", script]) {
    Err(m) => Err(str.concat("project sync could not run: ", m)),
    Ok(r) => {
      let combined := str.concat(r.stdout, r.stderr)
      if str.contains(combined, "SYNC_OK") {
        Ok(())
      } else {
        Err(str.slice(combined, 0, 600))
      }
    },
  }
}

# ── Operate loop v0 (#84/#85): between-iteration liveness signal ────────────
# No signal from outside a company's own build sandbox reaches the Strategist
# today — every decision is made from internal QA verdicts and digests. This
# is the smallest possible first Operate signal: if the last successful
# iteration launched a real server (evidence: a `launch`-role artifact with
# {"ok":true,"url":...}), re-curl that same URL between iterations. The
# server is a genuinely detached `nohup` process (roles.lex's run_server), so
# it persists across iterations independent of any sprint currently running —
# this is a real external fact, not a re-run of the build.
fn find_launch_url(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[Str] {
  find_url_from_node(db, sprint_id, "%launch%")
}

# The deploy node's own {"ok":true,"url":...} artifact (#101) points at the
# real public host:port on the Hetzner server -- a genuinely meaningful
# production signal, unlike launch's localhost URL which only lives as long
# as this machine's `run_company` process does.
fn find_deploy_url(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[Str] {
  find_url_from_node(db, sprint_id, "%deploy%")
}

fn find_url_from_node(db :: conn.ConnDb, sprint_id :: Str, node_id_pattern :: Str) -> [sql] Option[Str] {
  find_field_from_node(db, sprint_id, node_id_pattern, "url")
}

# The deploy node's own container name (#101's deploy_hetzner echoes it back
# on success) -- needed to SSH in and tail THAT container's logs specifically,
# since a Hetzner host may run more than one company's deploy at once.
fn find_deploy_service_name(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[Str] {
  find_field_from_node(db, sprint_id, "%deploy%", "service_name")
}

fn find_field_from_node(db :: conn.ConnDb, sprint_id :: Str, node_id_pattern :: Str, field :: Str) -> [sql] Option[Str] {
  let q := ormq.for_dialect({ sql: "SELECT content FROM artifacts WHERE sprint_id=? AND node_id LIKE ? ORDER BY length(content) DESC LIMIT 1", params: [PStr(sprint_id), PStr(node_id_pattern)] }, db.dialect)
  let rows :: Result[List[ContentRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => match jv.parse(r.content) {
        Err(_) => None,
        Ok(j) => {
          let v := json_str_field(j, field)
          if str.is_empty(v) {
            None
          } else {
            Some(v)
          }
        },
      },
    },
  }
}

# Curl the URL with a short timeout; "up" iff the server answered at all
# (any HTTP status — even a 404 means the process is alive and listening),
# "down" iff the connection failed outright (refused, timed out).
fn check_liveness(url :: Str) -> [proc] Str {
  let script := str.join(["curl -s -o /dev/null -w '%{http_code}' --max-time 5 '", url, "' 2>/dev/null || echo CURL_FAILED"], "")
  match proc.run("bash", ["-c", script]) {
    Err(_) => "down",
    Ok(r) => if str.contains(r.stdout, "CURL_FAILED") {
      "down"
    } else {
      if str.is_empty(str.trim(r.stdout)) {
        "down"
      } else {
        "up"
      }
    },
  }
}

type LivenessReading = { status :: Str, ms :: Int }

# Parse curl's %{time_total} ("0.123456", seconds) into integer millis.
fn parse_curl_time_ms(out :: Str) -> Int
  examples {
    parse_curl_time_ms("0.123456") => 123,
    parse_curl_time_ms("1.5") => 1500,
    parse_curl_time_ms("2") => 2000,
    parse_curl_time_ms("garbage") => 0
  }
{
  let t := str.trim(out)
  let parts := str.split(t, ".")
  let sec := match list.head(parts) {
    None => 0,
    Some(whole) => match str.to_int(whole) {
      None => 0,
      Some(s) => s,
    },
  }
  let frac_ms := match list.head(list.tail(parts)) {
    None => 0,
    Some(frac) => match str.to_int(str.slice(str.concat(frac, "000"), 0, 3)) {
      None => 0,
      Some(m) => m,
    },
  }
  sec * 1000 + frac_ms
}

# Same up/down semantics as check_liveness, plus the wall-clock latency of
# the probe in millis — the numeric series the CTL3 residual baseline
# scores, which is what catches a degraded-but-still-responding server
# that the binary check is structurally blind to.
fn check_liveness_timed(url :: Str) -> [proc] LivenessReading {
  let script := str.join(["curl -s -o /dev/null -w '%{time_total}' --max-time 5 '", url, "' 2>/dev/null || echo CURL_FAILED"], "")
  match proc.run("bash", ["-c", script]) {
    Err(_) => { status: "down", ms: 0 },
    Ok(r) => if str.contains(r.stdout, "CURL_FAILED") {
      { status: "down", ms: 0 }
    } else {
      if str.is_empty(str.trim(r.stdout)) {
        { status: "down", ms: 0 }
      } else {
        { status: "up", ms: parse_curl_time_ms(r.stdout) }
      }
    },
  }
}

# SSH into the Hetzner host and grep the deployed container's last 5 minutes
# of docker logs for error-shaped lines -- a real bug often still answers
# HTTP requests (so `check_liveness`'s any-response-counts-as-up misses it
# entirely), but it does log the exception. "clean" is the honest default
# for anything that isn't actually deployed there or has nothing to say.
fn check_remote_errors(host :: Str, ssh_user :: Str, ssh_key :: Str, service_name :: Str) -> [proc] Str {
  if str.is_empty(host) {
    "clean"
  } else {
    if str.is_empty(service_name) {
      "clean"
    } else {
      let ssh_opts := str.join(["-i ", ssh_key, " -o StrictHostKeyChecking=accept-new"], "")
      let script := str.join(["ssh ", ssh_opts, " ", ssh_user, "@", host, " \"docker logs --since 5m ", service_name, " 2>&1 | grep -iE 'error|exception|traceback' | tail -5\" 2>/dev/null || true"], "")
      match proc.run("bash", ["-c", script]) {
        Err(_) => "clean",
        Ok(r) => if str.is_empty(str.trim(r.stdout)) {
          "clean"
        } else {
          str.slice(str.trim(r.stdout), 0, 500)
        },
      }
    }
  }
}

fn record_operate_signal(db :: conn.ConnDb, company_id :: Str, idx :: Int, kind :: Str, value :: Str) -> [sql, time] Result[Unit, Str] {
  let now := time.now_str()
  let id := str.join([company_id, "-", int.to_str(idx), "-", kind, "-", now], "")
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO company_operate_signals (id, company_id, idx, kind, value, observed_at) VALUES (?, ?, ?, ?, ?, ?)", params: [PStr(id), PStr(company_id), PInt(idx), PStr(kind), PStr(value), PStr(now)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# After a successful iteration whose sprint launched a real server, check
# it's still live and record the observation. Prefers the deploy node's real
# public URL over launch's localhost one (#101) -- localhost only proves the
# demo process on THIS machine is alive, not that the product is actually
# reachable by real users. Falls back to launch's URL for companies that
# haven't deployed yet (still a genuine, if weaker, signal). A no-op
# (Ok(())) for companies with neither node — e.g. a CLI tool like dataforge
# has nothing to check.
fn liveness_target(db :: conn.ConnDb, sprint_id :: Str) -> [sql] Option[{ url :: Str, source :: Str }] {
  match find_deploy_url(db, sprint_id) {
    Some(url) => Some({ url: url, source: "production" }),
    None => match find_launch_url(db, sprint_id) {
      Some(url) => Some({ url: url, source: "local demo" }),
      None => None,
    },
  }
}

fn check_and_record_liveness(db :: conn.ConnDb, company_id :: Str, idx :: Int, sprint_id :: Str) -> [env, sql, time, proc] Result[Unit, Str] {
  match liveness_target(db, sprint_id) {
    None => Ok(()),
    Some(target) => {
      let reading := check_liveness_timed(target.url)
      match record_operate_signal(db, company_id, idx, "liveness", str.join([reading.status, " (", target.source, ": ", target.url, ")"], "")) {
        Err(e) => Err(e),
        Ok(_) => {
          let __lat := if reading.status == "up" {
            record_operate_signal(db, company_id, idx, "latency_ms", int.to_str(reading.ms))
          } else {
            Ok(())
          }
          match check_and_record_errors(db, company_id, idx, sprint_id, target.source) {
            Err(e) => Err(e),
            Ok(_) => match sensing.sense_company(db, None, company_id, sensing.default_policy()) {
              Err(e) => Err(e),
              Ok(_) => Ok(()),
            },
          }
        },
      }
    },
  }
}

# Only production (real Hetzner deploy) targets have a container to log-tail
# -- local demo processes run via `nohup`, not docker, so there is nothing to
# `docker logs` for them.
fn check_and_record_errors(db :: conn.ConnDb, company_id :: Str, idx :: Int, sprint_id :: Str, source :: Str) -> [env, sql, time, proc] Result[Unit, Str] {
  if source != "production" {
    Ok(())
  } else {
    match find_deploy_service_name(db, sprint_id) {
      None => Ok(()),
      Some(service_name) => {
        let host := match env.get("HETZNER_HOST") {
          Some(v) => v,
          None => "",
        }
        let ssh_user := match env.get("HETZNER_USER") {
          Some(v) => v,
          None => "root",
        }
        let ssh_key := match env.get("HETZNER_SSH_KEY") {
          Some(v) => v,
          None => "~/.ssh/id_rsa",
        }
        let errors := check_remote_errors(host, ssh_user, ssh_key, service_name)
        match record_operate_signal(db, company_id, idx, "errors", errors) {
          Err(e) => Err(e),
          Ok(_) => record_operate_signal(db, company_id, idx, "error_count", int.to_str(error_line_count(errors))),
        }
      },
    }
  }
}

type SignalRow = { value :: Str, observed_at :: Str }

fn recent_operate_signals(db :: conn.ConnDb, company_id :: Str, kind :: Str, limit :: Int) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT value, observed_at FROM company_operate_signals WHERE company_id=? AND kind=? ORDER BY idx DESC LIMIT ?", params: [PStr(company_id), PStr(kind), PInt(limit)] }, db.dialect)
  let rows :: Result[List[SignalRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.reverse(list.map(rs, fn (r :: SignalRow) -> Str {
      str.join([r.observed_at, ": ", r.value], "")
    })),
  }
}

# Line count of an error-scan result; "clean" (or blank) counts zero.
fn error_line_count(errors :: Str) -> Int
  examples {
    error_line_count("clean") => 0,
    error_line_count("") => 0,
    error_line_count("one error line") => 1,
    error_line_count("line one\nline two") => 2
  }
{
  let t := str.trim(errors)
  if str.is_empty(t) or str.starts_with(t, "clean") {
    0
  } else {
    list.len(str.split(t, "\n"))
  }
}

# CTL7 (#118/#125): the ledger-derived numbers the Strategist reads instead
# of (or in addition to) raw incident narrative — same summarised-numbers
# pattern as the cost ledger (#94) already used in board_report below.
fn format_operate_metrics(m :: oledger.OperateMetrics, cost_cents :: Int) -> Str
  examples {
    format_operate_metrics({ open_incidents: 1, resolved_count: 2, escalated_count: 0, verified_effects: 10, hit_rate_pct: 80, hit_rate_trend: "steady (~80%)", avg_evidence_cost_milli: 500 }, 1234) => "Controller metrics — open incidents: 1, resolved: 2, escalated: 0, verified actions: 10, hit rate: 80% (steady (~80%)), avg evidence cost per closed incident: 500m, company spend so far: $12.34"
  }
{
  str.join(["Controller metrics — open incidents: ", int.to_str(m.open_incidents), ", resolved: ", int.to_str(m.resolved_count), ", escalated: ", int.to_str(m.escalated_count), ", verified actions: ", int.to_str(m.verified_effects), ", hit rate: ", int.to_str(m.hit_rate_pct), "% (", m.hit_rate_trend, "), avg evidence cost per closed incident: ", int.to_str(m.avg_evidence_cost_milli), "m, company spend so far: ", format_cents(cost_cents)], "")
}

fn operate_metrics_section(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  let m := oledger.operate_metrics(db, company_id)
  if m.open_incidents == 0 and m.resolved_count == 0 and m.escalated_count == 0 and m.verified_effects == 0 {
    "(no controller data yet for this company)"
  } else {
    format_operate_metrics(m, get_company_cost_cents(db, company_id))
  }
}

fn format_incident(i :: oledger.IncidentRow) -> Str {
  let state := if str.is_empty(i.closed_at) {
    "OPEN since "
  } else {
    str.join([i.status, " ", i.opened_at, " -> "], "")
  }
  let until := if str.is_empty(i.closed_at) {
    i.opened_at
  } else {
    i.closed_at
  }
  str.join(["- [", i.status, "] ", i.symptoms_json, " ", state, until], "")
}

# The Strategist's operate view, CTL3 shape (#121): grouped incidents from
# the operate ledger plus the single latest reading per raw series —
# volume goes DOWN versus dumping raw check history, while a live problem
# is more visible, not less.
fn operate_section(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  let latest := recent_operate_signals(db, company_id, "liveness", 1)
  let liveness_str := if list.is_empty(latest) {
    "(no launched server for this company, or no liveness checks yet)"
  } else {
    str.join(latest, "\n")
  }
  let incidents := oledger.recent_incidents(db, company_id, 3)
  let incidents_str := if list.is_empty(incidents) {
    liveness_str
  } else {
    str.join([liveness_str, "\nIncidents (operate ledger, latest 3):\n", str.join(list.map(incidents, format_incident), "\n")], "")
  }
  let metrics_str := str.join([incidents_str, "\n\n", operate_metrics_section(db, company_id)], "")
  let errors := recent_operate_signals(db, company_id, "errors", 1)
  let noisy := list.fold(errors, false, fn (acc :: Bool, line :: Str) -> Bool {
    acc or error_line_count(after_ts(line)) > 0
  })
  if noisy {
    str.join([metrics_str, "\n\nRecent error log scans (production deploys only):\n", str.join(errors, "\n")], "")
  } else {
    metrics_str
  }
}

# Populate the phase-0 replay corpus (#118/#120) from a live database's
# existing signal history: derive incident episodes (`oledger.backfill_all`)
# and, since backfilled rows never went through the between-iteration
# hook, retroactively score them (`sensing.backfill_score_all`) so CTL4's
# diagnosis and CTL5's verifier read real residuals instead of the
# unscored-column default. Idempotent; run once after deploying, and
# again any time older, never-backfilled history needs pulling in.
fn backfill_operate_corpus(db :: conn.ConnDb, log :: tlog.Log) -> [sql, time] Result[{ incidents :: Int, scored :: Int }, Str] {
  match oledger.backfill_all(db, log) {
    Err(e) => Err(str.concat("incident backfill failed: ", e)),
    Ok(n_inc) => match sensing.backfill_score_all(db, sensing.default_policy()) {
      Err(e) => Err(str.concat("score backfill failed: ", e)),
      Ok(n_scored) => Ok({ incidents: n_inc, scored: n_scored }),
    },
  }
}

# recent_operate_signals prefixes each value with "<observed_at>: " — strip
# it so error_line_count judges the recorded value, not the timestamp.
fn after_ts(line :: Str) -> Str {
  let parts := str.split(line, ": ")
  if list.len(parts) <= 1 {
    line
  } else {
    str.join(list.tail(parts), ": ")
  }
}

fn board_report(db :: conn.ConnDb, company_id :: Str) -> [sql] Str {
  match load_company(db, company_id) {
    None => str.concat("No company found with id: ", company_id),
    Some(cfg) => {
      let stage := load_stage(db, company_id)
      let its := load_iterations(db, company_id)
      let decisions := list.map(recent_events(db, company_id, "goal_decision", 5), format_decision)
      let transitions := list.map(recent_events(db, company_id, "stage_transition", 5), format_stage_transition)
      str.join(["=== Board Report: ", company_id, " ===\n", "Mission: ", cfg.goal, "\n", "Stage: ", stage_to_str(stage), "\n", "Iterations run: ", int.to_str(list.len(its)), "\n", "Estimated spend so far: ", format_cents(get_company_cost_cents(db, company_id)), " (rough proxy — not real billing data)", "\n\n", "Shipped so far:\n", shipped_summary(db, company_id), "\n\n", "Backlog:\n", backlog_section(db, company_id), "\n\n", "Recent liveness checks:\n", operate_section(db, company_id), "\n\n", "Recent decisions:\n", lines_or(decisions, "(none yet)"), "\n\n", "Recent stage transitions:\n", lines_or(transitions, "(none yet)")], "")
    },
  }
}

