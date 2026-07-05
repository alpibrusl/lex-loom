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

import "lex-schema/json_value" as jv

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
type IterCtx = { idx :: Int, last_verdict :: Str, digest_summary :: Str, accepted_count :: Int, bounced_count :: Int }

type CompanyRow = { id :: Str, goal :: Str, model :: Str, max_iterations :: Int, stop_when :: Str, pmf_when :: Str, maintenance_when :: Str, wake_when :: Str }

type IterRow = { idx :: Int, sprint_id :: Str, parent_sprint_id :: Str, status :: Str, goal :: Str }

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

# Build the condition context from a finished iteration.
fn derive_ctx(db :: conn.ConnDb, sprint_id :: Str, idx :: Int, success :: Bool) -> [sql] IterCtx {
  let verdict := if success {
    "passed"
  } else {
    "failed"
  }
  { idx: idx, last_verdict: verdict, digest_summary: digest_summary(db, sprint_id), accepted_count: count_events(db, sprint_id, "node_accepted"), bounced_count: count_events(db, sprint_id, "node_bounced") }
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
# to continue (nothing to pivot to / nothing to queue). Unparseable -> continue.
fn parse_strategist_decision(reply :: Str) -> StrategistDecision {
  match jv.parse(reply) {
    Err(_) => { decision: "continue", goal: "", reason: "unparseable strategist reply" },
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
type ResumePoint = { start_idx :: Int, parent_sprint :: Str, prev_ctx :: IterCtx }

fn last_iteration(its :: List[CompanyIteration]) -> Option[CompanyIteration] {
  list.fold(its, None, fn (acc :: Option[CompanyIteration], it :: CompanyIteration) -> Option[CompanyIteration] {
    Some(it)
  })
}

fn resume_point(db :: conn.ConnDb, company_id :: Str) -> [sql] ResumePoint {
  match last_iteration(load_iterations(db, company_id)) {
    None => { start_idx: 1, parent_sprint: "", prev_ctx: { idx: 1, last_verdict: "", digest_summary: "", accepted_count: 0, bounced_count: 0 } },
    Some(it) => { start_idx: it.idx + 1, parent_sprint: it.sprint_id, prev_ctx: derive_ctx(db, it.sprint_id, it.idx, it.status == "success") },
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

