# manager.lex — ORG3 (lex-loom#218): manager roles — agents whose output is
# reviews and reports, not artifacts.
#
# A manager's judgment enters the system at exactly two points, both derived
# from the ORG1 org chart and both auditable:
#
#   1. REVIEW. Every `done` assignment whose to_role has a manager is put in
#      front of that manager as an ordinary sprint node (cast, gated,
#      trail-recorded — same machinery as the work itself). The manager's
#      "artifact" is a verdict: accept, or return-with-notes. The verdict is
#      parsed MECHANICALLY; an unparseable review changes nothing (refuse,
#      don't downgrade — the assignment stays `done` and is re-reviewed next
#      iteration).
#   2. ATTESTATION. An accept is a positive attestation on the worker's pool
#      agent (cast.increment_attestation); a return is a negative one
#      (cast.record_bounce — which also retires a repeatedly-bounced agent
#      per cast.lex's existing <= -3 rule). Manager judgment feeds the same
#      promotion/demotion ledger mechanical outcomes already feed; it does
#      not get its own side channel.
#
# Returns are bounded: past delegation.max_rework_rounds() the assignment is
# finally `returned` and escalates up the reporting lines (ORG2 semantics) —
# a manager/worker disagreement can never loop forever.
#
# The manager also REPORTS upward: report_for aggregates its assignments
# into a compact record, trailed as `manager_report`; reports_section renders
# the latest report per manager for the Strategist's context — the org chart
# earning its keep as a context-budget mechanism (summaries flow up, raw
# artifacts don't).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.io" as io

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "lex-trail/src/log" as tlog

import "./graph" as graph

import "./org" as org

import "./cast" as cast

import "./orchestrator" as orch

import "./transport" as tr

import "./delegation" as delegation

import "./budget" as budget

import "./company" as company

# ── Verdict model ────────────────────────────────────────────────────────────
type Verdict = { accept :: Bool, notes :: Str }

# The FIXED review frame. The task, the artifact and the notes are data
# inside it; the manager cannot be steered into a different job by either.
fn review_prompt(a :: delegation.Assignment, artifact_content :: Str) -> Str {
  str.join(["You are the manager who delegated the following task to your direct report '", a.to_role, "'.\n\nTHE TASK:\n", delegation.prompt_for(a.kind, a.goal), "\n\nTHE REPORT'S SUBMITTED ARTIFACT:\n", artifact_content, "\n\nJudge whether the artifact actually accomplishes the task. Respond with EXACTLY one JSON object and nothing else: {\"verdict\": \"accept\"} to accept, or {\"verdict\": \"return\", \"notes\": \"what must change\"} to return it for rework."], "")
}

# Mechanical verdict extraction. A clean JSON object is preferred; a
# response that merely contains an unambiguous verdict string still counts
# (proc/LLM agents wrap output in prose more often than not). Anything else
# is None — and None changes no state.
fn parse_verdict(output :: Str) -> Option[Verdict] {
  match jv.parse(str.trim(output)) {
    Ok(j) => match jv.get_field(j, "verdict") {
      Some(JStr(v)) => {
        let notes := match jv.get_field(j, "notes") {
          Some(JStr(n)) => n,
          _ => "",
        }
        if v == "accept" {
          Some({ accept: true, notes: notes })
        } else {
          if v == "return" {
            Some({ accept: false, notes: notes })
          } else {
            None
          }
        }
      },
      _ => None,
    },
    Err(_) => {
      let says_accept := str.contains(output, "\"verdict\": \"accept\"") or str.contains(output, "\"verdict\":\"accept\"")
      let says_return := str.contains(output, "\"verdict\": \"return\"") or str.contains(output, "\"verdict\":\"return\"")
      if says_accept and not says_return {
        Some({ accept: true, notes: "" })
      } else {
        if says_return and not says_accept {
          Some({ accept: false, notes: "" })
        } else {
          None
        }
      }
    },
  }
}

fn review_node_id(a :: delegation.Assignment) -> Str {
  str.concat("review-", str.slice(a.id, 0, 8))
}

fn clip(s :: Str, n :: Int) -> Str {
  if str.len(s) > n {
    str.concat(str.slice(s, 0, n), "…")
  } else {
    s
  }
}

