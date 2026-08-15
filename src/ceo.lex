# ceo.lex — ORG4 (lex-loom#219): the CEO — goal origination above the
# Strategist.
#
# The CEO runs on the HB1 heartbeat (scheduler.handle_company), not
# per-sprint, and it can do exactly ONE kind of thing: emit a PROPOSAL to
# the board. It never acts directly — the board disposes, through the same
# attention queue every other human decision already flows through
# (oracle "board", RESOLVER_ID recorded), and nothing changes until a
# proposal is approved. It never gains spend/payment authority.
#
# Three deliberate mechanics:
#
#   1. MECHANICAL GATE, THEN JUDGMENT. Whether the CEO is even consulted is
#      decided by grounded signals (consecutive failed iterations + the
#      settlement-recorded revenue trend), not by an LLM. Healthy company →
#      the CEO agent is never invoked: zero proposal churn, zero spend.
#      Hysteresis on top: at most one proposal per iteration index, and
#      never while one is already pending before the board.
#   2. STRICT VERDICTS. The CEO's output must parse as EXACTLY one JSON
#      proposal object — there is no prose fallback for a mission change.
#      Unparseable, or a pivot without a new goal → no proposal (refuse,
#      don't downgrade).
#   3. LEDGERED MISSIONS. The founding mission is row 1 of mission_ledger;
#      every approved revision appends a row naming its source proposal and
#      the board member who approved it. The Strategist keeps executing
#      whatever the CURRENT mission is (companies.goal) — the human-written
#      mission is the founding input, not the permanent ceiling.

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

import "./manager" as manager

import "./company" as company

fn ceo_sprint(company_id :: Str) -> Str {
  str.concat(company_id, "/ceo")
}

# ── Grounded health signals ──────────────────────────────────────────────────
type Health = { failing_streak :: Int, latest_revenue_cents :: Int, prior_revenue_cents :: Int, revenue_growing :: Bool }

type StatusRow = { status :: Str }

fn recent_statuses(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT status FROM company_iterations WHERE company_id=? ORDER BY idx DESC LIMIT 3", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[StatusRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: StatusRow) -> Str {
      r.status
    }),
  }
}

fn leading_failed(statuses :: List[Str]) -> Int {
  match list.head(statuses) {
    None => 0,
    Some(s) => if s == "failed" {
      1 + leading_failed(list.tail(statuses))
    } else {
      0
    },
  }
}

type SignalRow = { value :: Str }

