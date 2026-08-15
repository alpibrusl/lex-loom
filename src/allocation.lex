# allocation.lex — GOV3 (lex-loom#223): the allocation loop — the company
# proposes budget allocations from revenue, the board approves.
#
# Before this, revenue closed an INFORMATION loop only: verified readings
# reached the Strategist's prompt, but nothing connected money coming in to
# how the company spends — envelopes (GOV2) were set once by a human. The
# allocation loop closes that, without ever letting the company move its
# own money:
#
#   1. HEARTBEAT CADENCE, MECHANICAL GATE. The finance side is consulted on
#      the scheduler heartbeat, and only when there is something to allocate
#      over: declared envelopes AND a settlement-verified revenue reading.
#      Hysteresis: at most one proposal per iteration index, never while
#      one is pending before the board.
#   2. STRICT PROPOSALS WITH A FALSIFIABLE PREDICTION. The proposal must be
#      EXACTLY one JSON object; every change targets a valid envelope scope
#      with positive integer cents; and the proposal carries a prediction —
#      "this allocation should produce verified revenue >= X by iteration
#      K" — following #118's effect-contract discipline. Unparseable, or a
#      structurally invalid change set, is refused (trailed) and changes
#      nothing.
#   3. BOARD DECISIONS ONLY. A proposal parks in the attention queue
#      (oracle "board", evidence attached). The ONLY code path that changes
#      envelopes from a proposal is apply_resolved reading an APPROVED
#      attention row — the envelope update runs as the board member who
#      approved it (budget.set_envelope's actor), so the GOV2 trail shows
#      who authorized every cap. Rejected → current envelopes stand,
#      disposition ledgered.
#   4. GRADED. When the next proposal is considered, the last applied
#      proposal's prediction is graded against the CURRENT verified revenue
#      (hit/miss, trailed, stored on the allocation row), and the company's
#      allocation hit rate is part of the evidence the finance agent and
#      the board both see.
#
# The invariant stays absolute: loom never moves real money. Allocation
# governs INTERNAL spend authority (LLM/tool cost envelopes); real-world
# payments remain outside the box (#89).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "lex-trail/src/log" as tlog

import "./graph" as graph

import "./cast" as cast

import "./orchestrator" as orch

import "./transport" as tr

import "./budget" as budget

import "./company" as company

fn alloc_sprint(company_id :: Str) -> Str {
  str.concat(company_id, "/allocation")
}

# ── Model ────────────────────────────────────────────────────────────────────
type Change = { scope :: Str, cap_cents :: Int }

type Proposal = { kind :: Str, changes :: List[Change], rationale :: Str, target_cents :: Int, by_iteration :: Int }

type AllocationRow = { id :: Str, status :: Str, changes_json :: Str, rationale :: Str, predicted_target_cents :: Int, predicted_by_iter :: Int, attention_id :: Str, proposed_at_iter :: Int, grade :: Str }

# ── Strict proposal parsing ──────────────────────────────────────────────────
# The whole (trimmed) output must be one JSON object:
#   {"allocation": "none"}
#   {"allocation": "revise", "changes": [{"scope": "role:build", "cap_cents": 2000}, ...],
#    "rationale": "...", "prediction": {"target_cents": 500, "by_iteration": 6}}
# A revise with no valid changes, an invalid scope, non-positive cents, or a
# missing/empty prediction is refused outright — a spend-authority change
# gets no prose fallback and no unfalsifiable form.
fn parse_changes(j :: jv.Json) -> Option[List[Change]] {
  match jv.get_field(j, "changes") {
    Some(JList(items)) => list.fold(items, Some([]), fn (acc :: Option[List[Change]], item :: jv.Json) -> Option[List[Change]] {
      match acc {
        None => None,
        Some(seen) => {
          let scope := match jv.get_field(item, "scope") {
            Some(JStr(s)) => s,
            _ => "",
          }
          let cents := match jv.get_field(item, "cap_cents") {
            Some(JInt(c)) => c,
            _ => 0,
          }
          if budget.valid_scope(scope) and cents > 0 {
            Some(list.concat(seen, [{ scope: scope, cap_cents: cents }]))
          } else {
            None
          }
        },
      }
    }),
    _ => None,
  }
}

