# diagnosis.lex — shadow diagnosis (#118/#122, CTL4).
#
# Phase 2 of the Operate loop v1: incidents get explicit hypotheses with
# NUMERIC posteriors — a wrong diagnosis is measurable, never deniable.
# Per the design's stack choice, this is plain Bayes over a hand-built
# cause × symptom likelihood matrix (integer percent throughout); a
# learned model is premature until the corpus has volume.
#
# SHADOW MODE: no actions, no production writes. The diagnoser only reads
# the ledger, spends the incident's evidence budget (each probe is an
# operate_evidence row — refused past the cap), and persists its verdict
# columns. Budget exhaustion without confidence is recorded as a SENSING
# GAP — a defect of the sensing layer, not of the diagnoser — and is the
# CTL3 backlog's highest-value input.
#
# First real lex-ctl consumption in loom: the hypothesis type and the
# top/confident helpers come from the kernel (lex-ctl/src/incident), per
# the kernel/host split — loom supplies the causes, the tools, their
# costs and the matrix; the kernel supplies the mechanism types.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-trail/src/log" as tlog

import "lex-ctl/src/incident" as kinc

import "./operate_ledger" as ledger

# ── The closed hypothesis space ───────────────────────────────────────────────
fn causes() -> List[Str]
  examples {
    causes() => ["server_down", "degraded_latency", "application_error", "transient"]
  }
{
  ["server_down", "degraded_latency", "application_error", "transient"]
}

fn uniform_prior() -> List[kinc.Hypothesis]
  examples {
    uniform_prior() => [{ cause: "server_down", p_pct: 25, evidence_for: [], evidence_against: [] }, { cause: "degraded_latency", p_pct: 25, evidence_for: [], evidence_against: [] }, { cause: "application_error", p_pct: 25, evidence_for: [], evidence_against: [] }, { cause: "transient", p_pct: 25, evidence_for: [], evidence_against: [] }]
  }
{
  list.map(causes(), fn (c :: Str) -> kinc.Hypothesis {
    { cause: c, p_pct: 25, evidence_for: [], evidence_against: [] }
  })
}

# ── The closed evidence-tool set ──────────────────────────────────────────────
#
# Each tool reads only ledger rows linked to the incident, costs a fixed
# amount of the incident's budget, and yields a binary outcome. The order
# is a hand-assigned value-of-information ranking: cheap discriminators
# first, the expensive log scan last.
type Tool = { name :: Str, cost_milli :: Int }

fn tools() -> List[Tool]
  examples {
    tools() => [{ name: "liveness_reading", cost_milli: 100 }, { name: "latency_residual", cost_milli: 100 }, { name: "recovery_check", cost_milli: 100 }, { name: "error_scan", cost_milli: 300 }]
  }
{
  [{ name: "liveness_reading", cost_milli: 100 }, { name: "latency_residual", cost_milli: 100 }, { name: "recovery_check", cost_milli: 100 }, { name: "error_scan", cost_milli: 300 }]
}

# p(outcome | cause), integer percent — the hand-built discrimination
# matrix. Only the "positive" outcome is tabulated; the complement is
# 100 - p. A coarse matrix beats nothing by a wide margin at this scale.
fn likelihood(cause :: Str, tool_name :: Str, positive :: Bool) -> Int
  examples {
    likelihood("server_down", "liveness_reading", true) => 95,
    likelihood("transient", "recovery_check", true) => 90,
    likelihood("degraded_latency", "latency_residual", true) => 95,
    likelihood("application_error", "error_scan", true) => 95,
    likelihood("server_down", "liveness_reading", false) => 5
  }
{
  let pos := if tool_name == "liveness_reading" {
    if cause == "server_down" {
      95
    } else {
      if cause == "degraded_latency" {
        15
      } else {
        if cause == "application_error" {
          40
        } else {
          70
        }
      }
    }
  } else {
    if tool_name == "latency_residual" {
      if cause == "server_down" {
        30
      } else {
        if cause == "degraded_latency" {
          95
        } else {
          if cause == "application_error" {
            50
          } else {
            40
          }
        }
      }
    } else {
      if tool_name == "error_scan" {
        if cause == "server_down" {
          30
        } else {
          if cause == "degraded_latency" {
            30
          } else {
            if cause == "application_error" {
              95
            } else {
              20
            }
          }
        }
      } else {
        if cause == "server_down" {
          20
        } else {
          if cause == "degraded_latency" {
            30
          } else {
            if cause == "application_error" {
              25
            } else {
              90
            }
          }
        }
      }
    }
  }
  if positive {
    pos
  } else {
    100 - pos
  }
}