# The two most recent settlement-recorded revenue readings, newest first.
# Unparseable readings are skipped — only grounded numbers count.
fn recent_revenue(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Int] {
  let q := ormq.for_dialect({ sql: "SELECT value FROM company_operate_signals WHERE company_id=? AND kind='revenue_cents' ORDER BY observed_at DESC, idx DESC LIMIT 4", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[SignalRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.fold(rs, [], fn (acc :: List[Int], r :: SignalRow) -> List[Int] {
      if list.len(acc) >= 2 {
        acc
      } else {
        match company.parse_revenue_cents(r.value) {
          None => acc,
          Some(c) => list.concat(acc, [c]),
        }
      }
    }),
  }
}

fn assess(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Health {
  let streak := leading_failed(recent_statuses(db, company_id))
  let revs := recent_revenue(db, company_id)
  let latest := match list.head(revs) {
    None => 0,
    Some(c) => c,
  }
  let prior := match list.head(list.tail(revs)) {
    None => 0,
    Some(c) => c,
  }
  { failing_streak: streak, latest_revenue_cents: latest, prior_revenue_cents: prior, revenue_growing: list.len(revs) >= 2 and latest > prior }
}

# The mechanical gate: the CEO is consulted only when the sprint loop is
# demonstrably failing AND revenue is not growing. Pure and testable.
fn should_consult(h :: Health) -> Bool {
  h.failing_streak >= 2 and not h.revenue_growing
}

fn health_summary(h :: Health) -> Str {
  str.join(["consecutive failed iterations: ", int.to_str(h.failing_streak), "; latest revenue reading: ", company.format_cents(h.latest_revenue_cents), " (prior: ", company.format_cents(h.prior_revenue_cents), ", growing: ", if h.revenue_growing {
    "yes"
  } else {
    "no"
  }, ")"], "")
}

# ── The CEO's judgment (strictly parsed) ─────────────────────────────────────
type Proposal = { kind :: Str, new_goal :: Str, rationale :: Str }

fn ceo_prompt(mission :: Str, current_goal :: Str, evidence :: Str) -> Str {
  str.join(["You are the CEO of an autonomous company. You do not execute work and you have no spending authority; your ONLY power is to propose a strategic change to the human board, with evidence.\n\nFOUNDING MISSION:\n", mission, "\n\nCURRENT GOAL (what the Strategist is executing):\n", current_goal, "\n\nEVIDENCE (grounded signals — not self-reports):\n", evidence, "\n\nDecide whether the company should change course. Respond with EXACTLY one JSON object and nothing else:\n{\"proposal\": \"none\"} — stay the course;\n{\"proposal\": \"pivot\", \"new_goal\": \"<the revised mission-level goal>\", \"rationale\": \"<why, citing the evidence>\"} — propose a pivot;\n{\"proposal\": \"sunset\", \"rationale\": \"<why, citing the evidence>\"} — propose winding the company down."], "")
}

# Strict: the whole (trimmed) output must be one JSON proposal object. A
# mission change gets no prose fallback. A pivot without a non-empty
# new_goal is refused outright.
fn parse_proposal(output :: Str) -> Option[Proposal] {
  match jv.parse(str.trim(output)) {
    Err(_) => None,
    Ok(j) => match jv.get_field(j, "proposal") {
      Some(JStr(k)) => {
        let new_goal := match jv.get_field(j, "new_goal") {
          Some(JStr(g)) => g,
          _ => "",
        }
        let rationale := match jv.get_field(j, "rationale") {
          Some(JStr(r)) => r,
          _ => "",
        }
        if k == "none" {
          Some({ kind: "none", new_goal: "", rationale: rationale })
        } else {
          if k == "pivot" and not str.is_empty(str.trim(new_goal)) {
            Some({ kind: "pivot", new_goal: new_goal, rationale: rationale })
          } else {
            if k == "sunset" {
              Some({ kind: "sunset", new_goal: "", rationale: rationale })
            } else {
              None
            }
          }
        }
      },
      _ => None,
    },
  }
}

# ── Mission ledger ───────────────────────────────────────────────────────────
type LedgerRow = { idx :: Int, mission :: Str, source :: Str, approved_by :: Str, created_at :: Str }

fn mission_history(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[LedgerRow] {
  let q := ormq.for_dialect({ sql: "SELECT idx, mission, source, approved_by, created_at FROM mission_ledger WHERE company_id=? ORDER BY idx ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[LedgerRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn append_ledger(db :: conn.ConnDb, company_id :: Str, mission :: Str, source :: Str, approved_by :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  let idx := list.len(mission_history(db, company_id)) + 1
  let q := ormq.for_dialect({ sql: "INSERT INTO mission_ledger (id, company_id, idx, mission, source, approved_by, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", params: [PStr(crypto.random_str_hex(16)), PStr(company_id), PInt(idx), PStr(mission), PStr(source), PStr(approved_by), PStr(time.now_str())] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Row 1 is always the founding mission — written once, the first time the
# CEO pass sees the company.
fn ensure_founding(db :: conn.ConnDb, company_id :: Str, mission :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  if list.is_empty(mission_history(db, company_id)) {
    let __r := append_ledger(db, company_id, mission, "founding", "founder")
    ()
  } else {
    ()
  }
}

# A board-approved pivot revises BOTH goal pointers: the company's mission
# (companies.goal — what a fresh run starts from) and the latest iteration's
# operational goal (what company_runner's resume_point continues with, which
# otherwise deliberately outlives ccfg.goal). History is not rewritten — the
# audit story lives in mission_ledger and the mission_revised trail event;
# iteration.goal is the "continue with" pointer, and the board just moved it.
fn revise_goal(db :: conn.ConnDb, company_id :: Str, new_goal :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE companies SET goal=? WHERE id=?", params: [PStr(new_goal), PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => {
      let q2 := ormq.for_dialect({ sql: "UPDATE company_iterations SET goal=? WHERE company_id=? AND idx=(SELECT MAX(idx) FROM company_iterations WHERE company_id=?)", params: [PStr(new_goal), PStr(company_id), PStr(company_id)] }, db.dialect)
      match sql.exec(db.handle, q2.sql, q2.params) {
        Err(e) => Err(e.message),
        Ok(_) => Ok(()),
      }
    },
  }
}

# ── Proposing (advisory-until-approved) ──────────────────────────────────────
# Same shape parse_proposal reads, so the stored doc round-trips through the
# exact parser the CEO's own output went through.
fn proposal_doc(p :: Proposal, evidence :: Str) -> Str {
  jv.stringify(JObj([("proposal", JStr(p.kind)), ("new_goal", JStr(p.new_goal)), ("rationale", JStr(p.rationale)), ("evidence", JStr(evidence))]))
}

fn evidence_block(db :: conn.ConnDb, cfg :: company.CompanyCfg, h :: Health) -> [sql, fs_read] Str {
  str.join([health_summary(h), "\n", company.real_economics_section(db, cfg.id), manager.reports_section(db, cfg.id)], "")
}

fn already_proposed_for_iter(db :: conn.ConnDb, company_id :: Str, idx :: Int) -> [sql, fs_read] Bool {
  tr.trail_contains(db, company_id, "ceo_proposal", str.concat("\"iter\":", int.to_str(idx)))
}

fn has_pending_proposal(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Bool {
  not list.is_empty(tr.attention_pending_for_sprint(db, ceo_sprint(company_id)))
}

# Consult the CEO agent (an ordinary cast node, role "ceo") and, if it
# proposes a change, put the proposal — evidence attached — in front of the
# board. Nothing else happens here.
fn consult_and_propose(db :: conn.ConnDb, cfg :: company.CompanyCfg, api_max :: Int, h :: Health, iter_idx :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let sprint := ceo_sprint(cfg.id)
  let evidence := evidence_block(db, cfg, h)
  let founding := match list.head(mission_history(db, cfg.id)) {
    None => cfg.goal,
    Some(row) => row.mission,
  }
  let request := ceo_prompt(founding, cfg.goal, evidence)
  let node := { id: str.concat("ceo-", int.to_str(iter_idx)), role: "ceo", gate: "spec non-empty", expand: None, activate_when: "" }
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
    None => io.print(str.join(["[ceo] ", cfg.id, ": consultation produced no outcome — no proposal"], "")),
    Some(o) => if not o.attested {
      io.print(str.join(["[ceo] ", cfg.id, ": consultation node not attested — no proposal"], ""))
    } else {
      match parse_proposal(orch.resolve_input(db, o.artifact)) {
        None => {
          let __t := tr.trail(db, cfg.id, "ceo_proposal_declined", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"reason\":\"no strict-JSON proposal in CEO output\"}"], ""))
          io.print(str.join(["[ceo] ", cfg.id, ": output was not a strict proposal — refusing to act on it"], ""))
        },
        Some(p) => if p.kind == "none" {
          let __t := tr.trail(db, cfg.id, "ceo_proposal_declined", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"reason\":\"CEO judged: stay the course\"}"], ""))
          io.print(str.join(["[ceo] ", cfg.id, ": stay the course"], ""))
        } else {
          match tr.artifact_put(db, sprint, node.id, proposal_doc(p, evidence)) {
            Err(e) => io.print(str.join(["[ceo] ", cfg.id, ": could not store proposal evidence: ", e], "")),
            Ok(hash) => match tr.push_attention(db, sprint, node.id, str.concat("ceo proposal ", p.kind), "board", hash) {
              Err(e) => io.print(str.join(["[ceo] ", cfg.id, ": could not queue proposal: ", e], "")),
              Ok(att_id) => {
                let __t := tr.trail(db, cfg.id, "ceo_proposal", str.join(["{\"iter\":", int.to_str(iter_idx), ",\"kind\":\"", p.kind, "\",\"attention\":\"", att_id, "\",\"rationale\":\"", company.json_escape(p.rationale), "\"}"], ""))
                io.print(str.join(["[ceo] ", cfg.id, ": PROPOSAL (", p.kind, ") queued for the board — attention ", att_id, " (advisory until approved)"], ""))
              },
            },
          }
        },
      }
    },
  }
}

# ── Applying board decisions ─────────────────────────────────────────────────
fn resolved_proposals(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[tr.AttentionRow] {
  let q := ormq.for_dialect({ sql: "SELECT id, sprint_id, node_id, gate, oracle, artifact_hash, verdict, rejection_reason, created_at, resolved_by FROM attention_queue WHERE sprint_id=? AND verdict IN ('approved', 'rejected') ORDER BY created_at ASC", params: [PStr(ceo_sprint(company_id))] }, db.dialect)
  let rows :: Result[List[tr.AttentionRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn apply_one(db :: conn.ConnDb, cfg :: company.CompanyCfg, item :: tr.AttentionRow) -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Unit {
  if item.verdict == "rejected" {
    if tr.trail_contains(db, cfg.id, "ceo_proposal_rejected", item.id) {
      ()
    } else {
      let __t := tr.trail(db, cfg.id, "ceo_proposal_rejected", str.join(["{\"attention\":\"", item.id, "\",\"by\":\"", item.resolved_by, "\",\"reason\":\"", company.json_escape(item.rejection_reason), "\"}"], ""))
      io.print(str.join(["[ceo] ", cfg.id, ": board REJECTED proposal ", item.id, " (", item.resolved_by, ") — course unchanged"], ""))
    }
  } else {
    if tr.trail_contains(db, cfg.id, "mission_revised", item.id) or tr.trail_contains(db, cfg.id, "company_sunset", item.id) {
      ()
    } else {
      match tr.artifact_get(db, item.artifact_hash) {
        Err(e) => io.print(str.join(["[ceo] ", cfg.id, ": approved proposal ", item.id, " has unreadable evidence (", e, ") — refusing to apply"], "")),
        Ok(doc) => match parse_proposal(doc) {
          None => io.print(str.join(["[ceo] ", cfg.id, ": approved proposal ", item.id, " does not parse — refusing to apply"], "")),
          Some(p) => if p.kind == "pivot" {
            match revise_goal(db, cfg.id, p.new_goal) {
              Err(e) => io.print(str.join(["[ceo] ", cfg.id, ": goal revision failed: ", e], "")),
              Ok(_) => {
                let __l := append_ledger(db, cfg.id, p.new_goal, str.concat("ceo_proposal ", item.id), item.resolved_by)
                let __t := tr.trail(db, cfg.id, "mission_revised", str.join(["{\"attention\":\"", item.id, "\",\"by\":\"", item.resolved_by, "\",\"goal\":\"", company.json_escape(p.new_goal), "\"}"], ""))
                io.print(str.join(["[ceo] ", cfg.id, ": board APPROVED pivot (", item.resolved_by, ") — mission revised, the Strategist executes the new goal from the next iteration"], ""))
              },
            }
          } else {
            if p.kind == "sunset" {
              let __s := company.save_stage(db, cfg.id, Sunset)
              let __t := tr.trail(db, cfg.id, "company_sunset", str.join(["{\"attention\":\"", item.id, "\",\"by\":\"", item.resolved_by, "\"}"], ""))
              io.print(str.join(["[ceo] ", cfg.id, ": board APPROVED sunset (", item.resolved_by, ") — company wound down"], ""))
            } else {
              io.print(str.join(["[ceo] ", cfg.id, ": approved proposal ", item.id, " has unknown kind '", p.kind, "' — refusing to apply"], ""))
            }
          },
        },
      }
    }
  }
}

fn apply_resolved(db :: conn.ConnDb, cfg :: company.CompanyCfg) -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Unit {
  let items := resolved_proposals(db, cfg.id)
  let __each := list.map(items, fn (item :: tr.AttentionRow) -> [io, sql, fs_read, fs_write, time, random, crypto, vcs] Unit {
    apply_one(db, cfg, item)
  })
  ()
}

# ── The heartbeat entry point ────────────────────────────────────────────────
# Called by scheduler.handle_company on every tick, BEFORE classification —
# so an approved pivot revises the goal the classifier and runner load.
fn heartbeat(db :: conn.ConnDb, company_id :: Str, api_max :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  match company.load_company(db, company_id) {
    None => (),
    Some(cfg) => {
      let __found := ensure_founding(db, company_id, cfg.goal)
      let __apply := apply_resolved(db, cfg)
      let h := assess(db, company_id)
      let iter_idx := company.latest_iteration_idx(db, company_id)
      if not should_consult(h) {
        ()
      } else {
        if has_pending_proposal(db, company_id) or already_proposed_for_iter(db, company_id, iter_idx) {
          ()
        } else {
          let __p := io.print(str.join(["[ceo] ", company_id, ": grounded signals warrant consulting the CEO (", health_summary(h), ")"], ""))
          consult_and_propose(db, cfg, api_max, h, iter_idx)
        }
      }
    },
  }
}

