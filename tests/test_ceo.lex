# test_ceo.lex — ORG4 (lex-loom#219): the CEO — goal origination above the
# Strategist. All offline (proc-executor agents, no LLM, no network).
#
#   1. MECHANICAL GATE — should_consult fires only on grounded distress
#      (failing streak + non-growing revenue); a healthy company never even
#      invokes the CEO agent (no churn, no spend).
#   2. STRICT PROPOSALS — only exact-JSON proposals count; a pivot without a
#      new goal is refused.
#   3. ADVISORY-UNTIL-APPROVED — a proposal parks before the board (oracle
#      "board") with its evidence attached; nothing changes until resolved;
#      no duplicate proposals while one is pending.
#   4. LEDGERED MISSIONS — founding mission is row 1; an approved pivot
#      revises companies.goal (what the Strategist executes next) and
#      appends a ledger row naming the proposal and the approver; a
#      rejection changes nothing. An approved sunset winds the company down.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/query" as ormq

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/ceo" as ceo

import "../src/company" as company

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

# Per-test file DB (#242): agent_pool casting is role-scoped, so tests
# must not share a database or they cast each other's agents.
fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-org4-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "founding mission: build a widget factory", model: "proc:cat", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_iteration(db :: conn.ConnDb, cid :: Str, idx :: Int, status :: Str) -> [sql, fs_write, time] Unit {
  let __r := company.record_iteration(db, { company_id: cid, idx: idx, sprint_id: str.join([cid, "/iter-", int.to_str(idx)], ""), parent_sprint_id: "", status: "running", goal: "g" })
  let __f := company.finish_iteration(db, cid, idx, status)
  ()
}

fn seed_ceo_agent(db :: conn.ConnDb, model_name :: Str) -> [sql, fs_write, random, crypto] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, 'ceo', '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(str.concat("ceo-agent-", crypto.random_str_hex(6))), PStr(model_name)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn pivot_ceo_model() -> Str {
  "proc:echo '{\"proposal\": \"pivot\", \"new_goal\": \"pivot to a paid analytics API\", \"rationale\": \"two failed iterations and flat revenue\"}'"
}

fn sunset_ceo_model() -> Str {
  "proc:echo '{\"proposal\": \"sunset\", \"rationale\": \"no path to revenue\"}'"
}

# ── 1. The mechanical gate (pure) ────────────────────────────────────────────
fn test_gate() -> Result[Unit, Str] {
  match check("healthy company: no consult", not ceo.should_consult({ failing_streak: 0, latest_revenue_cents: 0, prior_revenue_cents: 0, revenue_growing: false })) {
    Err(e) => Err(e),
    Ok(_) => match check("one failure is not a crisis", not ceo.should_consult({ failing_streak: 1, latest_revenue_cents: 0, prior_revenue_cents: 0, revenue_growing: false })) {
      Err(e) => Err(e),
      Ok(_) => match check("two failures + flat revenue: consult", ceo.should_consult({ failing_streak: 2, latest_revenue_cents: 100, prior_revenue_cents: 100, revenue_growing: false })) {
        Err(e) => Err(e),
        Ok(_) => match check("growing revenue overrides a failing streak", not ceo.should_consult({ failing_streak: 3, latest_revenue_cents: 200, prior_revenue_cents: 100, revenue_growing: true })) {
          Err(e) => Err(e),
          Ok(_) => match check("leading_failed counts only the streak", ceo.leading_failed(["failed", "failed", "success"]) == 2) {
            Err(e) => Err(e),
            Ok(_) => check("a success at the head resets the streak", ceo.leading_failed(["success", "failed", "failed"]) == 0),
          },
        },
      },
    },
  }
}

