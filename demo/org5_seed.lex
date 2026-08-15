# demo/org5_seed.lex — CLI scaffolding for demo/org5-role-registry-roundtrip.sh.
#
# Drives ORG5 through ONLY real production functions (role_registry.*,
# cast.cast_node, company.save_company) — no reimplementation.
#
# Commands (DB_PATH + COMPANY_ID via env):
#   save_cmd     — save a company row (POLICY_ISOLATION env, e.g. "ceiling:Demo").
#   castable_cmd — print castable_kinds as a comma-separated line.
#   propose_cmd  — registry.propose_role(KIND, PROMPT, TOOLS, PRESET, BY).
#   apply_cmd    — registry.apply_resolved (the scheduler-heartbeat pass).
#   cast_cmd     — cast.cast_node for ROLE with a proc:cat model; prints "id|kind".
#   defs_cmd     — role_defs ledger rows as "kind|status|grant|proposed_by|approved_by".

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/role_registry" as registry

import "../src/cast" as cast

import "../src/company" as company

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

fn save_cmd() -> [env, io, sql, fs_read, fs_write, time] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => {
      let cfg :: company.CompanyCfg := { id: cid, goal: "demo goal", model: "proc:cat", max_iterations: 1, stop_when: "", pmf_when: "", maintenance_when: "", wake_when: "", soft_mesh_url: "", soft_org_id: "", soft_roles: "", soft_settlement: "", policy_isolation: get_env("POLICY_ISOLATION", "") }
      let __c := company.save_company(db, cfg)
      io.print(str.join(["[org5-seed] ", cid, " saved (policy_isolation='", cfg.policy_isolation, "')"], ""))
    },
  }
}

fn castable_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => io.print(str.join(registry.castable_kinds(db, cid), ",")),
  }
}

fn propose_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto, vcs] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => match registry.propose_role(db, cid, get_env("KIND", "growth_hacker"), get_env("PROMPT", "You are the Growth Hacker. Propose concrete distribution experiments grounded in the product's real usage signals."), get_env("TOOLS", "none"), get_env("PRESET", "Demo"), get_env("BY", "ceo")) {
      Ok(att) => io.print(str.concat("[org5-seed] proposal queued for the board: ", att)),
      Err(m) => io.print(str.concat("[org5-seed] ", m)),
    },
  }
}

fn apply_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => registry.apply_resolved(db, cid),
  }
}

fn cast_cmd() -> [env, io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  let role := get_env("ROLE", "growth_hacker")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => {
      let node := { id: str.concat("demo-", role), role: role, gate: "spec non-empty", expand: None, activate_when: "" }
      let entry := cast.cast_node(db, node, "demo request", "proc:cat", str.concat(cid, "/iter-demo"))
      io.print(str.join([entry.agent_config.id, "|", entry.agent_config.kind], ""))
    },
  }
}

type DefRow = { kind :: Str, status :: Str, grant_preset :: Str, proposed_by :: Str, approved_by :: Str }

fn defs_cmd() -> [env, io, sql, fs_read, fs_write] Unit {
  let cid := get_env("COMPANY_ID", "org5co")
  match open_db() {
    Err(e) => io.print(str.concat("[org5-seed] FATAL: ", e)),
    Ok(db) => {
      let statuses := ["proposed", "active", "refused"]
      let __each := list.map(statuses, fn (s :: Str) -> [env, io, sql, fs_read] Unit {
        let __rows := list.map(registry.load_defs(db, cid, s), fn (d :: registry.RoleDef) -> [io] Unit {
          io.print(str.join([d.kind, "|", d.status, "|", d.grant_preset, "|", d.proposed_by, "|", d.approved_by], ""))
        })
        ()
      })
      ()
    },
  }
}

