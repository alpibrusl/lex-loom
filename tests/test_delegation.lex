# test_delegation.lex — ORG2 (lex-loom#217): agent→agent delegation.
#
# The three ORG2 rules, each proven offline (no LLM, no network):
#
#   1. STRUCTURAL GATE — `offer` writes an assignment only when the ORG1 org
#      chart says the target reports to the delegator; refusals land on the
#      trail and create no row.
#   2. CLOSED VOCABULARY — a task kind outside `known_kinds()` is refused at
#      the same gate; the prompt frame per kind is fixed, the goal is data.
#   3. NORMAL EXECUTION — an accepted assignment materializes as an ordinary
#      sprint node (company_runner.drain_assignments) and the artifact lands
#      back on the assignment row, using the real orchestrator with a
#      proc-executor (`cat`) agent from the pool.
#
# The delegate tool itself is also exercised: its execute row is [net, io,
# proc] — it can only append a request line; authorization happens in
# `flush_delegations`, against the DB, after the fact.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "../src/migrate" as migrate

import "../src/org" as org

import "../src/delegation" as delegation

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

fn open_db() -> [sql, fs_write, random] Result[conn.ConnDb, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open memory db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

# docs reports to eng_manager, eng_manager reports to founder.
fn seed_org(db :: conn.ConnDb, cid :: Str) -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match org.parse_org_spec("docs:eng_manager,eng_manager:founder") {
    Err(e) => Err(e),
    Ok(edges) => org.save_org(db, cid, edges),
  }
}

fn seed_proc_pool_agent(db :: conn.ConnDb, role :: Str) -> [sql, fs_write, random, crypto] Result[Unit, Str] {
  let id := str.concat("proc-pool-", crypto.random_str_hex(6))
  let q := ormq.for_dialect({ sql: "INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, bounce_count, retired_at, created_at) VALUES (?, ?, '', 'proc:cat', '[]', 5, 0, '', '2026-01-01T00:00:00')", params: [PStr(id), PStr(role)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Closed vocabulary (pure) ─────────────────────────────────────────────────
fn test_vocabulary() -> Result[Unit, Str] {
  match check("vocabulary is exactly the four task kinds", list.len(delegation.known_kinds()) == 4) {
    Err(e) => Err(e),
    Ok(_) => match check("write_docs is a known kind", delegation.is_known_kind("write_docs")) {
      Err(e) => Err(e),
      Ok(_) => match check("free-form kinds are not known", not delegation.is_known_kind("run_arbitrary_shell")) {
        Err(e) => Err(e),
        Ok(_) => match check("goal is interpolated into the fixed frame", str.contains(delegation.prompt_for("write_tests", "cover the parser"), "cover the parser")) {
          Err(e) => Err(e),
          Ok(_) => check("frame is the kind's, not the goal's", str.starts_with(delegation.prompt_for("write_tests", "cover the parser"), "Delegated task — write tests")),
        },
      },
    },
  }
}

# ── Structural gate: may_assign derives from the org chart only ──────────────
fn test_may_assign_follows_org_chart() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org2-gate-", crypto.random_str_hex(6))
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match check("manager may assign to a direct report", delegation.may_assign(db, cid, "eng_manager", "docs")) {
          Err(e) => Err(e),
          Ok(_) => match check("a report may not assign upward", not delegation.may_assign(db, cid, "docs", "eng_manager")) {
            Err(e) => Err(e),
            Ok(_) => match check("grandparent is not a direct manager", not delegation.may_assign(db, cid, "founder", "docs")) {
              Err(e) => Err(e),
              Ok(_) => check("a flat company authorizes nobody", not delegation.may_assign(db, str.concat(cid, "-flat"), "eng_manager", "docs")),
            },
          },
        },
      }
    },
  }
}

