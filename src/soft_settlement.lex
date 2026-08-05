# soft_settlement.lex — SA3 (lex-loom#180): evidence-gated settlement for
# one real money signal.
#
# "Money moves (or is recorded) only when soft's trail re-verifies the
# work" — this is the mechanism. `REVENUE_URL` stays the actual data source
# (it's the only place a real number comes from; nothing here invents a
# second one) — what changes is what happens to that reading once it's
# fetched: instead of trusting it at face value and storing it raw, it gets
# recorded as a hash-chained lex-trail event and immediately re-derived
# through lex-soft's `verdict.verify` against a real legality spec. A
# reading that doesn't verify is still recorded (never silently dropped —
# see check_and_record_revenue's fallback), but `board_report` can now cite
# something re-checkable, not just a bare figure nobody ever re-verifies.
#
# In-process, not over HTTP: lex-soft's settlement/verdict/ledger machinery
# is a library-level Lex API (a `Db`/`tlog.Log` in, a `Verdict` out) with no
# deployed write/verify HTTP surface today — see
# docs/design/soft-os-aware-agents.md's SA3 section for the fuller reasoning.
# `lex-soft` is a real `lex.toml` package dependency of this repo as of
# this change; the trail lives in this company's own db connection
# (`settlement.trail_on(db.handle)`), the same one loom already uses for
# everything else — no second database, no network hop, no separate soft
# deployment required to get a re-verifiable settlement event.

import "std.str" as str

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-trail/src/log" as tlog

import "lex-trail/src/kinds" as kinds

import "lex-spec/spec" as sp

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/verdict" as verdict

# The legality rule, as DATA (lex-spec's own idiom — see lex-soft's
# tests/test_verdict.lex `grant_spec()` for the pattern this mirrors): a
# claimed revenue reading must be non-negative. Real, not decorative — a
# broken or malicious REVENUE_URL returning garbage or a negative number is
# caught here, not silently trusted the way raw revenue_url polling was.
# Deliberately minimal (SA3's own scope: "proving the pattern, not rolling
# it out" — SA4 generalizes).
fn revenue_legality_spec() -> sp.Spec {
  { name: "loom.revenue.non_negative", quantifiers: [QRecord({ name: "outcome", fields: [{ name: "revenue_cents", ty: TInt }] })], predicate: EBinop({ op: sp.op_ge(), lhs: EField({ binding: "outcome", field: "revenue_cents" }), rhs: EConst(VInt(0)) }) }
}

fn revenue_binding() -> Str {
  "outcome"
}

# Records the claim as a minimal, parent-linked trail chain
# (cap.invoked -> cap.completed) — the completed event's payload is what
# verdict.verify's outcome_of binds into the legality spec, so the kind
# MUST be kinds.cap_completed() for that lookup to find it. Returns the tip
# event's content-addressed id (the trail_id), or Err if the trail write
# itself failed.
fn record_revenue_claim(log :: tlog.Log, company_id :: Str, revenue_cents :: Int, source :: Str) -> [sql, time] Result[Str, Str] {
  let invoked := jv.stringify(JObj([("company_id", JStr(company_id)), ("source", JStr(source))]))
  match tlog.append_actor(log, kinds.cap_invoked(), company_id, None, invoked) {
    Err(e) => Err(e),
    Ok(e1) => {
      let done := jv.stringify(JObj([("company_id", JStr(company_id)), ("source", JStr(source)), ("revenue_cents", JInt(revenue_cents))]))
      match tlog.append_actor(log, kinds.cap_completed(), company_id, Some(e1.id), done) {
        Err(e) => Err(e),
        Ok(e2) => Ok(e2.id),
      }
    },
  }
}

# Independently re-derive a Verdict over an already-recorded trail — walks
# the hash chain, re-hashes every event, and re-evaluates the legality spec
# against the recorded outcome. This is "soft's own evidence re-derivation"
# the promotion criterion asks for: it recomputes from the trail every time
# it's called, never trusts a stored claim.
fn verify_revenue_claim(log :: tlog.Log, trail_id :: Str) -> [sql] verdict.Verdict {
  verdict.verify(log, trail_id, Some(revenue_legality_spec()), revenue_binding())
}

type Settled = { trail_id :: Str, verdict :: verdict.Verdict }

# Record + immediately verify, in one call — the shape
# check_and_record_revenue actually needs.
fn settle_revenue(db :: conn.ConnDb, company_id :: Str, revenue_cents :: Int, source :: Str) -> [sql, time] Result[Settled, Str] {
  let log := settlement.trail_on(db.handle)
  match record_revenue_claim(log, company_id, revenue_cents, source) {
    Err(e) => Err(e),
    Ok(trail_id) => Ok({ trail_id: trail_id, verdict: verify_revenue_claim(log, trail_id) }),
  }
}

# The value stored in company_operate_signals under kind "revenue_cents"
# when settlement is enabled — carries the trail_id + verdict alongside the
# claimed number, so real_economics_section / board_report can cite
# something re-verifiable instead of a bare figure nobody ever re-checks.
fn settled_signal_json(s :: Settled, revenue_cents :: Int) -> Str {
  jv.stringify(JObj([("revenue_cents", JInt(revenue_cents)), ("trail_id", JStr(s.trail_id)), ("verified", JBool(s.verdict.verified)), ("reason", JStr(s.verdict.reason))]))
}

