# effects.lex — shadow effect contracts + counterfactual verifier (#118/#123, CTL5).
#
# Phase 3 of the Operate loop v1. SHADOW MODE: nothing executes. For each
# diagnosed incident (CTL4), this module proposes a remediation from a
# CLOSED action vocabulary — one entry per diagnosed cause — classifies
# it (reversibility × blast × dwell, `lex-ctl/tier`), and attaches a
# falsifiable EFFECT CONTRACT (`lex-ctl/contract`): a typed predicate over
# a named signal, a deadline, and the diagnosis's own confidence. A
# scheduled sweep (`verify_pending`) — never the proposer — later judges
# each contract against what the signal actually did
# (`lex-ctl/verify.judge`): materialised, falsified, or ambiguous, with
# ambiguous counting as a miss. This is the phase the design calls out as
# the real test: a contract whose predicate cannot be evaluated from
# ledger signals is unrepresentable by construction (the confabulator
# failure mode), and writing a prediction that can actually fail is
# harder than writing a plausible remediation.
#
# loom has no wall-clock scheduler yet, so the between-iteration counter
# (`idx`, already the ordering key on every operate_* row) stands in for
# the kernel's abstract "ms" clock: `deadline_ms` on the reconstructed
# contract holds an ABSOLUTE idx threshold, and callers pass the
# company's current idx as `now_idx` — exactly the shape
# `lex-ctl/verify.judge` already expects, just re-derived in loom's
# actual operational tempo instead of true milliseconds.
#
# Persistence goes through the ledger's own content-addressed rows
# (`operate_ledger.record_action`/`record_effect`, already shipped in
# CTL2) — `lex-ctl/contract.make`/`compute_id` are not called here; the
# kernel's `EffectContract`/`Predicate` record shapes and its verifier are
# what's reused, reconstructed ad hoc from the ledger row at judge time.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "lex-ctl/src/contract" as kct

import "lex-ctl/src/verify" as kverify

import "lex-ctl/src/tier" as ktier

import "./operate_ledger" as ledger

import "./sensing" as sensing

# ── The closed action vocabulary — one remediation per diagnosed cause ───────
type ActionSpec = { class_key :: Str, reversibility :: ktier.Reversibility, blast :: ktier.Blast, dwell_delta_idx :: Int, deadline_delta_idx :: Int, signal_kind :: Str, cmp :: kct.Comparator, threshold_milli :: Int, on_falsify :: kct.OnFalsify }

# `transient` has no fixed symptom kind — it reuses whichever series
# opened the incident, so `incident_symptom_kind` is only consulted then.
fn action_spec_for(cause :: Str, incident_symptom_kind :: Str) -> Option[ActionSpec]
  examples {
    action_spec_for("unknown_cause", "liveness") => None
  }
{
  if cause == "server_down" {
    Some({ class_key: "restart", reversibility: Idempotent, blast: Instance, dwell_delta_idx: 2, deadline_delta_idx: 4, signal_kind: "liveness", cmp: Below, threshold_milli: 1000, on_falsify: Rollback })
  } else {
    if cause == "degraded_latency" {
      Some({ class_key: "scale", reversibility: Compensatable, blast: Service, dwell_delta_idx: 3, deadline_delta_idx: 5, signal_kind: "latency_ms", cmp: Below, threshold_milli: 1000, on_falsify: Rollback })
    } else {
      if cause == "application_error" {
        Some({ class_key: "rollback_release", reversibility: Compensatable, blast: Service, dwell_delta_idx: 3, deadline_delta_idx: 5, signal_kind: "errors", cmp: Below, threshold_milli: 1000, on_falsify: Handoff })
      } else {
        if cause == "transient" {
          Some({ class_key: "hold", reversibility: Idempotent, blast: Instance, dwell_delta_idx: 1, deadline_delta_idx: 2, signal_kind: incident_symptom_kind, cmp: Below, threshold_milli: 1000, on_falsify: Hold })
        } else {
          None
        }
      }
    }
  }
}

# The lex-ctl action classification for a spec — structural ceiling only
# (auto/propose/escalate from the axes alone); measured promotion is
# CTL6's job.
fn action_class_of(spec :: ActionSpec) -> ktier.ActionClass {
  { key: spec.class_key, reversibility: spec.reversibility, blast: spec.blast, dwell_ms: spec.dwell_delta_idx }
}

# ── Enum <-> Str, the direction lex-ctl/contract does not provide ───────────
fn cmp_of_str(s :: Str) -> kct.Comparator {
  if s == "above" {
    Above
  } else {
    Below
  }
}

fn on_falsify_of_str(s :: Str) -> kct.OnFalsify {
  if s == "hold" {
    Hold
  } else {
    if s == "handoff" {
      Handoff
    } else {
      Rollback
    }
  }
}

fn outcome_of_str(s :: Str) -> kverify.Outcome {
  if s == "materialised" {
    Materialised
  } else {
    if s == "falsified" {
      Falsified
    } else {
      if s == "ambiguous" {
        Ambiguous
      } else {
        Pending
      }
    }
  }
}

