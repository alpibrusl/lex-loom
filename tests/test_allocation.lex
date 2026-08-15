# test_allocation.lex — GOV3 (lex-loom#223): the allocation loop.
#
# All offline (proc-executor agents, no LLM, no network):
#
#   1. STRICT PARSING — only exact-JSON revise proposals with valid scopes,
#      positive cents, and a falsifiable prediction count; everything else
#      is None.
#   2. MECHANICAL GATE — no envelopes or no verified revenue reading = the
#      finance agent is never consulted.
#   3. ADVISORY-UNTIL-APPROVED — a proposal parks before the board and
#      envelopes DO NOT change; there is no code path from proposal to
#      envelope change without a board decision. No duplicates while
#      pending.
#   4. APPROVAL applies the changes as the approving board member (GOV2's
#      budget_envelope_set trail names them); REJECTION changes nothing and
#      is ledgered.
#   5. GRADING — once the predicted iteration is reached, the applied
#      allocation is graded hit/miss against the CURRENT verified revenue,
#      trailed, and the hit rate feeds the next proposal's evidence.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.int" as int

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/allocation" as allocation

import "../src/budget" as budget

import "../src/company" as company

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-gov3-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "sell widgets", model: "proc:cat", max_iterations: 5, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_iteration(db :: conn.ConnDb, cid :: Str, idx :: Int, status :: Str) -> [sql, fs_write, time] Unit {
  let __r := company.record_iteration(db, { company_id: cid, idx: idx, sprint_id: str.join([cid, "/iter-", int.to_str(idx)], ""), parent_sprint_id: "", status: "running", goal: "g" })
  let __f := company.finish_iteration(db, cid, idx, status)
  ()
}

fn seed_finance_agent(db :: conn.ConnDb, model_name :: Str) -> [sql, fs_write, random, crypto] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, 'finance', '', ?, '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(str.concat("fin-agent-", crypto.random_str_hex(6))), PStr(model_name)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn revise_model() -> Str {
  "proc:echo '{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 2000}, {\"scope\": \"role:docs\", \"cap_cents\": 500}], \"rationale\": \"revenue is real, fund the docs push\", \"prediction\": {\"target_cents\": 500, \"by_iteration\": 2}}'"
}

fn seed_revenue(db :: conn.ConnDb, cid :: Str, idx :: Int, cents_json :: Str) -> [sql, time] Unit {
  let __r := company.record_operate_signal(db, cid, idx, "revenue_cents", cents_json)
  ()
}

fn cap_of(db :: conn.ConnDb, cid :: Str, scope :: Str) -> [sql, fs_read] Int {
  match budget.envelope_for(db, cid, scope) {
    None => 0 - 1,
    Some(e) => e.cap_cents,
  }
}

# A distressed-but-funded company ready for an allocation proposal.
fn ready_company(db :: conn.ConnDb, cid :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  let __c := company.save_company(db, mk_ccfg(cid))
  let __e := budget.set_envelope(db, cid, "total", 1000, "founder")
  let __i := seed_iteration(db, cid, 1, "success")
  let __r := seed_revenue(db, cid, 1, "{\"revenue_cents\": 100}")
  seed_finance_agent(db, revise_model())
}

# ── 1. Strict parsing ────────────────────────────────────────────────────────
fn test_parse() -> Result[Unit, Str] {
  match check("none parses", match allocation.parse_proposal("{\"allocation\": \"none\"}") {
    Some(p) => p.kind == "none",
    None => false,
  }) {
    Err(e) => Err(e),
    Ok(_) => match check("valid revise parses with changes + prediction", match allocation.parse_proposal("{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 2000}], \"rationale\": \"r\", \"prediction\": {\"target_cents\": 500, \"by_iteration\": 3}}") {
      Some(p) => p.kind == "revise" and list.len(p.changes) == 1 and p.target_cents == 500 and p.by_iteration == 3,
      None => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => match check("revise WITHOUT a prediction is refused (falsifiability required)", match allocation.parse_proposal("{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 2000}]}") {
        Some(_) => false,
        None => true,
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("invalid scope refused", match allocation.parse_proposal("{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"role:warp\", \"cap_cents\": 10}], \"prediction\": {\"target_cents\": 1, \"by_iteration\": 1}}") {
          Some(_) => false,
          None => true,
        }) {
          Err(e) => Err(e),
          Ok(_) => match check("non-positive cents refused", match allocation.parse_proposal("{\"allocation\": \"revise\", \"changes\": [{\"scope\": \"total\", \"cap_cents\": 0}], \"prediction\": {\"target_cents\": 1, \"by_iteration\": 1}}") {
            Some(_) => false,
            None => true,
          }) {
            Err(e) => Err(e),
            Ok(_) => check("prose is refused", match allocation.parse_proposal("we should raise the budget") {
              Some(_) => false,
              None => true,
            }),
          },
        },
      },
    },
  }
}

# ── 2. The mechanical gate ───────────────────────────────────────────────────
fn test_gate() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov3-gate-", crypto.random_str_hex(6))
      let __c := company.save_company(db, mk_ccfg(cid))
      match check("no envelopes: never consulted", not allocation.should_consult(db, cid)) {
        Err(e) => Err(e),
        Ok(_) => {
          let __e := budget.set_envelope(db, cid, "total", 1000, "founder")
          match check("envelopes but no verified revenue: never consulted", not allocation.should_consult(db, cid)) {
            Err(e) => Err(e),
            Ok(_) => {
              let __r := seed_revenue(db, cid, 1, "{\"revenue_cents\": 100}")
              check("envelopes + verified revenue: consulted", allocation.should_consult(db, cid))
            },
          }
        },
      }
    },
  }
}

