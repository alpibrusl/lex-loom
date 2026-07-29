# actuation.lex — the first auto tier, behind a circuit breaker (#118/#124, CTL6).
#
# Phase 4 of the Operate loop v1. This module is the DECISION layer only:
# given an effect contract, it answers "may this action's class execute
# right now" — Auto, Propose, Escalate, or Blocked with a structural
# reason. It never performs the remediation itself. loom has never had a
# real production-mutating executor (only read-only probes: liveness
# curl, remote docker-log tail), and per the design's own caution — "do
# not start this on the strength of plausible-looking output, only on
# the measured hit rate" — wiring a real mutating action (SSH + restart)
# is a deliberate, separately-reviewed step, not something to bolt on
# silently inside a gating pass. Until an operator wires an executor, the
# gate is inert by construction: every class starts at zero verified
# samples, `real_tier` correctly resolves to Propose (or the structural
# Escalate ceiling), and nothing this module computes can cause an
# action to run.
#
# Four hard stability constraints, all reused directly from the kernel:
#
#   - Circuit breaker + measured promotion: `lex-ctl/tier.record`/`effective`
#     folded over the REAL chronological disposition history per class
#     (`operate_ledger.class_dispositions`) — not a copy of the logic,
#     the actual kernel fold.
#   - Dwell lock + global concurrency cap: `lex-ctl/stability.can_act`,
#     fed a `DwellLock` list reconstructed from still-pending contracts
#     on the subsystem (loom has no long-lived lock table; the ledger
#     already has an ordering key, so the lock set is just a query).
#   - Precondition re-check: the state hash captured at proposal time
#     (CTL5's `propose_contract`) compared against the current one; a
#     mismatch means the world moved and the action must not execute.
#   - Oscillation tracking: `operate_ledger.oscillation_pairs` — actions
#     of the same class on the same subsystem started within 2x dwell of
#     each other, the metric the design's phase-4 acceptance criterion
#     asks the ledger to carry, independent of whether anything ever
#     actually executed.
#
# The gate is structural by construction: `decide` consults only the
# action's classification, its measured record, and content hashes — it
# never reads the incident's narrative (hypotheses, evidence text), so
# nothing ingested from a log line or an error message can widen what a
# class is permitted to do.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-ctl/src/tier" as ktier

import "lex-ctl/src/stability" as kstab

import "lex-orm/src/connection" as conn

import "./operate_ledger" as ledger

import "./sensing" as sensing

import "./effects" as eff

# ── Policy — the same numbers CTL5 exposed via class_promotion_status ───────
fn policy() -> ktier.Policy
  examples {
    policy() => { min_samples: 30, min_hit_rate_pct: 70, breaker_misses: 3 }
  }
{
  { min_samples: 30, min_hit_rate_pct: 70, breaker_misses: 3 }
}

fn global_concurrency_cap() -> Int
  examples {
    global_concurrency_cap() => 1
  }
{
  1
}

# Oscillation window: 2x the class's own dwell — the design's own
# definition ("actions reversed within 2x dwell time").
fn oscillation_window_idx(dwell_delta_idx :: Int) -> Int
  examples {
    oscillation_window_idx(2) => 4
  }
{
  dwell_delta_idx * 2
}

# ── Real ClassStats — folding the kernel's own `record` over ledger history ──
# The measured record for a class ON ONE COMPANY, built by replaying
# every verified disposition through `lex-ctl/tier.record` in the order
# the breaker actually experienced them. This is the kernel's own fold,
# not a reimplementation — `record`'s consecutive-miss counting is
# exactly what the circuit breaker consumes.
#
# Company-scoped (#134): a class key names a KIND of remediation
# ("restart"), not a specific target — company A's servers being
# reliably restartable says nothing about company B's, whose actual
# infrastructure is entirely different. Scoring by class_key alone let
# one company's failures trip the breaker (or dilute the hit rate) for
# every other company, and let a clean company reach Auto by borrowing
# another's record.
fn real_stats(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] ktier.ClassStats {
  list.fold(ledger.class_dispositions(db, company_id, class_key), ktier.empty_stats(), fn (s :: ktier.ClassStats, d :: Str) -> ktier.ClassStats {
    ktier.record(s, d == "materialised")
  })
}

# The tier a class actually operates at right now FOR ONE COMPANY:
# structural ceiling demoted by that company's own measured record and
# circuit breaker — never promoted past its ceiling, never promoted on
# another class's (or another company's) record.
fn real_tier(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] Option[ktier.Tier] {
  match eff.action_spec_by_class_key(class_key) {
    None => None,
    Some(spec) => Some(ktier.effective(eff.action_class_of(spec), real_stats(db, company_id, class_key), policy())),
  }
}