# ── 2. Strict proposal parsing (pure) ────────────────────────────────────────
fn test_parse_proposal() -> Result[Unit, Str] {
  match check("none parses", match ceo.parse_proposal("{\"proposal\": \"none\"}") {
    Some(p) => p.kind == "none",
    None => false,
  }) {
    Err(e) => Err(e),
    Ok(_) => match check("pivot parses with goal + rationale", match ceo.parse_proposal("{\"proposal\": \"pivot\", \"new_goal\": \"sell shovels\", \"rationale\": \"gold rush\"}") {
      Some(p) => p.kind == "pivot" and p.new_goal == "sell shovels" and p.rationale == "gold rush",
      None => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => match check("pivot WITHOUT a new goal is refused", match ceo.parse_proposal("{\"proposal\": \"pivot\", \"rationale\": \"vibes\"}") {
        Some(_) => false,
        None => true,
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("sunset parses", match ceo.parse_proposal("{\"proposal\": \"sunset\", \"rationale\": \"dead market\"}") {
          Some(p) => p.kind == "sunset",
          None => false,
        }) {
          Err(e) => Err(e),
          Ok(_) => match check("prose-wrapped JSON is refused (strict)", match ceo.parse_proposal("Here you go: {\"proposal\": \"pivot\", \"new_goal\": \"x\"}") {
            Some(_) => false,
            None => true,
          }) {
            Err(e) => Err(e),
            Ok(_) => check("garbage is refused", match ceo.parse_proposal("we should probably pivot") {
              Some(_) => false,
              None => true,
            }),
          },
        },
      },
    },
  }
}

# ── 3. Healthy company: the CEO agent is never invoked ───────────────────────
fn test_healthy_no_consult() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org4-healthy-", crypto.random_str_hex(6))
      let __c := company.save_company(db, mk_ccfg(cid))
      let __i1 := seed_iteration(db, cid, 1, "success")
      let __i2 := seed_iteration(db, cid, 2, "success")
      let __hb := ceo.heartbeat(db, cid, 50)
      match check("no proposal queued", list.is_empty(tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo")))) {
        Err(e) => Err(e),
        Ok(_) => match check("no ceo agent was ever cast (no node_cast in the ceo sprint)", not tr.trail_contains(db, str.concat(cid, "/ceo"), "node_cast", "ceo")) {
          Err(e) => Err(e),
          Ok(_) => check("founding mission ledgered as row 1", match list.head(ceo.mission_history(db, cid)) {
            Some(r) => r.idx == 1 and r.source == "founding" and r.approved_by == "founder",
            None => false,
          }),
        },
      }
    },
  }
}

# ── 4. Distress -> proposal with evidence; no duplicates while pending ───────
fn distressed_company(db :: conn.ConnDb, cid :: Str, model :: Str) -> [sql, fs_write, time, random, crypto] Result[Unit, Str] {
  let __c := company.save_company(db, mk_ccfg(cid))
  let __i1 := seed_iteration(db, cid, 1, "failed")
  let __i2 := seed_iteration(db, cid, 2, "failed")
  let __r1 := company.record_operate_signal(db, cid, 1, "revenue_cents", "{\"revenue_cents\": 100}")
  let __r2 := company.record_operate_signal(db, cid, 2, "revenue_cents", "{\"revenue_cents\": 100}")
  seed_ceo_agent(db, model)
}

fn test_distress_proposes_once() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org4-distress-", crypto.random_str_hex(6))
      match distressed_company(db, cid, pivot_ceo_model()) {
        Err(e) => Err(e),
        Ok(_) => {
          let __hb := ceo.heartbeat(db, cid, 50)
          let pending := tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo"))
          match list.head(pending) {
            None => Err("expected a pending proposal before the board"),
            Some(item) => match check("proposal goes to the board", item.oracle == "board" and item.gate == "ceo proposal pivot") {
              Err(e) => Err(e),
              Ok(_) => match check("evidence attached to the proposal", match tr.artifact_get(db, item.artifact_hash) {
                Ok(doc) => str.contains(doc, "consecutive failed iterations: 2") and str.contains(doc, "pivot to a paid analytics API"),
                Err(_) => false,
              }) {
                Err(e) => Err(e),
                Ok(_) => match check("proposal is on the trail", tr.trail_contains(db, cid, "ceo_proposal", item.id)) {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let __hb2 := ceo.heartbeat(db, cid, 50)
                    match check("no duplicate proposal while one is pending", list.len(tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo"))) == 1) {
                      Err(e) => Err(e),
                      Ok(_) => check("goal unchanged until the board decides", match company.load_company(db, cid) {
                        Some(c) => c.goal == "founding mission: build a widget factory",
                        None => false,
                      }),
                    }
                  },
                },
              },
            },
          }
        },
      }
    },
  }
}