# ── Integer Bayes ─────────────────────────────────────────────────────────────
fn sum_p(hs :: List[kinc.Hypothesis]) -> Int
  examples {
    sum_p(uniform_prior()) => 100
  }
{
  list.fold(hs, 0, fn (n :: Int, h :: kinc.Hypothesis) -> Int {
    n + h.p_pct
  })
}

# Renormalise posteriors to sum 100, giving the rounding remainder to the
# current leader so `confident` sees an honest total.
fn normalize(hs :: List[kinc.Hypothesis]) -> List[kinc.Hypothesis] {
  let total := sum_p(hs)
  if total == 0 {
    uniform_prior()
  } else {
    let scaled := list.map(hs, fn (h :: kinc.Hypothesis) -> kinc.Hypothesis {
      { cause: h.cause, p_pct: h.p_pct * 100 / total, evidence_for: h.evidence_for, evidence_against: h.evidence_against }
    })
    let rem := 100 - sum_p(scaled)
    match kinc.top_hypothesis(scaled) {
      None => scaled,
      Some(top) => list.map(scaled, fn (h :: kinc.Hypothesis) -> kinc.Hypothesis {
        if h.cause == top.cause {
          { cause: h.cause, p_pct: h.p_pct + rem, evidence_for: h.evidence_for, evidence_against: h.evidence_against }
        } else {
          h
        }
      }),
    }
  }
}

# One Bayes update: posterior ∝ prior × likelihood, with the evidence id
# filed for or against each hypothesis by whether the observed outcome
# supports it.
fn apply_evidence(hs :: List[kinc.Hypothesis], tool_name :: Str, positive :: Bool, evidence_id :: Str) -> List[kinc.Hypothesis] {
  normalize(list.map(hs, fn (h :: kinc.Hypothesis) -> kinc.Hypothesis {
    let w := likelihood(h.cause, tool_name, positive)
    if w >= 50 {
      { cause: h.cause, p_pct: h.p_pct * w, evidence_for: list.concat(h.evidence_for, [evidence_id]), evidence_against: h.evidence_against }
    } else {
      { cause: h.cause, p_pct: h.p_pct * w, evidence_for: h.evidence_for, evidence_against: list.concat(h.evidence_against, [evidence_id]) }
    }
  }))
}

# ── Tool outcomes from the ledger ─────────────────────────────────────────────
type SigRow = { kind :: Str, value :: Str, score_milli :: Int }