# ── Structural gate: dwell lock + global concurrency cap ─────────────────────
fn active_dwell_locks(db :: conn.ConnDb, subsystem :: Str, exclude_effect :: Str) -> [sql] List[kstab.DwellLock] {
  list.map(ledger.active_dwell_windows(db, subsystem, exclude_effect), fn (w :: ledger.WindowRow) -> kstab.DwellLock {
    { subsystem: w.subsystem, held_until_ms: w.deadline_idx }
  })
}

# Structural only: consults the dwell-lock set and the global in-flight
# count, nothing else. `lex-ctl/stability.can_act`, called unmodified.
# Both queries exclude the effect being decided on — its own
# already-persisted pending row must not count against itself.
fn structurally_clear(db :: conn.ConnDb, effect :: Str, subsystem :: Str, now_idx :: Int) -> [sql] Bool {
  kstab.can_act(active_dwell_locks(db, subsystem, effect), subsystem, now_idx, ledger.pending_count(db, effect), global_concurrency_cap())
}

# ── Precondition re-check ─────────────────────────────────────────────────────
# Has the world moved since this contract was proposed? Re-derives the
# same state hash CTL5 computed at proposal time; any mismatch — the
# signal moved, or was unobserved and is now observed, or vice versa —
# means the precondition no longer holds.
fn precondition_holds(db :: conn.ConnDb, r :: ledger.EffectFullRow) -> [sql] Bool {
  r.expected_state_hash == eff.state_hash(r.company_id, r.signal, sensing.latest_score(db, r.company_id, r.signal))
}

# ── The decision ──────────────────────────────────────────────────────────────
# `Cleared` wraps the kernel's own `ktier.Tier` rather than redeclaring
# Auto/Propose/Escalate as Decision's own variants — `ktier.Tier` and a
# sibling sum type sharing bare constructor names is exactly the
# collision fixed upstream in lex-ctl#2; this avoids reintroducing it.
type Decision = Cleared(ktier.Tier) | Blocked(Str)

fn decision_str(d :: Decision) -> Str
  examples {
    decision_str(Cleared(Auto)) => "auto",
    decision_str(Blocked("dwell_or_concurrency")) => "blocked:dwell_or_concurrency"
  }
{
  match d {
    Cleared(Auto) => "auto",
    Cleared(Propose) => "propose",
    Cleared(Escalate) => "escalate",
    Blocked(reason) => str_concat_blocked(reason),
  }
}

fn str_concat_blocked(reason :: Str) -> Str {
  str.concat("blocked:", reason)
}

# The whole gate in one call: structural ceiling + measured record +
# breaker (`real_tier`), then — only for a class whose tier is Auto —
# dwell/concurrency and the precondition hash. A `Blocked` verdict is a
# STABILITY veto layered on top of an otherwise-Auto-eligible action; it
# is not a demotion of the class itself, and it never touches the
# incident's narrative.
fn decide(db :: conn.ConnDb, effect :: Str, now_idx :: Int) -> [sql] Result[Decision, Str] {
  match ledger.effect_full(db, effect) {
    None => Err("no such effect"),
    Some(r) => match real_tier(db, r.company_id, r.class_key) {
      None => Err("no action spec for class"),
      Some(Escalate) => Ok(Cleared(Escalate)),
      Some(Propose) => Ok(Cleared(Propose)),
      Some(Auto) => if not structurally_clear(db, effect, r.subsystem, now_idx) {
        Ok(Blocked("dwell_or_concurrency"))
      } else {
        if not precondition_holds(db, r) {
          Ok(Blocked("precondition_mismatch"))
        } else {
          Ok(Cleared(Auto))
        }
      },
    },
  }
}

# ── Oscillation + escalation dossier (for the board report) ─────────────────
fn oscillation_count(db :: conn.ConnDb, class_key :: Str, dwell_delta_idx :: Int) -> [sql] Int {
  ledger.oscillation_pairs(db, class_key, oscillation_window_idx(dwell_delta_idx))
}

# The dossier a human sees for an Escalate-tier decision: what the
# incident is, what was diagnosed, on what evidence, at what confidence.
# Rendered from the ledger's own columns — no free text is synthesised.
fn dossier(db :: conn.ConnDb, incident :: Str) -> [sql] Str {
  match ledger.incident_diag(db, incident) {
    None => "(no such incident)",
    Some(d) => if str.is_empty(d.diagnosed_cause) {
      "(undiagnosed — sensing gap)"
    } else {
      str.join(["incident ", incident, ": diagnosed ", d.diagnosed_cause, " (", int.to_str(d.diagnosed_p_pct), "%), symptoms ", d.symptoms_json], "")
    },
  }
}