# ── Offer: refusals leave a trail and no row; success leaves both ────────────
fn test_offer_gate_refusals() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org2-offer-", crypto.random_str_hex(6))
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => {
          let unknown := delegation.offer(db, cid, "eng_manager", "docs", "run_arbitrary_shell", "anything")
          let empty := delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "   ")
          let unauthorized := delegation.offer(db, cid, "docs", "eng_manager", "write_docs", "document the API")
          let ok := delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document the API")
          match check("unknown kind refused", match unknown {
            Err(m) => str.contains(m, "unknown task kind"),
            Ok(_) => false,
          }) {
            Err(e) => Err(e),
            Ok(_) => match check("empty goal refused", match empty {
              Err(m) => str.contains(m, "empty goal"),
              Ok(_) => false,
            }) {
              Err(e) => Err(e),
              Ok(_) => match check("no may_assign edge refused", match unauthorized {
                Err(m) => str.contains(m, "no may_assign authority"),
                Ok(_) => false,
              }) {
                Err(e) => Err(e),
                Ok(_) => match check("refusals are on the trail", tr.trail_contains(db, cid, "delegation_refused", "no may_assign edge")) {
                  Err(e) => Err(e),
                  Ok(_) => match ok {
                    Err(m) => Err(str.concat("authorized offer should succeed: ", m)),
                    Ok(id) => match check("authorized offer is on the trail", tr.trail_contains(db, cid, "assignment_offered", id)) {
                      Err(e) => Err(e),
                      Ok(_) => match check("exactly one assignment row exists", list.len(delegation.load_by_status(db, cid, "offered")) == 1) {
                        Err(e) => Err(e),
                        Ok(_) => match delegation.get_assignment(db, id) {
                          None => Err("offered assignment not readable back"),
                          Some(a) => check("goal survives the params_json round trip", a.goal == "document the API" and a.from_role == "eng_manager" and a.to_role == "docs" and a.status == "offered"),
                        },
                      },
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
}

# ── The delegate tool: append-only; authorization happens at flush ───────────
fn test_delegate_tool_flush() -> [io, net, proc, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org2-flush-", crypto.random_str_hex(6))
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => {
          let path := delegation.delegations_file(str.concat(cid, "-run"))
          let tool := delegation.delegate_tool(path)
          let exec := tool.execute
          let __c1 := exec(JObj([("to_role", JStr("docs")), ("kind", JStr("write_docs")), ("goal", JStr("write the changelog"))]))
          let __c2 := exec(JObj([("to_role", JStr("founder")), ("kind", JStr("write_docs")), ("goal", JStr("try to delegate upward"))]))
          match check("tool appended both request lines", list.len(list.filter(str.split(match io.read(path) {
            Ok(c) => c,
            Err(_) => "",
          }, "\n"), fn (l :: Str) -> Bool {
            not str.is_empty(str.trim(l))
          })) == 2) {
            Err(e) => Err(e),
            Ok(_) => {
              let n := delegation.flush_delegations(db, cid, "eng_manager", path)
              match check("only the org-authorized request became an assignment", n == 1) {
                Err(e) => Err(e),
                Ok(_) => match check("the unauthorized request was refused on the trail", tr.trail_contains(db, cid, "delegation_refused", "no may_assign edge")) {
                  Err(e) => Err(e),
                  Ok(_) => check("flush cleared the request file", str.is_empty(str.trim(match io.read(path) {
                    Ok(c) => c,
                    Err(_) => "",
                  }))),
                },
              }
            },
          }
        },
      }
    },
  }
}

# ── Materialization: an assignment runs as an ordinary sprint node ───────────
fn test_drain_materializes_assignment() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let cid := str.concat("org2-drain-", crypto.random_str_hex(6))
      let sprint_id := str.concat(cid, "/assign-iter")
      match seed_org(db, cid) {
        Err(e) => Err(e),
        Ok(_) => match seed_proc_pool_agent(db, "docs") {
          Err(e) => Err(e),
          Ok(_) => match delegation.offer(db, cid, "eng_manager", "docs", "write_docs", "document the delegation flow") {
            Err(m) => Err(str.concat("offer failed: ", m)),
            Ok(id) => {
              let ccfg :: company.CompanyCfg := { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
              let __d := company_runner.drain_assignments(db, ccfg, sprint_id, 50)
              match delegation.get_assignment(db, id) {
                None => Err("assignment vanished after drain"),
                Some(a) => match check("drained assignment is done", a.status == "done") {
                  Err(e) => Err(e),
                  Ok(_) => match check("the artifact landed on the assignment", not str.is_empty(a.artifact_ref)) {
                    Err(e) => Err(e),
                    Ok(_) => match check("completion is on the trail", tr.trail_contains(db, cid, "assignment_done", id)) {
                      Err(e) => Err(e),
                      Ok(_) => check("the node was cast under the org chart's authority", tr.trail_contains(db, sprint_id, "node_cast", "\"authority\":\"eng_manager\"")),
                    },
                  },
                },
              }
            },
          },
        },
      }
    },
  }
}

fn suite() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] List[Result[Unit, Str]] {
  [test_vocabulary(), test_may_assign_follows_org_chart(), test_offer_gate_refusals(), test_delegate_tool_flush(), test_drain_materializes_assignment()]
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