# `done` assignments that have a manager to answer to. A flat company (or an
# unmanaged role) has no reviewer — `done` is then final, exactly as in ORG2.
fn reviewable(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[delegation.Assignment] {
  let edges := org.load_org(db, company_id)
  list.filter(delegation.load_by_status(db, company_id, "done"), fn (a :: delegation.Assignment) -> Bool {
    match org.manager_of(edges, a.to_role) {
      None => false,
      Some(_) => true,
    }
  })
}

fn apply_accept(db :: conn.ConnDb, a :: delegation.Assignment, manager_role :: Str, notes :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let __s := delegation.set_status(db, a.id, "approved", a.artifact_ref, notes)
  let __att := if str.is_empty(a.worker_agent_id) {
    ()
  } else {
    cast.increment_attestation(db, a.worker_agent_id)
  }
  let __t := tr.trail(db, a.company_id, "assignment_approved", str.join(["{\"assignment\":\"", a.id, "\",\"by\":\"", manager_role, "\",\"worker\":\"", a.worker_agent_id, "\",\"notes\":\"", company.json_escape(notes), "\"}"], ""))
  io.print(str.join(["[manager] ", manager_role, " ACCEPTED assignment ", delegation.node_id_for(a), " (", a.kind, " by ", a.to_role, ") — positive attestation on ", a.worker_agent_id], ""))
}

fn apply_return(db :: conn.ConnDb, a :: delegation.Assignment, manager_role :: Str, notes :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let __att := if str.is_empty(a.worker_agent_id) {
    ()
  } else {
    cast.record_bounce(db, a.worker_agent_id)
  }
  if a.rework_count >= delegation.max_rework_rounds() {
    let chain := org.escalation_chain(org.load_org(db, a.company_id), a.to_role)
    let chain_str := if list.is_empty(chain) {
      "(flat — no reporting line)"
    } else {
      str.join(chain, " -> ")
    }
    let __s := delegation.set_status(db, a.id, "returned", "", notes)
    let __t := tr.trail(db, a.company_id, "assignment_returned", str.join(["{\"assignment\":\"", a.id, "\",\"to\":\"", a.to_role, "\",\"reason\":\"", company.json_escape(notes), "\",\"escalates_to\":\"", company.json_escape(chain_str), "\"}"], ""))
    io.print(str.join(["[manager] ", manager_role, " returned assignment ", delegation.node_id_for(a), " past the rework cap — FINAL, escalation path: ", chain_str], ""))
  } else {
    let __s := delegation.send_to_rework(db, a.id, notes)
    let __t := tr.trail(db, a.company_id, "assignment_rework", str.join(["{\"assignment\":\"", a.id, "\",\"by\":\"", manager_role, "\",\"worker\":\"", a.worker_agent_id, "\",\"notes\":\"", company.json_escape(notes), "\"}"], ""))
    io.print(str.join(["[manager] ", manager_role, " RETURNED assignment ", delegation.node_id_for(a), " for rework (round ", int.to_str(a.rework_count + 1), "): ", clip(notes, 80)], ""))
  }
}

# Put one `done` assignment in front of its manager, as an ordinary sprint
# node, and apply the verdict.
fn review_one(db :: conn.ConnDb, ccfg :: company.CompanyCfg, sprint_id :: Str, api_max :: Int, a :: delegation.Assignment) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  match org.manager_of(org.load_org(db, ccfg.id), a.to_role) {
    None => (),
    Some(manager_role) => {
      let artifact := orch.resolve_input(db, a.artifact_ref)
      let node := { id: review_node_id(a), role: manager_role, gate: "spec non-empty", expand: None, activate_when: "" }
      let g := { id: sprint_id, phase: Implementation, nodes: [node], edges: [] }
      let request := review_prompt(a, artifact)
      let roster := cast.select_roster(db, g, request, ccfg.model, sprint_id)
      let trail_none :: Option[tlog.Log] := None
      let acfg := { id: sprint_id, request: request, model: ccfg.model, db: db, api_calls_max: api_max, roster: roster, trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: ccfg.policy_isolation }
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
        None => {
          let __t := tr.trail(db, ccfg.id, "manager_review_unparseable", str.join(["{\"assignment\":\"", a.id, "\",\"by\":\"", manager_role, "\",\"reason\":\"no review outcome\"}"], ""))
          ()
        },
        Some(o) => if not o.attested {
          let __t := tr.trail(db, ccfg.id, "manager_review_unparseable", str.join(["{\"assignment\":\"", a.id, "\",\"by\":\"", manager_role, "\",\"reason\":\"review node not attested\"}"], ""))
          ()
        } else {
          match parse_verdict(orch.resolve_input(db, o.artifact)) {
            None => {
              let __t := tr.trail(db, ccfg.id, "manager_review_unparseable", str.join(["{\"assignment\":\"", a.id, "\",\"by\":\"", manager_role, "\",\"reason\":\"no mechanical verdict in review output\"}"], ""))
              ()
            },
            Some(v) => if v.accept {
              apply_accept(db, a, manager_role, v.notes)
            } else {
              apply_return(db, a, manager_role, v.notes)
            },
          }
        },
      }
    },
  }
}

