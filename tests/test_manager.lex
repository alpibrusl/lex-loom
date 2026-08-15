# test_manager.lex — ORG3 (lex-loom#218): manager review, attestation, report.
#
# All offline (proc-executor agents, no LLM, no network):
#
#   1. VERDICT PARSING is mechanical — clean JSON, prose-embedded verdict
#      strings, ambiguity and garbage each do exactly one thing.
#   2. ACCEPT FLOW — a manager's accept approves the assignment AND lands a
#      positive attestation on the worker's pool agent.
#   3. RETURN → REWORK → FINAL — returns are bounded by
#      delegation.max_rework_rounds(); each return bounces the worker, and a
#      repeatedly-returned worker retires per cast.lex's existing <= -3 rule
#      (manager judgment drives the SAME promotion/demotion ledger).
#   4. UNPARSEABLE REVIEW changes nothing — refuse, don't downgrade.
#   5. REPORTS — the manager's aggregate report (not raw artifacts) is what
#      the Strategist's prompt consumes.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/org" as org

import "../src/delegation" as delegation

import "../src/manager" as manager

import "../src/company" as company

import "../src/company_runner" as company_runner

import "../src/transport" as tr

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

# agent_pool casting is role-scoped, not company-scoped — so each test gets
# its OWN file DB (#242), or every test would cast the previous test's
# manager agent.
fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-org3-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_org(db :: conn.ConnDb, cid :: Str) -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match org.parse_org_spec("docs:eng_manager,eng_manager:founder") {
    Err(e) => Err(e),
    Ok(edges) => org.save_org(db, cid, edges),
  }
}

fn seed_pool_agent(db :: conn.ConnDb, id :: Str, role :: Str, model_name :: Str, attestation :: Int) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, '', ?, '[]', ?, 0, '', '2026-01-01T00:00:00')", params: [PStr(id), PStr(role), PStr(model_name), PInt(attestation)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn accept_manager_model() -> Str {
  "proc:echo '{\"verdict\": \"accept\", \"notes\": \"solid work\"}'"
}

fn return_manager_model() -> Str {
  "proc:echo '{\"verdict\": \"return\", \"notes\": \"add error handling\"}'"
}

type PoolStateRow = { attestation_count :: Int, bounce_count :: Int, retired_at :: Str }