fn str_of_outcome(o :: kverify.Outcome) -> Str
  examples {
    str_of_outcome(Materialised) => "materialised",
    str_of_outcome(Ambiguous) => "ambiguous"
  }
{
  match o {
    Pending => "pending",
    Materialised => "materialised",
    Falsified => "falsified",
    Ambiguous => "ambiguous",
  }
}

# The precondition hash (CTL6): content-addresses whatever observed
# state motivated the action, so a later re-check can tell whether the
# world moved since proposal. None (no reading yet) hashes distinctly
# from any real score, so "went from unobserved to observed" also
# counts as a state change.
fn state_hash(company_id :: Str, signal_kind :: Str, score :: Option[Int]) -> Str {
  let score_str := match score {
    None => "none",
    Some(s) => int.to_str(s),
  }
  crypto.sha256_str(str.join(["operate.state", company_id, signal_kind, score_str], "|"))
}

fn first_symptom_kind(symptoms_json :: Str) -> Str {
  if str.contains(symptoms_json, "liveness") {
    "liveness"
  } else {
    if str.contains(symptoms_json, "latency_ms") {
      "latency_ms"
    } else {
      if str.contains(symptoms_json, "errors") {
        "errors"
      } else {
        "liveness"
      }
    }
  }
}

# ── Propose ───────────────────────────────────────────────────────────────────
# Propose a shadow action + effect contract for a diagnosed incident.
# Requires a non-gap diagnosis (CTL4) — a diagnosis that ended in a
# sensing gap has no cause to remediate. `now_idx` is the company's
# current iteration counter, the window's start.
fn propose_contract(db :: conn.ConnDb, log :: Option[tlog.Log], incident :: Str, now_idx :: Int, at :: Str) -> [sql, time] Result[Str, Str] {
  match ledger.incident_diag(db, incident) {
    None => Err(str.concat("no such incident: ", incident)),
    Some(d) => if str.is_empty(d.diagnosed_cause) {
      Err("incident has not been diagnosed")
    } else {
      match action_spec_for(d.diagnosed_cause, first_symptom_kind(d.symptoms_json)) {
        None => Err(str.concat("no action spec for cause: ", d.diagnosed_cause)),
        Some(spec) => match ledger.record_action(db, incident, d.company_id, spec.class_key, d.company_id, "{}", "propose", at) {
          Err(e) => Err(e),
          Ok(action_id) => match ledger.record_effect(db, kct.make(action_id, spec.class_key, d.company_id, { signal: spec.signal_kind, cmp: spec.cmp, threshold_milli: spec.threshold_milli }, now_idx + spec.deadline_delta_idx, d.diagnosed_p_pct, spec.on_falsify), incident, at, at) {
            Err(e) => Err(e),
            Ok(effect_id) => match ledger.set_effect_window(db, effect_id, now_idx, now_idx + spec.deadline_delta_idx) {
              Err(e) => Err(e),
              Ok(_) => match ledger.set_expected_state_hash(db, effect_id, state_hash(d.company_id, spec.signal_kind, sensing.latest_score(db, d.company_id, spec.signal_kind))) {
                Err(e) => Err(e),
                Ok(_) => match ledger.emit_optional(log, fn (l :: tlog.Log) -> [sql, time] Result[Str, Str] {
                  ledger.trail_action_executed(l, action_id, incident, spec.class_key, "propose", None)
                }, ()) {
                  Err(e) => Err(e),
                  Ok(_) => ledger.emit_optional(log, fn (l :: tlog.Log) -> [sql, time] Result[Str, Str] {
                    ledger.trail_effect_contracted(l, effect_id, action_id, None)
                  }, effect_id),
                },
              },
            },
          },
        },
      }
    },
  }
}

fn propose_list(db :: conn.ConnDb, log :: Option[tlog.Log], ids :: List[Str], now_idx :: Int, at :: Str, acc :: Int) -> [sql, time] Result[Int, Str] {
  match list.head(ids) {
    None => Ok(acc),
    Some(id) => match propose_contract(db, log, id, now_idx, at) {
      Err(e) => Err(e),
      Ok(_) => propose_list(db, log, list.tail(ids), now_idx, at, acc + 1),
    },
  }
}

# Propose a contract for every one of this company's incidents that CTL4
# diagnosed a real cause for and that has no action yet
# (`operate_ledger.diagnosed_without_action`) — the automatic counterpart
# to calling `propose_contract` by hand for one incident at a time.
# Returns the number of contracts newly proposed.
fn propose_for_company(db :: conn.ConnDb, log :: Option[tlog.Log], company_id :: Str, now_idx :: Int, at :: Str) -> [sql, time] Result[Int, Str] {
  propose_list(db, log, ledger.diagnosed_without_action(db, company_id), now_idx, at, 0)
}

