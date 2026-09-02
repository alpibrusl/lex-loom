# demo/gov2_seed.lex — CLI scaffolding for demo/gov2-budget-envelope-roundtrip.sh.
#
# Drives GOV2 through ONLY real production functions (budget.*,
# company_runner.run_company, orchestrator.run_phase) — no reimplementation.
#
# Commands (DB_PATH + COMPANY_ID via env):
#   seed_cmd     — save the company (proc:cat model, 1 iteration max).
#   envelope_cmd — budget.set_envelope(SCOPE, CAP_CENTS, BY).
#   charge_cmd   — budget.charge(ROLE, CENTS) — a deterministic stand-in for
#                  the ledger charges nodes accrue.
#   run_cmd      — company_runner.run_company; prints stopped_by.
#   dispatch_cmd — one real run_phase with a docs node and a demo node
#                  (proc:cat roster); prints "node|attested|reason" rows.
#   report_cmd   — the budget utilization section the board report carries.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.int" as int

import "lex-orm/src/connection" as conn

import "lex-llm/src/providers" as providers

import "lex-trail/src/log" as tlog

import "../src/migrate" as migrate

import "../src/budget" as budget

import "../src/company" as company

import "../src/company_runner" as company_runner

import "../src/orchestrator" as orch

import "../src/cast" as cast

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None => default,
    Some(v) => if str.is_empty(v) {
      default
    } else {
      v
    },
  }
}

fn open_db() -> [env, sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(get_env("DB_PATH", "company.db")) {
    Err(_) => Err("open db failed"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

fn mk_ccfg(cid :: Str) -> company.CompanyCfg {
  { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }
}

fn seed_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => {
      let __c := company.save_company(db, mk_ccfg(cid))
      io.print(str.join(["[gov2-seed] ", cid, " saved"], ""))
    },
  }
}

fn envelope_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => match budget.set_envelope(db, cid, get_env("SCOPE", "total"), match str.to_int(get_env("CAP_CENTS", "0")) {
      Some(c) => c,
      None => 0,
    }, get_env("BY", "board-jane")) {
      Err(m) => io.print(str.concat("[gov2-seed] refused: ", m)),
      Ok(_) => io.print(str.join(["[gov2-seed] envelope ", get_env("SCOPE", "total"), " set"], "")),
    },
  }
}

fn charge_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => {
      let cents := match str.to_int(get_env("CENTS", "0")) {
        Some(c) => c,
        None => 0,
      }
      let __c := budget.charge(db, cid, get_env("ROLE", "docs"), cents)
      io.print(str.join(["[gov2-seed] charged ", int.to_str(cents), "c to ", get_env("ROLE", "docs")], ""))
    },
  }
}

fn run_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => {
      let res := company_runner.run_company(db, mk_ccfg(cid), 1, false)
      io.print(str.join(["[gov2-seed] ", cid, ": iterations=", int.to_str(res.iterations), " stopped_by=", res.stopped_by], ""))
    },
  }
}

fn proc_agent(node_id :: Str, role :: Str) -> [env] cast.RosterEntry {
  { node_id: node_id, pool_agent_id: str.concat("proc-", node_id), agent_config: { id: str.concat("proc-", node_id), kind: role, system_prompt: "", model_name: "proc:cat", provider: providers.ollama_local(), tools: [], proc_cmd: "cat", a2a_url: "", sprint_id: "" } }
}

fn dispatch_cmd() -> [env, io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, vcs, approval] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  let sid := str.concat(cid, "/iter-dispatch")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => {
      let g := { id: sid, phase: Implementation, nodes: [{ id: "write", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "summarize", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
      let trail_none :: Option[tlog.Log] := None
      let cfg := { id: sid, request: "demo request", model: "proc:cat", db: db, api_calls_max: 50, roster: [proc_agent("write", "docs"), proc_agent("summarize", "demo")], trail_log: trail_none, review_transitions: false, depth: 0, iter_ctx: None, exec_mode: "inline", policy_isolation: "" }
      let pr := orch.run_phase(g, Implementation, "", [], cfg)
      let __each := list.map(pr.outcomes, fn (o :: orch.NodeOutcome) -> [io] Unit {
        io.print(str.join([o.node_id, "|", if o.attested {
          "attested"
        } else {
          "refused"
        }, "|", o.reason], ""))
      })
      ()
    },
  }
}

fn report_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "gov2co")
  match open_db() {
    Err(e) => io.print(str.concat("[gov2-seed] FATAL: ", e)),
    Ok(db) => io.print(budget.report_section(db, cid)),
  }
}