# ── 5. Approval applies: goal revised, ledgered with the approver ────────────
fn test_approval_revises_mission() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org4-approve-", crypto.random_str_hex(6))
      match distressed_company(db, cid, pivot_ceo_model()) {
        Err(e) => Err(e),
        Ok(_) => {
          let __hb := ceo.heartbeat(db, cid, 50)
          match list.head(tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo"))) {
            None => Err("expected a pending proposal"),
            Some(item) => {
              let __r := tr.resolve_attention(db, item.id, "approved", "", "board-jane")
              let __hb2 := ceo.heartbeat(db, cid, 50)
              match check("the Strategist's next goal is the approved pivot", match company.load_company(db, cid) {
                Some(c) => c.goal == "pivot to a paid analytics API",
                None => false,
              }) {
                Err(e) => Err(e),
                Ok(_) => {
                  let hist := ceo.mission_history(db, cid)
                  match check("ledger has founding + revision", list.len(hist) == 2) {
                    Err(e) => Err(e),
                    Ok(_) => match list.head(list.tail(hist)) {
                      None => Err("revision row missing"),
                      Some(rev) => match check("revision names the proposal and the approver", rev.approved_by == "board-jane" and str.contains(rev.source, "ceo_proposal") and rev.mission == "pivot to a paid analytics API") {
                        Err(e) => Err(e),
                        Ok(_) => match check("revision is on the trail", tr.trail_contains(db, cid, "mission_revised", item.id)) {
                          Err(e) => Err(e),
                          Ok(_) => {
                            let __hb3 := ceo.heartbeat(db, cid, 50)
                            check("apply is idempotent (no third ledger row)", list.len(ceo.mission_history(db, cid)) == 2)
                          },
                        },
                      },
                    },
                  }
                },
              }
            },
          }
        },
      }
    },
  }
}

# ── 6. Rejection changes nothing ─────────────────────────────────────────────
fn test_rejection_holds_course() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org4-reject-", crypto.random_str_hex(6))
      match distressed_company(db, cid, pivot_ceo_model()) {
        Err(e) => Err(e),
        Ok(_) => {
          let __hb := ceo.heartbeat(db, cid, 50)
          match list.head(tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo"))) {
            None => Err("expected a pending proposal"),
            Some(item) => {
              let __r := tr.resolve_attention(db, item.id, "rejected", "stay focused", "board-jane")
              let __hb2 := ceo.heartbeat(db, cid, 50)
              match check("goal unchanged after rejection", match company.load_company(db, cid) {
                Some(c) => c.goal == "founding mission: build a widget factory",
                None => false,
              }) {
                Err(e) => Err(e),
                Ok(_) => match check("ledger still only the founding mission", list.len(ceo.mission_history(db, cid)) == 1) {
                  Err(e) => Err(e),
                  Ok(_) => check("rejection is on the trail with the board's reason", tr.trail_contains(db, cid, "ceo_proposal_rejected", item.id)),
                },
              }
            },
          }
        },
      }
    },
  }
}

# ── 7. Approved sunset winds the company down ────────────────────────────────
fn test_sunset_approved() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org4-sunset-", crypto.random_str_hex(6))
      match distressed_company(db, cid, sunset_ceo_model()) {
        Err(e) => Err(e),
        Ok(_) => {
          let __hb := ceo.heartbeat(db, cid, 50)
          match list.head(tr.attention_pending_for_sprint(db, str.concat(cid, "/ceo"))) {
            None => Err("expected a pending sunset proposal"),
            Some(item) => {
              let __r := tr.resolve_attention(db, item.id, "approved", "", "board-jane")
              let __hb2 := ceo.heartbeat(db, cid, 50)
              match check("company stage is Sunset after approval", company.load_stage(db, cid) == Sunset) {
                Err(e) => Err(e),
                Ok(_) => check("sunset is on the trail", tr.trail_contains(db, cid, "company_sunset", item.id)),
              }
            },
          }
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_gate(), test_parse_proposal(), test_healthy_no_consult(), test_distress_proposes_once(), test_approval_revises_mission(), test_rejection_holds_course(), test_sunset_approved()]
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