# ── Verify ────────────────────────────────────────────────────────────────────
# Judge one effect contract against the ledger. Idempotent: a
# non-pending disposition is returned as-is without re-judging.
fn verify_contract(db :: conn.ConnDb, log :: Option[tlog.Log], effect :: Str, now_idx :: Int, at :: Str) -> [sql, time] Result[kverify.Outcome, Str] {
  match ledger.effect_full(db, effect) {
    None => Err(str.concat("no such effect: ", effect)),
    Some(r) => if r.disposition != "pending" {
      Ok(outcome_of_str(r.disposition))
    } else {
      let c := { id: effect, action_id: r.action_id, class_key: r.class_key, subsystem: r.subsystem, predicate: { signal: r.signal, cmp: cmp_of_str(r.cmp), threshold_milli: r.threshold_milli }, deadline_ms: r.deadline_idx, confidence_pct: r.confidence_pct, on_falsify: on_falsify_of_str(r.on_falsify) }
      let observed := sensing.latest_score(db, r.company_id, r.signal)
      let concurrent := ledger.concurrent_on_subsystem(db, r.subsystem, effect, r.contracted_at_idx, r.deadline_idx)
      let outcome := kverify.judge(c, observed, now_idx, concurrent)
      if kverify.is_final(outcome) {
        match ledger.record_disposition(db, effect, str_of_outcome(outcome), at) {
          Err(e) => Err(e),
          Ok(_) => ledger.emit_optional(log, fn (l :: tlog.Log) -> [sql, time] Result[Str, Str] {
            ledger.trail_effect_disposed(l, effect, str_of_outcome(outcome), None)
          }, outcome),
        }
      } else {
        Ok(outcome)
      }
    },
  }
}

fn verify_list(db :: conn.ConnDb, log :: Option[tlog.Log], ids :: List[Str], now_idx :: Int, at :: Str, acc :: Int) -> [sql, time] Result[Int, Str] {
  match list.head(ids) {
    None => Ok(acc),
    Some(id) => match verify_contract(db, log, id, now_idx, at) {
      Err(e) => Err(e),
      Ok(o) => verify_list(db, log, list.tail(ids), now_idx, at, if kverify.is_final(o) {
        acc + 1
      } else {
        acc
      }),
    },
  }
}

# The scheduled sweep: judge every pending contract, in a company- and
# subsystem-agnostic pass (contract windows are already scoped per
# subsystem). Returns the number newly disposed (materialised, falsified
# or ambiguous) this round — everything else is still Pending.
fn verify_pending(db :: conn.ConnDb, log :: Option[tlog.Log], now_idx :: Int, at :: Str) -> [sql, time] Result[Int, Str] {
  verify_list(db, log, ledger.pending_effects(db), now_idx, at, 0)
}

# ── Promotion status — the CTL6 gate check ───────────────────────────────────
type PromotionStatus = { class_key :: Str, samples :: Int, hit_rate_pct :: Int, ceiling :: ktier.Tier, promotable :: Bool }

# Every class key the registry above knows about — the set
# `actuation.record_all_tier_transitions` walks each sweep. Named once
# here so it can't drift out of sync with `action_spec_by_class_key`.
fn known_class_keys() -> List[Str]
  examples {
    known_class_keys() => ["restart", "scale", "rollback_release", "hold"]
  }
{
  ["restart", "scale", "rollback_release", "hold"]
}

fn action_spec_by_class_key(class_key :: Str) -> Option[ActionSpec] {
  if class_key == "restart" {
    action_spec_for("server_down", "")
  } else {
    if class_key == "scale" {
      action_spec_for("degraded_latency", "")
    } else {
      if class_key == "rollback_release" {
        action_spec_for("application_error", "")
      } else {
        if class_key == "hold" {
          action_spec_for("transient", "liveness")
        } else {
          None
        }
      }
    }
  }
}

# Samples ≥ 30 and hit rate ≥ 70% — the phase-3 promotion criterion for
# starting CTL6 on that class, for ONE company (#134 — the measured
# record must not cross company boundaries: company A's servers being
# reliably restartable says nothing about company B's). Ceiling comes
# from the classification alone (lex-ctl/tier.ceiling); a class whose
# ceiling is Escalate can meet the numeric bar and still never be
# `promotable` for Auto, since CTL6 only ever arms a class whose
# ceiling reaches Auto.
fn class_promotion_status(db :: conn.ConnDb, company_id :: Str, class_key :: Str) -> [sql] PromotionStatus {
  let samples := ledger.class_sample_count(db, company_id, class_key)
  let hit_rate := ledger.class_hit_rate_pct(db, company_id, class_key)
  let ceiling := match action_spec_by_class_key(class_key) {
    None => Escalate,
    Some(spec) => ktier.ceiling(action_class_of(spec)),
  }
  { class_key: class_key, samples: samples, hit_rate_pct: hit_rate, ceiling: ceiling, promotable: samples >= 30 and hit_rate >= 70 and ceiling == Auto }
}