# ── 3 + 4. Advisory until approved; apply as the approver; reject stands ─────
fn test_propose_approve_reject() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("gov3-flow-", crypto.random_str_hex(6))
      match ready_company(db, cid) {
        Err(e) => Err(e),
        Ok(_) => {
          let __hb := allocation.heartbeat(db, cid, 50)
          match list.head(tr.attention_pending_for_sprint(db, str.concat(cid, "/allocation"))) {
            None => Err("expected a pending allocation proposal"),
            Some(item) => match check("proposal goes to the board with evidence", item.oracle == "board" and not str.is_empty(item.artifact_hash)) {
              Err(e) => Err(e),
              Ok(_) => match check("NO envelope change without a board decision", cap_of(db, cid, "total") == 1000 and cap_of(db, cid, "role:docs") == 0 - 1) {
                Err(e) => Err(e),
                Ok(_) => {
                  let __hb2 := allocation.heartbeat(db, cid, 50)
                  match check("no duplicate proposal while pending", list.len(tr.attention_pending_for_sprint(db, str.concat(cid, "/allocation"))) == 1) {
                    Err(e) => Err(e),
                    Ok(_) => {
                      let __r := tr.resolve_attention(db, item.id, "approved", "", "board-jane")
                      let __hb3 := allocation.heartbeat(db, cid, 50)
                      match check("approval applies BOTH changes", cap_of(db, cid, "total") == 2000 and cap_of(db, cid, "role:docs") == 500) {
                        Err(e) => Err(e),
                        Ok(_) => match check("envelope changes are attributed to the approver", tr.trail_contains(db, cid, "budget_envelope_set", "board-jane")) {
                          Err(e) => Err(e),
                          Ok(_) => match check("allocation ledgered as applied, prediction pending", match list.head(allocation.load_allocations(db, cid, "applied")) {
                            Some(a) => a.grade == "pending" and a.predicted_target_cents == 500,
                            None => false,
                          }) {
                            Err(e) => Err(e),
                            Ok(_) => {
                              let cid2 := str.concat("gov3-rej-", crypto.random_str_hex(6))
                              match ready_company(db, cid2) {
                                Err(e) => Err(e),
                                Ok(_) => {
                                  let __h1 := allocation.heartbeat(db, cid2, 50)
                                  match list.head(tr.attention_pending_for_sprint(db, str.concat(cid2, "/allocation"))) {
                                    None => Err("expected a pending proposal for the reject case"),
                                    Some(item2) => {
                                      let __r2 := tr.resolve_attention(db, item2.id, "rejected", "not yet", "board-jane")
                                      let __h2 := allocation.heartbeat(db, cid2, 50)
                                      match check("rejection: envelopes stand", cap_of(db, cid2, "total") == 1000) {
                                        Err(e) => Err(e),
                                        Ok(_) => match check("rejection ledgered", match list.head(allocation.load_allocations(db, cid2, "rejected")) {
                                          Some(_) => true,
                                          None => false,
                                        }) {
                                          Err(e) => Err(e),
                                          Ok(_) => check("rejection on the trail with the board's reason", tr.trail_contains(db, cid2, "allocation_rejected", "not yet")),
                                        },
                                      }
                                    },
                                  }
                                },
                              }
                            },
                          },
                        },
                      }
                    },
                  }
                },
              },
            },
          }
        },
      }
    },
  }
}

# ── 5. Grading against the prediction ────────────────────────────────────────
fn graded_flow(db :: conn.ConnDb, cid :: Str, revenue_at_2 :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Str, Str] {
  match ready_company(db, cid) {
    Err(e) => Err(e),
    Ok(_) => {
      let __h1 := allocation.heartbeat(db, cid, 50)
      match list.head(tr.attention_pending_for_sprint(db, str.concat(cid, "/allocation"))) {
        None => Err("no proposal"),
        Some(item) => {
          let __r := tr.resolve_attention(db, item.id, "approved", "", "board-jane")
          let __h2 := allocation.heartbeat(db, cid, 50)
          let __i2 := seed_iteration(db, cid, 2, "success")
          let __rev := seed_revenue(db, cid, 2, revenue_at_2)
          let __h3 := allocation.heartbeat(db, cid, 50)
          match list.head(allocation.load_allocations(db, cid, "applied")) {
            None => Err("applied allocation missing"),
            Some(a) => Ok(a.grade),
          }
        },
      }
    },
  }
}

fn test_grading() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let hit_cid := str.concat("gov3-hit-", crypto.random_str_hex(6))
      match graded_flow(db, hit_cid, "{\"revenue_cents\": 600}") {
        Err(e) => Err(e),
        Ok(g1) => match check("prediction met -> graded hit", g1 == "hit") {
          Err(e) => Err(e),
          Ok(_) => match check("grade is on the trail", tr.trail_contains(db, hit_cid, "allocation_graded", "hit")) {
            Err(e) => Err(e),
            Ok(_) => match check("hit rate feeds the next evidence", str.contains(allocation.hit_rate_line(db, hit_cid), "1 of 1")) {
              Err(e) => Err(e),
              Ok(_) => {
                let miss_cid := str.concat("gov3-miss-", crypto.random_str_hex(6))
                match graded_flow(db, miss_cid, "{\"revenue_cents\": 120}") {
                  Err(e) => Err(e),
                  Ok(g2) => match check("prediction missed -> graded miss", g2 == "miss") {
                    Err(e) => Err(e),
                    Ok(_) => check("miss is on the trail", tr.trail_contains(db, miss_cid, "allocation_graded", "miss")),
                  },
                }
              },
            },
          },
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_parse(), test_gate(), test_propose_approve_reject(), test_grading()]
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