fn parse_proposal(output :: Str) -> Option[Proposal] {
  match jv.parse(str.trim(output)) {
    Err(_) => None,
    Ok(j) => match jv.get_field(j, "allocation") {
      Some(JStr(k)) => if k == "none" {
        Some({ kind: "none", changes: [], rationale: "", target_cents: 0, by_iteration: 0 })
      } else {
        if k == "revise" {
          let rationale := match jv.get_field(j, "rationale") {
            Some(JStr(r)) => r,
            _ => "",
          }
          let prediction := jv.get_field(j, "prediction")
          let target := match prediction {
            Some(p) => match jv.get_field(p, "target_cents") {
              Some(JInt(t)) => t,
              _ => 0,
            },
            None => 0,
          }
          let by_iter := match prediction {
            Some(p) => match jv.get_field(p, "by_iteration") {
              Some(JInt(b)) => b,
              _ => 0,
            },
            None => 0,
          }
          match parse_changes(j) {
            None => None,
            Some(cs) => if list.is_empty(cs) or target <= 0 or by_iter <= 0 {
              None
            } else {
              Some({ kind: "revise", changes: cs, rationale: rationale, target_cents: target, by_iteration: by_iter })
            },
          }
        } else {
          None
        }
      },
      _ => None,
    },
  }
}

# ── Ledger ───────────────────────────────────────────────────────────────────
fn alloc_columns() -> Str {
  "id, status, changes_json, rationale, predicted_target_cents, predicted_by_iter, attention_id, proposed_at_iter, grade"
}

