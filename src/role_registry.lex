# role_registry.lex — ORG5 (lex-loom#220): the data-driven roster.
#
# Three mechanisms, all structural:
#
#   1. PACKS. [roles].packs in company.toml names which optional role sets
#      the company staffs. The pack vocabulary is a closed registry here;
#      an unknown pack REFUSES the launch (never a half-staffed company).
#      No [roles] declared = every builtin role castable, exactly as before.
#   2. BOUNDED RUNTIME ROLE CREATION. An agent (CEO/manager) may PROPOSE a
#      new role definition — prompt, tool profile, grant preset — but it
#      becomes castable only after (a) structural checks at write time:
#      the tool profile must borrow an EXISTING role's tool budget (no
#      novel tool synthesis) and the grant preset must be WITHIN the
#      company's grant ceiling (manifests.grant_within — installing never
#      widens; an agent-authored role can never carry a grant its company
#      doesn't already hold), and (b) BOARD approval through the same
#      attention queue as every other human decision.
#   3. LEDGER. The role_defs row itself is the ledger: who proposed, what
#      grants, who approved — plus role_proposed / role_refused /
#      role_activated / role_rejected trail events.
#
# Builtin roles stay defined in roles.lex's builtin_specs data list (single
# source of truth for their prompts/tools); this registry only ever ADDS
# roles below the company's ceiling, and cast.lex consults it exactly when
# the builtin dispatch misses.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "lex-schema/json_value" as jv

import "./role_kinds" as role_kinds

import "./manifests" as manifests

import "./transport" as tr

import "./roles" as roles

import "./agent/runner" as runner

import "./company" as company

fn roles_sprint(company_id :: Str) -> Str {
  str.concat(company_id, "/roles")
}

# ── Packs: a closed vocabulary of optional role sets ─────────────────────────
# "core" is always staffed. Together the packs cover every builtin role —
# tests/test_role_registry.lex asserts the partition matches role_kinds.
fn pack_registry() -> List[(Str, List[Str])] {
  [("core", ["pm", "architect", "build", "py_build", "ts_build", "qa", "py_qa", "ts_qa", "test_author", "devops", "docs", "demo", "scribe", "launch", "deploy"]), ("web", ["fe_build", "ux_designer"]), ("content", ["brand_designer", "content_designer", "brand_strategist", "copywriter", "content_creator", "seo_specialist"]), ("finance", ["finance", "monetization_handoff"]), ("governance", ["legal", "cx"]), ("research", ["research"]), ("security", ["security"])]
}

fn pack_names() -> List[Str] {
  list.map(pack_registry(), fn (p :: (Str, List[Str])) -> Str {
    match p {
      (name, _) => name,
    }
  })
}

fn pack_roles(name :: Str) -> List[Str] {
  list.fold(pack_registry(), [], fn (acc :: List[Str], p :: (Str, List[Str])) -> List[Str] {
    match p {
      (n, rs) => if n == name {
        rs
      } else {
        acc
      },
    }
  })
}

fn contains(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (found :: Bool, e :: Str) -> Bool {
    found or e == x
  })
}