fn pool_state(db :: conn.ConnDb, agent_id :: Str) -> [sql, fs_read] Option[PoolStateRow] {
  let q := ormq.for_dialect({ sql: "SELECT attestation_count, bounce_count, retired_at FROM agent_pool WHERE id=?", params: [PStr(agent_id)] }, db.dialect)
  let rows :: Result[List[PoolStateRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

# ── 1. Verdict parsing (pure) ────────────────────────────────────────────────
fn test_parse_verdict() -> Result[Unit, Str] {
  match check("clean accept parses", match manager.parse_verdict("{\"verdict\": \"accept\"}") {
    Some(v) => v.accept,
    None => false,
  }) {
    Err(e) => Err(e),
    Ok(_) => match check("return carries the notes", match manager.parse_verdict("{\"verdict\": \"return\", \"notes\": \"tighten the spec\"}") {
      Some(v) => not v.accept and v.notes == "tighten the spec",
      None => false,
    }) {
      Err(e) => Err(e),
      Ok(_) => match check("prose-embedded accept still counts", match manager.parse_verdict("Sure! Here is my verdict: {\"verdict\":\"accept\"} — great job.") {
        Some(v) => v.accept,
        None => false,
      }) {
        Err(e) => Err(e),
        Ok(_) => match check("garbage is None", match manager.parse_verdict("I think it looks fine overall") {
          Some(_) => false,
          None => true,
        }) {
          Err(e) => Err(e),
          Ok(_) => check("ambiguous output is None", match manager.parse_verdict("either {\"verdict\":\"accept\"} or {\"verdict\":\"return\"}") {
            Some(_) => false,
            None => true,
          }),
        },
      },
    },
  }
}

# ── 2. Accept flow: approval + positive attestation ──────────────────────────
fn test_accept_flow() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org3-accept-", crypto.random_str_hex(6))
      let worker_id := str.concat(cid, "-worker")
      let mgr_id := str.concat(cid, "-mgr")
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match seed_pool_agent(db, worker_id, "docs", "proc:cat", 5) {
          Err(e) => Err(e),
          Ok(_) => match seed_pool_agent(db, mgr_id, "eng_manager", accept_manager_model(), 5) {
            Err(e) => Err(e),
            Ok(_) => match delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document the review loop") {
              Err(m) => Err(str.concat("offer failed: ", m)),
              Ok(id) => {
                let ccfg := mk_ccfg(cid)
                let sprint := str.concat(cid, "/iter-review")
                let __d := company_runner.drain_assignments(db, ccfg, sprint, 50)
                let n := manager.review_assignments(db, ccfg, sprint, 50)
                match check("exactly one review conducted", n == 1) {
                  Err(e) => Err(e),
                  Ok(_) => match delegation.get_assignment(db, id) {
                    None => Err("assignment vanished"),
                    Some(a) => match check("manager accept approves the assignment", a.status == "approved") {
                      Err(e) => Err(e),
                      Ok(_) => match check("worker recorded on the assignment", a.worker_agent_id == worker_id) {
                        Err(e) => Err(e),
                        Ok(_) => match check("artifact survives approval", not str.is_empty(a.artifact_ref)) {
                          Err(e) => Err(e),
                          Ok(_) => match pool_state(db, worker_id) {
                            None => Err("worker pool agent missing"),
                            Some(p) => match check("accept is a positive attestation on the worker", p.attestation_count == 6) {
                              Err(e) => Err(e),
                              Ok(_) => check("approval is on the trail", tr.trail_contains(db, cid, "assignment_approved", id)),
                            },
                          },
                        },
                      },
                    },
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

# ── 3. Return -> rework (bounded) -> final return; worker demotes ────────────
fn drain_and_review(db :: conn.ConnDb, ccfg :: company.CompanyCfg, sprint :: Str) -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let __d := company_runner.drain_assignments(db, ccfg, sprint, 50)
  let __r := manager.review_assignments(db, ccfg, sprint, 50)
  ()
}

fn test_return_rework_cap_and_demotion() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org3-return-", crypto.random_str_hex(6))
      let worker_id := str.concat(cid, "-worker")
      let mgr_id := str.concat(cid, "-mgr")
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match seed_pool_agent(db, worker_id, "docs", "proc:cat", 0) {
          Err(e) => Err(e),
          Ok(_) => match seed_pool_agent(db, mgr_id, "eng_manager", return_manager_model(), 5) {
            Err(e) => Err(e),
            Ok(_) => match delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document the rework loop") {
              Err(m) => Err(str.concat("offer failed: ", m)),
              Ok(id) => {
                let ccfg := mk_ccfg(cid)
                let sprint := str.concat(cid, "/iter-rework")
                let __r1 := drain_and_review(db, ccfg, sprint)
                let after1 := delegation.get_assignment(db, id)
                match check("first return sends to rework with the notes", match after1 {
                  Some(a) => a.status == "rework" and a.rework_count == 1 and str.contains(a.reason, "add error handling"),
                  None => false,
                }) {
                  Err(e) => Err(e),
                  Ok(_) => {
                    let __r2 := drain_and_review(db, ccfg, sprint)
                    let after2 := delegation.get_assignment(db, id)
                    match check("second return still within the rework cap", match after2 {
                      Some(a) => a.status == "rework" and a.rework_count == 2,
                      None => false,
                    }) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let __r3 := drain_and_review(db, ccfg, sprint)
                        match delegation.get_assignment(db, id) {
                          None => Err("assignment vanished"),
                          Some(a) => match check("past the cap the return is FINAL", a.status == "returned") {
                            Err(e) => Err(e),
                            Ok(_) => match check("rework trail exists", tr.trail_contains(db, cid, "assignment_rework", id)) {
                              Err(e) => Err(e),
                              Ok(_) => match check("final return is on the trail with the escalation chain", tr.trail_contains(db, cid, "assignment_returned", "eng_manager -> founder")) {
                                Err(e) => Err(e),
                                Ok(_) => match pool_state(db, worker_id) {
                                  None => Err("worker pool agent missing"),
                                  Some(p) => match check("three returns drove the worker to -3", p.attestation_count == -3 and p.bounce_count == 3) {
                                    Err(e) => Err(e),
                                    Ok(_) => check("repeatedly-returned worker retires per cast.lex rules", not str.is_empty(p.retired_at)),
                                  },
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
            },
          },
        },
      }
    },
  }
}

# ── 4. Unparseable review changes nothing ────────────────────────────────────
fn test_unparseable_review_holds_state() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org3-noparse-", crypto.random_str_hex(6))
      let worker_id := str.concat(cid, "-worker")
      let mgr_id := str.concat(cid, "-mgr")
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match seed_pool_agent(db, worker_id, "docs", "proc:cat", 5) {
          Err(e) => Err(e),
          Ok(_) => match seed_pool_agent(db, mgr_id, "eng_manager", "proc:cat", 5) {
            Err(e) => Err(e),
            Ok(_) => match delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document something") {
              Err(m) => Err(str.concat("offer failed: ", m)),
              Ok(id) => {
                let ccfg := mk_ccfg(cid)
                let sprint := str.concat(cid, "/iter-noparse")
                let __r := drain_and_review(db, ccfg, sprint)
                match delegation.get_assignment(db, id) {
                  None => Err("assignment vanished"),
                  Some(a) => match check("assignment stays done (re-reviewed next iteration)", a.status == "done") {
                    Err(e) => Err(e),
                    Ok(_) => match pool_state(db, worker_id) {
                      None => Err("worker pool agent missing"),
                      Some(p) => match check("no attestation moved on an unparseable review", p.attestation_count == 5 and p.bounce_count == 0) {
                        Err(e) => Err(e),
                        Ok(_) => check("the non-verdict is on the trail", tr.trail_contains(db, cid, "manager_review_unparseable", id)),
                      },
                    },
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

# ── 5. Reports flow upward; the Strategist consumes the summary ──────────────
fn test_reports_reach_the_strategist() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org3-report-", crypto.random_str_hex(6))
      let worker_id := str.concat(cid, "-worker")
      let mgr_id := str.concat(cid, "-mgr")
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match seed_pool_agent(db, worker_id, "docs", "proc:cat", 5) {
          Err(e) => Err(e),
          Ok(_) => match seed_pool_agent(db, mgr_id, "eng_manager", accept_manager_model(), 5) {
            Err(e) => Err(e),
            Ok(_) => match delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document the report") {
              Err(m) => Err(str.concat("offer failed: ", m)),
              Ok(_) => {
                let ccfg := mk_ccfg(cid)
                let sprint := str.concat(cid, "/iter-report")
                let __r := drain_and_review(db, ccfg, sprint)
                let __filed := manager.record_reports(db, cid)
                let section := manager.reports_section(db, cid)
                match check("section names the manager's team", str.contains(section, "eng_manager team: 1 approved")) {
                  Err(e) => Err(e),
                  Ok(_) => match check("section summarizes, not raw artifacts", str.contains(section, "write_docs -> docs: approved")) {
                    Err(e) => Err(e),
                    Ok(_) => match check("report filing is on the trail", tr.trail_contains(db, cid, "manager_report", "eng_manager")) {
                      Err(e) => Err(e),
                      Ok(_) => {
                        let ctx := { idx: 1, last_verdict: "accepted", digest_summary: "", accepted_count: 1, bounced_count: 0, spend_cents: 0 }
                        let prompt := company_runner.strategist_prompt("mission", "shipped", [], "op", "ps", "ec", "di", "bs", section, "goal", ctx)
                        match check("strategist prompt carries the manager report", str.contains(prompt, "eng_manager team: 1 approved")) {
                          Err(e) => Err(e),
                          Ok(_) => check("strategist prompt frames it as the summary channel", str.contains(prompt, "Management reports")),
                        }
                      },
                    },
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
  [test_parse_verdict(), test_accept_flow(), test_return_rework_cap_and_demotion(), test_unparseable_review_holds_state(), test_reports_reach_the_strategist()]
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