# The review pass company_runner runs right after draining assignments.
# Returns how many reviews were conducted.
fn review_assignments(db :: conn.ConnDb, ccfg :: company.CompanyCfg, sprint_id :: Str, api_max :: Int) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Int {
  let todo := reviewable(db, ccfg.id)
  let __each := list.map(todo, fn (a :: delegation.Assignment) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
    review_one(db, ccfg, sprint_id, api_max, a)
  })
  list.len(todo)
}

# ── Reporting upward ─────────────────────────────────────────────────────────
type RoleRow = { from_role :: Str }

fn manager_roles(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT DISTINCT from_role FROM assignments WHERE company_id=? ORDER BY from_role ASC", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[RoleRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: RoleRow) -> Str {
      r.from_role
    }),
  }
}

# One manager's compact upward report: counts plus a one-liner per
# assignment. This — not the raw artifacts — is what flows up.
fn report_for(db :: conn.ConnDb, company_id :: Str, manager_role :: Str) -> [sql, fs_read] Str {
  let mine := list.filter(list.concat(delegation.load_by_status(db, company_id, "offered"), list.concat(delegation.load_by_status(db, company_id, "rework"), list.concat(delegation.load_by_status(db, company_id, "done"), list.concat(delegation.load_by_status(db, company_id, "approved"), delegation.load_by_status(db, company_id, "returned"))))), fn (a :: delegation.Assignment) -> Bool {
    a.from_role == manager_role
  })
  let count_of := fn (status :: Str) -> Int {
    list.len(list.filter(mine, fn (a :: delegation.Assignment) -> Bool {
      a.status == status
    }))
  }
  let lines := list.map(mine, fn (a :: delegation.Assignment) -> [sql, fs_read] Str {
    let note := if str.is_empty(a.reason) {
      ""
    } else {
      str.join([" — ", clip(a.reason, 80)], "")
    }
    str.join(["  * ", a.kind, " -> ", a.to_role, ": ", a.status, note, budget.remaining_line(db, company_id, a.to_role)], "")
  })
  str.join([manager_role, " team: ", int.to_str(count_of("approved")), " approved, ", int.to_str(count_of("done")), " awaiting review, ", int.to_str(count_of("rework")), " in rework, ", int.to_str(count_of("returned")), " returned, ", int.to_str(count_of("offered")), " queued.\n", str.join(lines, "\n")], "")
}

# Trail every manager's current report (one manager_report event each).
fn record_reports(db :: conn.ConnDb, company_id :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Int {
  let roles := manager_roles(db, company_id)
  let __each := list.map(roles, fn (m :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
    let rep := report_for(db, company_id, m)
    let __t := tr.trail(db, company_id, "manager_report", str.join(["{\"manager\":\"", m, "\",\"report\":\"", company.json_escape(rep), "\"}"], ""))
    io.print(str.join(["[manager] report filed by ", m], ""))
  })
  list.len(roles)
}

# The Strategist-facing section: the CURRENT report per manager, derived
# from the same DB state the trail events witness. Empty string when no
# delegation happened — the strategist prompt is unchanged for flat
# companies.
fn reports_section(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  let roles := manager_roles(db, company_id)
  if list.is_empty(roles) {
    ""
  } else {
    let blocks := list.map(roles, fn (m :: Str) -> [sql, fs_read] Str {
      str.concat("- ", report_for(db, company_id, m))
    })
    str.join(["\nManagement reports (delegated subtree work arrives summarized by its manager — raw artifacts are reviewed by them, not re-read here):\n", str.join(blocks, "\n")], "")
  }
}