fn load_allocations(db :: conn.ConnDb, company_id :: Str, status :: Str) -> [sql, fs_read] List[AllocationRow] {
  let q := ormq.for_dialect({ sql: str.join(["SELECT ", alloc_columns(), " FROM allocations WHERE company_id=? AND status=? ORDER BY created_at ASC"], ""), params: [PStr(company_id), PStr(status)] }, db.dialect)
  let rows :: Result[List[AllocationRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn changes_json(cs :: List[Change]) -> Str {
  jv.stringify(JList(list.map(cs, fn (c :: Change) -> jv.Json {
    JObj([("scope", JStr(c.scope)), ("cap_cents", JInt(c.cap_cents))])
  })))
}

fn set_alloc_status(db :: conn.ConnDb, id :: Str, status :: Str) -> [sql, fs_write, time] Unit {
  let q := ormq.for_dialect({ sql: "UPDATE allocations SET status=?, updated_at=? WHERE id=?", params: [PStr(status), PStr(time.now_str()), PStr(id)] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

fn set_alloc_grade(db :: conn.ConnDb, id :: Str, grade :: Str) -> [sql, fs_write, time] Unit {
  let q := ormq.for_dialect({ sql: "UPDATE allocations SET grade=?, updated_at=? WHERE id=?", params: [PStr(grade), PStr(time.now_str()), PStr(id)] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

# ── Grounded inputs ──────────────────────────────────────────────────────────
type SignalRow = { value :: Str }

fn latest_revenue_cents(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Option[Int] {
  let q := ormq.for_dialect({ sql: "SELECT value FROM company_operate_signals WHERE company_id=? AND kind='revenue_cents' ORDER BY observed_at DESC, idx DESC LIMIT 4", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[SignalRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.fold(rs, None, fn (acc :: Option[Int], r :: SignalRow) -> Option[Int] {
      match acc {
        Some(_) => acc,
        None => company.parse_revenue_cents(r.value),
      }
    }),
  }
}

# ── Grading (the effect-contract discipline) ─────────────────────────────────
# An applied allocation predicted "verified revenue >= target by iteration
# K". Once the company has REACHED iteration K, grade it against the current
# verified reading: hit or miss, once, trailed. Ungraded-but-not-yet-due
# stays pending.
fn grade_due(db :: conn.ConnDb, company_id :: Str, current_iter :: Int) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let applied := load_allocations(db, company_id, "applied")
  let __each := list.map(applied, fn (a :: AllocationRow) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
    if a.grade != "pending" or current_iter < a.predicted_by_iter {
      ()
    } else {
      let actual := match latest_revenue_cents(db, company_id) {
        Some(c) => c,
        None => 0,
      }
      let grade := if actual >= a.predicted_target_cents {
        "hit"
      } else {
        "miss"
      }
      let __g := set_alloc_grade(db, a.id, grade)
      let __t := tr.trail(db, company_id, "allocation_graded", str.join(["{\"allocation\":\"", a.id, "\",\"grade\":\"", grade, "\",\"predicted_cents\":", int.to_str(a.predicted_target_cents), ",\"actual_cents\":", int.to_str(actual), ",\"by_iteration\":", int.to_str(a.predicted_by_iter), "}"], ""))
      io.print(str.join(["[allocation] ", company_id, ": prediction from allocation ", str.slice(a.id, 0, 8), " graded ", grade, " (predicted >=", int.to_str(a.predicted_target_cents), "c, actual ", int.to_str(actual), "c)"], ""))
    }
  })
  ()
}

fn hit_rate_line(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  let applied := load_allocations(db, company_id, "applied")
  let hits := list.len(list.filter(applied, fn (a :: AllocationRow) -> Bool {
    a.grade == "hit"
  }))
  let graded := list.len(list.filter(applied, fn (a :: AllocationRow) -> Bool {
    a.grade == "hit" or a.grade == "miss"
  }))
  if graded == 0 {
    "no graded allocations yet"
  } else {
    str.join([int.to_str(hits), " of ", int.to_str(graded), " graded allocation prediction(s) hit"], "")
  }
}

# ── Proposing ────────────────────────────────────────────────────────────────
fn finance_prompt(goal :: Str, evidence :: Str) -> Str {
  str.join(["You are the finance function of an autonomous company. You have NO authority to move money or change budgets — your ONLY power is to propose the next period's spend-envelope allocation to the human board, with evidence and a falsifiable prediction. Envelopes govern internal LLM/tool spend only.\n\nMISSION:\n", goal, "\n\nEVIDENCE (settlement-verified revenue, current envelope utilization, allocation track record):\n", evidence, "\n\nDecide the next period's allocation. Respond with EXACTLY one JSON object and nothing else:\n{\"allocation\": \"none\"} — current envelopes are right;\n{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": <int>}, {\"scope\": \"role:<kind>\", \"cap_cents\": <int>}], \"rationale\": \"<why, citing the evidence>\", \"prediction\": {\"target_cents\": <verified revenue this should reach>, \"by_iteration\": <iteration number>}} — propose new caps (each change REPLACES that scope's cap)."], "")
}

fn evidence_block(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  let rev := match latest_revenue_cents(db, company_id) {
    None => "no verified revenue reading",
    Some(c) => str.join(["latest verified revenue reading: ", int.to_str(c), "c"], ""),
  }
  str.join([rev, "\nAllocation track record: ", hit_rate_line(db, company_id), budget.report_section(db, company_id)], "")
}

fn already_proposed_for_iter(db :: conn.ConnDb, company_id :: Str, idx :: Int) -> [sql, fs_read] Bool {
  tr.trail_contains(db, company_id, "allocation_proposed", str.concat("\"iter\":", int.to_str(idx)))
}

fn has_pending(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Bool {
  not list.is_empty(tr.attention_pending_for_sprint(db, alloc_sprint(company_id)))
}

# The mechanical gate: there must be something to allocate over — declared
# envelopes AND a verified revenue reading. No envelopes or no grounded
# revenue = the finance agent is never invoked.
fn should_consult(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Bool {
  if list.is_empty(budget.load_envelopes(db, company_id)) {
    false
  } else {
    match latest_revenue_cents(db, company_id) {
      None => false,
      Some(_) => true,
    }
  }
}

fn proposal_doc(p :: Proposal, evidence :: Str) -> Str {
  jv.stringify(JObj([("allocation", JStr(p.kind)), ("changes", match jv.parse(changes_json(p.changes)) {
    Ok(j) => j,
    Err(_) => JList([]),
  }), ("rationale", JStr(p.rationale)), ("prediction", JObj([("target_cents", JInt(p.target_cents)), ("by_iteration", JInt(p.by_iteration))])), ("evidence", JStr(evidence))]))
}

fn consult_and_propose(db :: conn.ConnDb, cfg :: company.CompanyCfg, api_max :: Int, iter_idx :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let sprint := alloc_sprint(cfg.id)
  let evidence := evidence_block(db, cfg.id)
  let request := finance_prompt(cfg.goal, evidence)
  let node := { id: str.concat("alloc-", int.to_str(iter_idx)), role: "finance", gate: "spec non-empty", expand: None, activate_when: "" }
  let g := { id: sprint, phase: Implementation, nodes: [node], edges: [] }
  let roster := cast.select_roster(db, g, request, cfg.model, sprint)
  let trail_none :: Option[tlog.Log] := None
  let acfg := { id: sprint, request: request, model: cfg.model, db: db, api_calls_max: api_max, roster: roster, trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: cfg.policy_isolation }
  let pr := orch.run_phase(g, Implementation, "", [], acfg)
  let outcome := list.fold(pr.outcomes, None, fn (acc :: Option[orch.NodeOutcome], o :: orch.NodeOutcome) -> Option[orch.NodeOutcome] {
    match acc {
      Some(_) => acc,
      None => if o.node_id == node.id {
        Some(o)
      } else {
        None
      },
    }
  })
  match outcome {
    None => io.print(str.join(["[allocation] ", cfg.id, ": consultation produced no outcome — no proposal"], "")),
    Some(o) => if not o.attested {
      io.print(str.join(["[allocation] ", cfg.id, ": consultation node not attested — no proposal"], ""))
    } else {
      match parse_proposal(orch.resolve_input(db, o.artifact)) {
        None => {
          let __t := tr.trail(db, cfg.id, "allocation_declined", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"reason\":\"no strict, falsifiable proposal in finance output\"}"], ""))
          io.print(str.join(["[allocation] ", cfg.id, ": output was not a strict, falsifiable proposal — refusing to act on it"], ""))
        },
        Some(p) => if p.kind == "none" {
          let __t := tr.trail(db, cfg.id, "allocation_declined", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"reason\":\"finance judged: current envelopes are right\"}"], ""))
          io.print(str.join(["[allocation] ", cfg.id, ": current envelopes stand"], ""))
        } else {
          match tr.artifact_put(db, sprint, node.id, proposal_doc(p, evidence)) {
            Err(e) => io.print(str.join(["[allocation] ", cfg.id, ": could not store proposal evidence: ", e], "")),
            Ok(hash) => match tr.push_attention(db, sprint, node.id, "allocation proposal", "board", hash) {
              Err(e) => io.print(str.join(["[allocation] ", cfg.id, ": could not queue proposal: ", e], "")),
              Ok(att_id) => {
                let id := crypto.random_str_hex(16)
                let q := ormq.for_dialect({ sql: "INSERT INTO allocations (id, company_id, status, changes_json, rationale, predicted_target_cents, predicted_by_iter, attention_id, proposed_at_iter, grade, created_at) VALUES (?, ?, 'proposed', ?, ?, ?, ?, ?, ?, '', ?)", params: [PStr(id), PStr(cfg.id), PStr(changes_json(p.changes)), PStr(p.rationale), PInt(p.target_cents), PInt(p.by_iteration), PStr(att_id), PInt(iter_idx), PStr(time.now_str())] }, db.dialect)
                let __r := sql.exec(db.handle, q.sql, q.params)
                let __t := tr.trail(db, cfg.id, "allocation_proposed", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"allocation\":\"", id, "\",\"attention\":\"", att_id, "\",\"predicted_cents\":", int.to_str(p.target_cents), ",\"by_iteration\":", int.to_str(p.by_iteration), "}"], ""))
                io.print(str.join(["[allocation] ", cfg.id, ": PROPOSAL queued for the board — attention ", att_id, " (predicts >=", int.to_str(p.target_cents), "c verified revenue by iteration ", int.to_str(p.by_iteration), "; advisory until approved)"], ""))
              },
            },
          }
        },
      }
    },
  }
}

# ── Applying board decisions ─────────────────────────────────────────────────
# The ONLY path from a proposal to an envelope change: an APPROVED attention
# row. Envelope updates run as the board member who approved (the actor on
# GOV2's budget_envelope_set trail).
fn apply_one(db :: conn.ConnDb, company_id :: Str, a :: AllocationRow) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  match tr.get_attention(db, a.attention_id) {
    None => (),
    Some(item) => if item.verdict == "approved" {
      let changes := match jv.parse(a.changes_json) {
        Err(_) => [],
        Ok(j) => match parse_changes(JObj([("changes", j)])) {
          None => [],
          Some(cs) => cs,
        },
      }
      let __each := list.map(changes, fn (c :: Change) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
        match budget.set_envelope(db, company_id, c.scope, c.cap_cents, item.resolved_by) {
          Err(m) => io.print(str.join(["[allocation] ", company_id, ": envelope change refused: ", m], "")),
          Ok(_) => io.print(str.join(["[allocation] ", company_id, ": envelope ", c.scope, " -> ", int.to_str(c.cap_cents), "c (approved by ", item.resolved_by, ")"], "")),
        }
      })
      let __s := set_alloc_status(db, a.id, "applied")
      let __g := set_alloc_grade(db, a.id, "pending")
      let __t := tr.trail(db, company_id, "allocation_applied", str.join(["{\"allocation\":\"", a.id, "\",\"by\":\"", item.resolved_by, "\"}"], ""))
      ()
    } else {
      if item.verdict == "rejected" {
        let __s := set_alloc_status(db, a.id, "rejected")
        let __t := tr.trail(db, company_id, "allocation_rejected", str.join(["{\"allocation\":\"", a.id, "\",\"by\":\"", item.resolved_by, "\",\"reason\":\"", company.json_escape(item.rejection_reason), "\"}"], ""))
        io.print(str.join(["[allocation] ", company_id, ": board REJECTED allocation ", str.slice(a.id, 0, 8), " (", item.resolved_by, ") — current envelopes stand"], ""))
      } else {
        ()
      }
    },
  }
}

fn apply_resolved(db :: conn.ConnDb, company_id :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let pending := load_allocations(db, company_id, "proposed")
  let __each := list.map(pending, fn (a :: AllocationRow) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
    apply_one(db, company_id, a)
  })
  ()
}

# ── The heartbeat entry point ────────────────────────────────────────────────
fn heartbeat(db :: conn.ConnDb, company_id :: Str, api_max :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  match company.load_company(db, company_id) {
    None => (),
    Some(cfg) => {
      let __apply := apply_resolved(db, company_id)
      let iter_idx := company.latest_iteration_idx(db, company_id)
      let __grade := grade_due(db, company_id, iter_idx)
      if not should_consult(db, company_id) {
        ()
      } else {
        if has_pending(db, company_id) or already_proposed_for_iter(db, company_id, iter_idx) {
          ()
        } else {
          consult_and_propose(db, cfg, api_max, iter_idx)
        }
      }
    },
  }
}