# Parse + validate a comma-separated packs declaration. Unknown pack =
# refuse, don't downgrade.
fn validate_packs(spec :: Str) -> Result[List[Str], Str] {
  let names := list.filter(list.map(str.split(spec, ","), fn (x :: Str) -> Str {
    str.trim(x)
  }), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  list.fold(names, Ok([]), fn (acc :: Result[List[Str], Str], n :: Str) -> Result[List[Str], Str] {
    match acc {
      Err(e) => Err(e),
      Ok(seen) => if contains(pack_names(), n) {
        Ok(list.concat(seen, [n]))
      } else {
        Err(str.join(["unknown role pack '", n, "' (known packs: ", str.join(pack_names(), ", "), ")"], ""))
      },
    }
  })
}

fn save_packs(db :: conn.ConnDb, company_id :: Str, packs :: List[Str]) -> [sql, fs_write] Result[Unit, Str] {
  let q := ormq.for_dialect({ sql: "UPDATE companies SET role_packs=? WHERE id=?", params: [PStr(str.join(packs, ",")), PStr(company_id)] }, db.dialect)
  match sql.exec(db.handle, q.sql, q.params) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

type PacksRow = { role_packs :: Str }

fn load_packs(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let q := ormq.for_dialect({ sql: "SELECT role_packs FROM companies WHERE id=?", params: [PStr(company_id)] }, db.dialect)
  let rows :: Result[List[PacksRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => match list.head(rs) {
      None => [],
      Some(r) => list.filter(list.map(str.split(r.role_packs, ","), fn (x :: Str) -> Str {
        str.trim(x)
      }), fn (s :: Str) -> Bool {
        not str.is_empty(s)
      }),
    },
  }
}

# What this company can cast: every builtin role when no packs are declared
# (today's behavior, unchanged); core + the declared packs when they are —
# plus every board-approved runtime role either way.
fn castable_kinds(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[Str] {
  let packs := load_packs(db, company_id)
  let builtin := if list.is_empty(packs) {
    role_kinds.known_kinds()
  } else {
    list.fold(list.concat(["core"], packs), [], fn (acc :: List[Str], p :: Str) -> List[Str] {
      list.fold(pack_roles(p), acc, fn (a :: List[Str], r :: Str) -> List[Str] {
        if contains(a, r) {
          a
        } else {
          list.concat(a, [r])
        }
      })
    })
  }
  list.fold(active_defs(db, company_id), builtin, fn (acc :: List[Str], d :: RoleDef) -> List[Str] {
    if contains(acc, d.kind) {
      acc
    } else {
      list.concat(acc, [d.kind])
    }
  })
}

# ── The company grant ceiling ────────────────────────────────────────────────
# [policy.isolation] may declare `ceiling = "<preset>"`; without one the
# ceiling is the sprint-level union every company already runs under
# (Implementation: ReadWrite FS, Sandboxed exec) — so by default a proposal
# can never exceed what the company already holds, and a company that
# declares a tighter ceiling gets structural refusals above it.
fn grant_ceiling(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] Str {
  match company.load_company(db, company_id) {
    None => "Implementation",
    Some(cfg) => match manifests.lookup_override(manifests.parse_isolation_overrides(cfg.policy_isolation), "ceiling") {
      None => "Implementation",
      Some(p) => p,
    },
  }
}

# ── Runtime role definitions ─────────────────────────────────────────────────
type RoleDef = { id :: Str, company_id :: Str, kind :: Str, system_prompt :: Str, tool_profile :: Str, grant_preset :: Str, status :: Str, proposed_by :: Str, approved_by :: Str, attention_id :: Str }

fn def_columns() -> Str {
  "id, company_id, kind, system_prompt, tool_profile, grant_preset, status, proposed_by, approved_by, attention_id"
}

fn load_defs(db :: conn.ConnDb, company_id :: Str, status :: Str) -> [sql, fs_read] List[RoleDef] {
  let q := ormq.for_dialect({ sql: str.join(["SELECT ", def_columns(), " FROM role_defs WHERE company_id=? AND status=? ORDER BY created_at ASC"], ""), params: [PStr(company_id), PStr(status)] }, db.dialect)
  let rows :: Result[List[RoleDef], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn active_defs(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[RoleDef] {
  load_defs(db, company_id, "active")
}

fn lookup_active(db :: conn.ConnDb, company_id :: Str, kind :: Str) -> [sql, fs_read] Option[RoleDef] {
  list.fold(active_defs(db, company_id), None, fn (acc :: Option[RoleDef], d :: RoleDef) -> Option[RoleDef] {
    match acc {
      Some(_) => acc,
      None => if d.kind == kind {
        Some(d)
      } else {
        None
      },
    }
  })
}

fn any_def_for_kind(db :: conn.ConnDb, company_id :: Str, kind :: Str) -> [sql, fs_read] Bool {
  let q := ormq.for_dialect({ sql: "SELECT COUNT(*) AS n FROM role_defs WHERE company_id=? AND kind=? AND status IN ('proposed', 'active')", params: [PStr(company_id), PStr(kind)] }, db.dialect)
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => false,
    Ok(rs) => match list.head(rs) {
      None => false,
      Some(r) => r.n > 0,
    },
  }
}

fn refuse(db :: conn.ConnDb, company_id :: Str, kind :: Str, proposed_by :: Str, reason :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Result[Str, Str] {
  let __t := tr.trail(db, company_id, "role_refused", str.join(["{\"kind\":\"", kind, "\",\"by\":\"", proposed_by, "\",\"reason\":\"", company.json_escape(reason), "\"}"], ""))
  Err(str.concat("role proposal refused: ", reason))
}

# Propose a new role definition. Every check is structural and happens at
# write time — nothing here trusts the proposer's judgment.
fn propose_role(db :: conn.ConnDb, company_id :: Str, kind :: Str, system_prompt :: Str, tool_profile :: Str, grant_preset :: Str, proposed_by :: Str) -> [sql, fs_read, fs_write, time, random, crypto, vcs] Result[Str, Str] {
  if contains(role_kinds.known_kinds(), kind) {
    refuse(db, company_id, kind, proposed_by, str.join(["'", kind, "' shadows a builtin role"], ""))
  } else {
    if any_def_for_kind(db, company_id, kind) {
      refuse(db, company_id, kind, proposed_by, str.join(["'", kind, "' is already proposed or active"], ""))
    } else {
      if str.is_empty(str.trim(system_prompt)) {
        refuse(db, company_id, kind, proposed_by, "empty system prompt")
      } else {
        if not (tool_profile == "none" or contains(role_kinds.known_kinds(), tool_profile)) {
          refuse(db, company_id, kind, proposed_by, str.join(["unknown tool profile '", tool_profile, "' — a new role can only borrow an existing role's tool budget"], ""))
        } else {
          if not contains(manifests.known_presets(), grant_preset) {
            refuse(db, company_id, kind, proposed_by, str.join(["unknown grant preset '", grant_preset, "' (known: ", str.join(manifests.known_presets(), ", "), ")"], ""))
          } else {
            let ceiling := grant_ceiling(db, company_id)
            if not manifests.grant_within(grant_preset, ceiling) {
              refuse(db, company_id, kind, proposed_by, str.join(["grant preset '", grant_preset, "' exceeds the company ceiling '", ceiling, "' — an agent-authored role can never carry a grant its company doesn't already hold"], ""))
            } else {
              let id := crypto.random_str_hex(16)
              let now := time.now_str()
              let doc := jv.stringify(JObj([("kind", JStr(kind)), ("tool_profile", JStr(tool_profile)), ("grant_preset", JStr(grant_preset)), ("proposed_by", JStr(proposed_by)), ("system_prompt", JStr(system_prompt))]))
              match tr.artifact_put(db, roles_sprint(company_id), str.concat("role-", kind), doc) {
                Err(e) => Err(str.concat("could not store role proposal: ", e)),
                Ok(hash) => match tr.push_attention(db, roles_sprint(company_id), str.concat("role-", kind), str.concat("role proposal ", kind), "board", hash) {
                  Err(e) => Err(str.concat("could not queue role proposal: ", e)),
                  Ok(att_id) => {
                    let q := ormq.for_dialect({ sql: "INSERT INTO role_defs (id, company_id, kind, system_prompt, tool_profile, grant_preset, status, proposed_by, attention_id, created_at) VALUES (?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?)", params: [PStr(id), PStr(company_id), PStr(kind), PStr(system_prompt), PStr(tool_profile), PStr(grant_preset), PStr(proposed_by), PStr(att_id), PStr(now)] }, db.dialect)
                    match sql.exec(db.handle, q.sql, q.params) {
                      Err(e) => Err(e.message),
                      Ok(_) => {
                        let __t := tr.trail(db, company_id, "role_proposed", str.join(["{\"kind\":\"", kind, "\",\"by\":\"", proposed_by, "\",\"grant\":\"", grant_preset, "\",\"tools\":\"", tool_profile, "\",\"attention\":\"", att_id, "\"}"], ""))
                        Ok(att_id)
                      },
                    }
                  },
                },
              }
            }
          }
        }
      }
    }
  }
}

fn set_def_status(db :: conn.ConnDb, id :: Str, status :: Str, approved_by :: Str) -> [sql, fs_write, time] Unit {
  let q := ormq.for_dialect({ sql: "UPDATE role_defs SET status=?, approved_by=?, updated_at=? WHERE id=?", params: [PStr(status), PStr(approved_by), PStr(time.now_str()), PStr(id)] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

# Apply board decisions on pending role proposals — run on the scheduler
# heartbeat, like the CEO's own pass.
fn apply_resolved(db :: conn.ConnDb, company_id :: Str) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let pending := load_defs(db, company_id, "proposed")
  let __each := list.map(pending, fn (d :: RoleDef) -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
    match tr.get_attention(db, d.attention_id) {
      None => (),
      Some(item) => if item.verdict == "approved" {
        let __s := set_def_status(db, d.id, "active", item.resolved_by)
        let __t := tr.trail(db, company_id, "role_activated", str.join(["{\"kind\":\"", d.kind, "\",\"by\":\"", item.resolved_by, "\",\"grant\":\"", d.grant_preset, "\"}"], ""))
        io.print(str.join(["[roles] ", company_id, ": board APPROVED role '", d.kind, "' (", item.resolved_by, ") — now castable, grant ", d.grant_preset], ""))
      } else {
        if item.verdict == "rejected" {
          let __s := set_def_status(db, d.id, "refused", item.resolved_by)
          let __t := tr.trail(db, company_id, "role_rejected", str.join(["{\"kind\":\"", d.kind, "\",\"by\":\"", item.resolved_by, "\"}"], ""))
          io.print(str.join(["[roles] ", company_id, ": board REJECTED role '", d.kind, "' (", item.resolved_by, ")"], ""))
        } else {
          ()
        }
      },
    }
  })
  ()
}

# An approved runtime role as a castable AgentDef — provider and tool
# resolution go through exactly the same machinery as builtins (roles.lex),
# so a runtime role gets no side channel.
fn def_to_agent(d :: RoleDef, model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := roles.make_provider()
  let tools := if d.tool_profile == "none" {
    []
  } else {
    roles.tools_of_role(d.tool_profile, "", sprint_id)
  }
  { id: str.concat("loom-dyn-", d.kind), kind: d.kind, system_prompt: d.system_prompt, model_name: model, provider: p, tools: tools, proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

