# demo/operate_loop.lex — CLI scaffolding for demo/run_operate_loop.sh (#118).
#
# Everything the Operate loop v1 actually does — sensing, diagnosis, contract
# proposal, verification — is pure Lex + SQL, no LLM. This demo proves the
# whole loop end to end against a REAL toy HTTP server (demo/toy_target.py)
# instead of fabricated test fixtures: a real curl connection failure opens
# a real server_down incident, a real measured latency spike opens a real
# degraded_latency incident, and — because the demo lets the toy server
# recover — the effect contracts the loop proposes for both should actually
# MATERIALISE once the deadline arrives, the same way a real remediation
# earning trust would.
#
# Only the seeding here is demo-only. `run_round_cmd` calls the same
# `company.check_and_record_liveness` the real iteration loop and
# `company_monitor_cmd` call — this demo exercises production code, not a
# reimplementation of it.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/company" as company

import "../src/effects" as effects

import "lex-ctl/src/tier" as ktier

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

fn open_db(db_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(db_path) {
    Err(_) => Err(str.concat("open db failed: ", db_path)),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate failed: ", e)),
      Ok(_) => Ok(db),
    },
  }
}

# One-time setup: a minimal company row so `board_report_cmd` and
# `check_and_record_liveness`/`operate_sweep` (called via `run_round_cmd`)
# have something to attach to.
fn seed_company_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let db_path := get_env("DB_PATH", "demo/operate-loop-demo.db")
  let company_id := get_env("COMPANY_ID", "operate-demo")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[operate-demo] FATAL: ", e)),
    Ok(db) => match company.save_company(db, { id: company_id, goal: "toy target for the Operate loop v1 demo", model: "none", max_iterations: 0, stop_when: "never", pmf_when: "never", maintenance_when: "never", wake_when: "never", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: "" }) {
      Err(e) => io.print(str.concat("[operate-demo] FATAL save_company: ", e)),
      Ok(_) => io.print(str.join(["[operate-demo] company seeded: ", company_id], "")),
    },
  }
}

# A "launch" artifact for this round's synthetic sprint_id, pointing at the
# toy server — the exact shape `company.find_launch_url` looks for
# (`{"url": ...}` in the artifact with the highest-content-length node_id
# LIKE '%launch%' for that sprint_id).
fn insert_launch_artifact(db :: conn.ConnDb, company_id :: Str, idx :: Int, url :: Str) -> [sql] Result[Unit, Str] {
  let sprint_id := company.iteration_sprint_id(company_id, idx)
  let node_id := str.join(["launch-", int.to_str(idx)], "")
  let hash := str.join(["demo-artifact-", company_id, "-", int.to_str(idx)], "")
  let content := str.join(["{\"ok\":true,\"url\":\"", url, "\"}"], "")
  let q := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO artifacts (hash, sprint_id, node_id, content, created_at) VALUES (?, ?, ?, ?, ?)", params: [PStr(hash), PStr(sprint_id), PStr(node_id), PStr(content), PStr("")] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Runs exactly one round: seed this round's iteration + launch artifact
# (so `find_launch_url` resolves to the toy server for THIS idx's
# sprint_id), then call the real `check_and_record_liveness` — which, since
# #145, also runs `operate_sweep` (CTL4 diagnosis + CTL5 propose/verify) at
# the end of the same call.
fn run_round_cmd() -> [env, io, sql, fs_read, fs_write, time, proc] Unit {
  let db_path := get_env("DB_PATH", "demo/operate-loop-demo.db")
  let company_id := get_env("COMPANY_ID", "operate-demo")
  let idx := match str.to_int(get_env("IDX", "1")) {
    Some(n) => n,
    None => 1,
  }
  let url := get_env("TARGET_URL", "http://127.0.0.1:8999")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[operate-demo] FATAL: ", e)),
    Ok(db) => {
      let sprint_id := company.iteration_sprint_id(company_id, idx)
      match company.record_iteration(db, { company_id: company_id, idx: idx, sprint_id: sprint_id, parent_sprint_id: "", status: "running", goal: "toy target" }) {
        Err(e) => io.print(str.concat("[operate-demo] FATAL record_iteration: ", e)),
        Ok(_) => match insert_launch_artifact(db, company_id, idx, url) {
          Err(e) => io.print(str.concat("[operate-demo] FATAL insert_launch_artifact: ", e)),
          Ok(_) => match company.check_and_record_liveness(db, company_id, idx, sprint_id) {
            Err(e) => io.print(str.join(["[operate-demo] round ", int.to_str(idx), " FAILED: ", e], "")),
            Ok(_) => io.print(str.join(["[operate-demo] round ", int.to_str(idx), " done (target=", url, ")"], "")),
          },
        },
      }
    },
  }
}

# CTL6's promotion gate for one action class, for eyeballing at the end of
# the demo — with only 1-2 samples this will never clear the real >=30
# threshold, but the hit rate on however many samples exist shows whether
# the loop's predictions actually held.
fn promotion_status_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let db_path := get_env("DB_PATH", "demo/operate-loop-demo.db")
  let company_id := get_env("COMPANY_ID", "operate-demo")
  let class_key := get_env("CLASS_KEY", "restart")
  match open_db(db_path) {
    Err(e) => io.print(str.concat("[operate-demo] FATAL: ", e)),
    Ok(db) => {
      let s := effects.class_promotion_status(db, company_id, class_key)
      io.print(str.join(["[operate-demo] class=", s.class_key, " samples=", int.to_str(s.samples), " hit_rate_pct=", int.to_str(s.hit_rate_pct), " ceiling=", tier_to_str(s.ceiling), " promotable=", if s.promotable {
        "true"
      } else {
        "false"
      }], ""))
    },
  }
}

fn tier_to_str(t :: ktier.Tier) -> Str {
  match t {
    Auto => "Auto",
    Propose => "Propose",
    Escalate => "Escalate",
  }
}

