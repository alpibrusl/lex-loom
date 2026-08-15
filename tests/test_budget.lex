# test_budget.lex — GOV2 (lex-loom#222): per-role spend envelopes.
#
# All offline (proc-executor agents, no LLM, no network):
#
#   1. MANIFEST PARSING refuses invalid scopes/amounts (never a half-set
#      budget); valid declarations round-trip.
#   2. CHARGES are atomic increments — an envelope's spent counter is the
#      exact sum of charges and can never go negative; a role without an
#      envelope is simply untracked (the total still charges).
#   3. WARN ONCE at the soft threshold; ESCALATE ONCE at the hard cap
#      (attention item for the board + ORG1 chain on the trail).
#   4. ENFORCED AT DISPATCH: an exhausted role envelope refuses that role's
#      node through the REAL orchestrator while an unrelated role's node in
#      the same phase completes; an exhausted total envelope refuses to
#      start the next iteration (stopped_by "budget") — no overdraft.
#   5. REPORTED: utilization lines with WARNING/EXHAUSTED flags.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-llm/src/providers" as providers

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/budget" as budget

import "../src/company" as company

import "../src/company_runner" as company_runner

import "../src/orchestrator" as orch

import "../src/cast" as cast

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-gov2-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn proc_agent(node_id :: Str, role :: Str) -> cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: role, system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

type CountRow = { n :: Int }

fn count_rows(db :: conn.ConnDb, q :: Str, p :: Str) -> [sql, fs_read] Int {
  let qd := ormq.for_dialect({ sql: q, params: [PStr(p)] }, db.dialect)
  let rows :: Result[List[CountRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# ── 1. Manifest parsing ──────────────────────────────────────────────────────
fn test_parse_spec() -> Result[Unit, Str] {
  match check("total + role parse", match budget.parse_envelope_spec("total:5000, role:build:2000") {
    Ok(es) => es == [("total", 5000), ("role:build", 2000)],
    Err(_) => false,
  }) {
    Err(e) => Err(e),
    Ok(_) => match check("empty declaration is fine", match budget.parse_envelope_spec("") {
      Ok(es) => list.is_empty(es),
      Err(_) => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => match check("unknown role scope refused", match budget.parse_envelope_spec("role:warp_engineer:100") {
        Ok(_) => false,
        Err(m) => str.contains(m, "invalid envelope scope"),
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("non-integer amount refused", match budget.parse_envelope_spec("total:lots") {
          Ok(_) => false,
          Err(m) => str.contains(m, "integer cents"),
        }) {
          Err(e) => Err(e),
          Ok(_) => check("zero cap refused", match budget.parse_envelope_spec("total:0") {
            Ok(_) => false,
            Err(m) => str.contains(m, "> 0 cents"),
          }),
        },
      },
    },
  }
}

# ── 2 + 3. Charging, warning once, escalating once ───────────────────────────
fn test_charge_warn_escalate() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov2-charge-", crypto.random_str_hex(6))
      let __e1 := budget.set_envelope(db, cid, "total", 1000, "board-jane")
      let __e2 := budget.set_envelope(db, cid, "role:docs", 100, "board-jane")
      match check("envelope set is trailed with the actor", tr.trail_contains(db, cid, "budget_envelope_set", "board-jane")) {
        Err(e) => Err(e),
        Ok(_) => {
          let __c1 := budget.charge(db, cid, "docs", 40)
          let __c2 := budget.charge(db, cid, "qa", 25)
          match check("charges land on role AND total", match budget.envelope_for(db, cid, "role:docs") {
            Some(e) => e.spent_cents == 40,
            None => false,
          } and match budget.envelope_for(db, cid, "total") {
            Some(e) => e.spent_cents == 65,
            None => false,
          }) {
            Err(e) => Err(e),
            Ok(_) => match check("a role without an envelope is untracked but the total still charges", match budget.envelope_for(db, cid, "role:qa") {
              None => true,
              Some(_) => false,
            }) {
              Err(e) => Err(e),
              Ok(_) => {
                let __c3 := budget.charge(db, cid, "docs", 45)
                let __w1 := budget.warn_if_needed(db, cid, "role:docs")
                let __w2 := budget.warn_if_needed(db, cid, "role:docs")
                match check("soft threshold warns exactly once", count_rows(db, "SELECT COUNT(*) AS n FROM traces WHERE event_kind='budget_warning' AND agent_id=?", cid) == 1) {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let __c4 := budget.charge(db, cid, "docs", 20)
                    match check("over the cap is Exhausted", match budget.check_role(db, cid, "docs") {
                      Exhausted => true,
                      _ => false,
                    }) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let __x1 := budget.escalate_exhausted(db, cid, "role:docs", "docs")
                        let __x2 := budget.escalate_exhausted(db, cid, "role:docs", "docs")
                        match check("hard cap escalates exactly once (one attention item)", list.len(tr.attention_pending_for_sprint(db, str.concat(cid, "/budget"))) == 1) {
                          Err(e) => Err(e),
                          Ok(_) => match check("escalation carries the chain on the trail", count_rows(db, "SELECT COUNT(*) AS n FROM traces WHERE event_kind='budget_escalated' AND agent_id=?", cid) == 1) {
                            Err(e) => Err(e),
                            Ok(_) => check("spent can never be negative", match budget.envelope_for(db, cid, "role:docs") {
                              Some(e) => e.spent_cents == 105 and e.spent_cents >= 0,
                              None => false,
                            }),
                          },
                        }
                      },
                    }
                  },
                }
              },
            },
          }
        },
      }
    },
  }
}