fn linked_signals(db :: conn.ConnDb, incident :: Str) -> [sql] List[SigRow] {
  let q := ormq.for_dialect({ sql: "SELECT kind, value, score_milli FROM company_operate_signals WHERE incident_id=? ORDER BY idx ASC", params: [PStr(incident)] }, db.dialect)
  let rows :: Result[List[SigRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# The binary outcome each tool observes for this incident.
fn outcome(db :: conn.ConnDb, incident :: Str, tool_name :: Str) -> [sql] Bool {
  let sigs := linked_signals(db, incident)
  if tool_name == "liveness_reading" {
    list.fold(sigs, false, fn (acc :: Bool, s :: SigRow) -> Bool {
      acc or s.kind == "liveness" and not ledger.is_healthy("liveness", s.value)
    })
  } else {
    if tool_name == "latency_residual" {
      list.fold(sigs, false, fn (acc :: Bool, s :: SigRow) -> Bool {
        acc or s.kind == "latency_ms" and (s.score_milli >= 3000 or s.score_milli <= 0 - 3000)
      })
    } else {
      if tool_name == "error_scan" {
        list.fold(sigs, false, fn (acc :: Bool, s :: SigRow) -> Bool {
          acc or s.kind == "errors" and not ledger.is_healthy("errors", s.value)
        })
      } else {
        list.len(sigs) <= 1
      }
    }
  }
}

fn outcome_str(positive :: Bool) -> Str
  examples {
    outcome_str(true) => "positive",
    outcome_str(false) => "negative"
  }
{
  if positive {
    "positive"
  } else {
    "negative"
  }
}

# ── The shadow diagnosis loop ─────────────────────────────────────────────────
type Diagnosis = { cause :: Str, p_pct :: Int, gap :: Bool }

fn hyps_json(hs :: List[kinc.Hypothesis]) -> Str {
  str.join(["[", str.join(list.map(hs, fn (h :: kinc.Hypothesis) -> Str {
    str.join(["{\"cause\":\"", h.cause, "\",\"p_pct\":", int.to_str(h.p_pct), "}"], "")
  }), ","), "]"], "")
}

fn persist(db :: conn.ConnDb, incident :: Str, hs :: List[kinc.Hypothesis], gap :: Bool) -> [sql] Result[Diagnosis, Str] {
  let top := match kinc.top_hypothesis(hs) {
    None => { cause: "", p_pct: 0, evidence_for: [], evidence_against: [] },
    Some(h) => h,
  }
  let q := ormq.for_dialect({ sql: "UPDATE operate_incidents SET hypotheses_json=?, diagnosed_cause=?, diagnosed_p_pct=?, diagnosis_gap=? WHERE id=?", params: [PStr(hyps_json(hs)), PStr(top.cause), PInt(top.p_pct), PInt(if gap {
    1
  } else {
    0
  }), PStr(incident)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok({ cause: top.cause, p_pct: top.p_pct, gap: gap }),
  }
}

fn trail_diagnosis(log :: tlog.Log, incident :: Str, d :: Diagnosis, parent :: Option[Str]) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, "loom.operate.diagnosis", parent, str.join(["{\"incident_id\":\"", incident, "\",\"cause\":\"", d.cause, "\",\"p_pct\":", int.to_str(d.p_pct), ",\"gap\":", if d.gap {
    "true"
  } else {
    "false"
  }, "}"], "")) {
    Err(e) => Err(e),
    Ok(evt) => Ok(evt.id),
  }
}

fn run_tools(db :: conn.ConnDb, log :: Option[tlog.Log], incident :: Str, ts :: List[Tool], hs :: List[kinc.Hypothesis], p_star_pct :: Int, at :: Str) -> [sql, time] Result[{ hs :: List[kinc.Hypothesis], gap :: Bool }, Str] {
  if kinc.confident(hs, p_star_pct) {
    Ok({ hs: hs, gap: false })
  } else {
    match list.head(ts) {
      None => Ok({ hs: hs, gap: not kinc.confident(hs, p_star_pct) }),
      Some(t) => {
        let positive := outcome(db, incident, t.name)
        let probe := str.join([t.name, "=", outcome_str(positive)], "")
        match ledger.record_evidence(db, incident, probe, t.cost_milli, probe, at) {
          Err(_) => Ok({ hs: hs, gap: true }),
          Ok(ev_id) => {
            let __trail := match log {
              None => Ok(""),
              Some(l) => ledger.trail_evidence_recorded(l, ev_id, incident, None),
            }
            run_tools(db, log, incident, list.tail(ts), apply_evidence(hs, t.name, positive, ev_id), p_star_pct, at)
          },
        }
      },
    }
  }
}

# Shadow-diagnose one incident: run the tool ladder under the evidence
# budget until confident or dry, persist the posterior + verdict, emit
# the trail event when a log is supplied. `grant_cap_milli` gives
# budget-less (backfilled) episodes a cap first — historical incidents
# predate budgets.
fn diagnose(db :: conn.ConnDb, log :: Option[tlog.Log], incident :: Str, p_star_pct :: Int, grant_cap_milli :: Int, at :: Str) -> [sql, time] Result[Diagnosis, Str] {
  match ledger.ensure_budget_cap(db, incident, grant_cap_milli) {
    Err(e) => Err(e),
    Ok(_) => match run_tools(db, log, incident, tools(), uniform_prior(), p_star_pct, at) {
      Err(e) => Err(e),
      Ok(r) => match persist(db, incident, r.hs, r.gap) {
        Err(e) => Err(e),
        Ok(d) => match log {
          None => Ok(d),
          Some(l) => match trail_diagnosis(l, incident, d, None) {
            Err(e) => Err(e),
            Ok(_) => Ok(d),
          },
        },
      },
    },
  }
}

type IdRow = { id :: Str }

fn undiagnosed(db :: conn.ConnDb) -> [sql] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT id FROM operate_incidents WHERE diagnosed_cause='' ORDER BY opened_at ASC", params: [] }, db.dialect)
  let rows :: Result[List[IdRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: IdRow) -> Str {
      r.id
    }),
  }
}

fn diagnose_list(db :: conn.ConnDb, log :: Option[tlog.Log], ids :: List[Str], p_star_pct :: Int, grant_cap_milli :: Int, at :: Str, acc :: Int) -> [sql, time] Result[Int, Str] {
  match list.head(ids) {
    None => Ok(acc),
    Some(id) => match diagnose(db, log, id, p_star_pct, grant_cap_milli, at) {
      Err(e) => Err(e),
      Ok(_) => diagnose_list(db, log, list.tail(ids), p_star_pct, grant_cap_milli, at, acc + 1),
    },
  }
}

# Diagnose every not-yet-diagnosed incident (the whole replay corpus, or
# whatever sensing has opened since). Returns the number diagnosed.
fn diagnose_all(db :: conn.ConnDb, log :: Option[tlog.Log], p_star_pct :: Int, grant_cap_milli :: Int, at :: Str) -> [sql, time] Result[Int, Str] {
  diagnose_list(db, log, undiagnosed(db), p_star_pct, grant_cap_milli, at, 0)
}

# ── Scoring against the labeled corpus ────────────────────────────────────────
type Score = { labeled :: Int, correct :: Int, top1_pct :: Int }

type LabeledRow = { root_cause :: Str, diagnosed_cause :: Str, diagnosed_p_pct :: Int }

fn labeled_rows(db :: conn.ConnDb) -> [sql] List[LabeledRow] {
  let q := ormq.for_dialect({ sql: "SELECT root_cause, diagnosed_cause, diagnosed_p_pct FROM operate_incidents WHERE root_cause!='' AND diagnosed_cause!=''", params: [] }, db.dialect)
  let rows :: Result[List[LabeledRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# Top-1 accuracy over labeled incidents — the phase-2 promotion gate
# (>= 60% to start CTL5).
fn score_corpus(db :: conn.ConnDb) -> [sql] Score {
  let rows := labeled_rows(db)
  let labeled := list.len(rows)
  let correct := list.fold(rows, 0, fn (n :: Int, r :: LabeledRow) -> Int {
    if r.root_cause == r.diagnosed_cause {
      n + 1
    } else {
      n
    }
  })
  { labeled: labeled, correct: correct, top1_pct: if labeled == 0 {
    0
  } else {
    correct * 100 / labeled
  } }
}

# Calibration: bucket stated confidence into decades and report observed
# accuracy per bucket. Miscalibration here poisons the tier gate, which
# consumes these numbers — gross miscalibration blocks CTL5.
type CalBin = { lo :: Int, n :: Int, correct :: Int }

fn calibration(db :: conn.ConnDb) -> [sql] List[CalBin] {
  let rows := labeled_rows(db)
  list.map([0, 10, 20, 30, 40, 50, 60, 70, 80, 90], fn (lo :: Int) -> CalBin {
    list.fold(rows, { lo: lo, n: 0, correct: 0 }, fn (b :: CalBin, r :: LabeledRow) -> CalBin {
      let in_bin := r.diagnosed_p_pct >= lo and (r.diagnosed_p_pct < lo + 10 or lo == 90)
      if in_bin {
        { lo: b.lo, n: b.n + 1, correct: if r.root_cause == r.diagnosed_cause {
          b.correct + 1
        } else {
          b.correct
        } }
      } else {
        b
      }
    })
  })
}