# ── 4a. Dispatch enforcement through the real orchestrator ───────────────────
fn outcome_for(outcomes :: List[orch.NodeOutcome], node_id :: Str) -> Option[orch.NodeOutcome] {
  list.fold(outcomes, None, fn (acc :: Option[orch.NodeOutcome], o :: orch.NodeOutcome) -> Option[orch.NodeOutcome] {
    match acc {
      Some(_) => acc,
      None => if o.node_id == node_id {
        Some(o)
      } else {
        None
      },
    }
  })
}

fn test_dispatch_refusal_spares_other_roles() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov2-dispatch-", crypto.random_str_hex(6))
      let sid := str.concat(cid, "/iter-1")
      let __e := budget.set_envelope(db, cid, "role:docs", 1, "board-jane")
      let __drain := budget.charge(db, cid, "docs", 1)
      let g := { id: sid, phase: Implementation, nodes: [{ id: "write", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "summarize", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
      let trail_none :: Option[tlog.Log] := None
      let cfg := { id: sid, request: "demo request", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("write", "docs"), proc_agent("summarize", "demo")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
      let pr := orch.run_phase(g, Implementation, "", [], cfg)
      match outcome_for(pr.outcomes, "write") {
        None => Err("no outcome for the docs node"),
        Some(o1) => match check("exhausted role refused at dispatch", not o1.attested and str.contains(o1.reason, "BUDGET")) {
          Err(e) => Err(e),
          Ok(_) => match outcome_for(pr.outcomes, "summarize") {
            None => Err("no outcome for the demo node"),
            Some(o2) => match check("unrelated role completes in the same phase", o2.attested) {
              Err(e) => Err(e),
              Ok(_) => match check("refusal is on the trail", tr.trail_contains(db, sid, "node_refused_budget", "write")) {
                Err(e) => Err(e),
                Ok(_) => check("refusal escalated to the board once", list.len(tr.attention_pending_for_sprint(db, str.concat(cid, "/budget"))) == 1),
              },
            },
          },
        },
      }
    },
  }
}

# ── 4b. Total envelope stops the company before the next iteration ───────────
fn test_total_exhaustion_stops_company() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov2-total-", crypto.random_str_hex(6))
      let __e := budget.set_envelope(db, cid, "total", 5, "board-jane")
      let __spend := budget.charge(db, cid, "docs", 5)
      let res := company_runner.run_company(db, mk_ccfg(cid), 5, false)
      match check("company stops with stopped_by=budget", res.stopped_by == "budget") {
        Err(e) => Err(e),
        Ok(_) => match check("no iteration ran", res.iterations == 0) {
          Err(e) => Err(e),
          Ok(_) => check("exhaustion escalated to the board", list.len(tr.attention_pending_for_sprint(db, str.concat(cid, "/budget"))) == 1),
        },
      }
    },
  }
}

# ── 5. Reporting ─────────────────────────────────────────────────────────────
fn test_report_section() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov2-report-", crypto.random_str_hex(6))
      let __e1 := budget.set_envelope(db, cid, "total", 1000, "board-jane")
      let __e2 := budget.set_envelope(db, cid, "role:docs", 100, "board-jane")
      let __c1 := budget.charge(db, cid, "docs", 100)
      let section := budget.report_section(db, cid)
      match check("section renders utilization", str.contains(section, "role:docs: 100c of 100c (100%) EXHAUSTED")) {
        Err(e) => Err(e),
        Ok(_) => match check("total shows percentage", str.contains(section, "total: 100c of 1000c (10%)")) {
          Err(e) => Err(e),
          Ok(_) => check("empty company renders nothing", str.is_empty(budget.report_section(db, str.concat(cid, "-none")))),
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_parse_spec(), test_charge_warn_escalate(), test_dispatch_refusal_spares_other_roles(), test_total_exhaustion_stops_company(), test_report_section()]
}

fn run_all() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

