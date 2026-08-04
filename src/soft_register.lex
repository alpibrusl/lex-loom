# soft_register.lex — register one of a company's [soft].roles into lex-soft's
# mesh (SA2, lex-loom#179 — docs/design/soft-os-aware-agents.md).
#
# SA1 (#178) gave company.toml a `[soft]` section (mesh_url/org_id/roles) —
# schema and persistence only, nothing read it. This is the first thing that
# does: for each declared role this company has BOTH opted in (via
# `[soft].roles`) AND actually stands up an A2A server for (today: only
# `cx`, `src/server/cx_a2a.lex`), POST a registration into the mesh node at
# `[soft].mesh_url`'s `/peers` route (lex-soft's `federation.lex`; there is
# no literal `mesh.mount` — `/peers` is the real self-onboard surface, see
# lex-soft's own docs/building-a-domain-agent.md §3 "registry-only" path).
#
# Deliberately the minimum viable registration, not the credentialed
# `/connections` onboarding flow — that's a real design decision for a later
# phase (SA3's evidence-gated settlement is a much better place to add
# auth/trust weight than bolting it onto SA2's plumbing).

import "std.str" as str

import "std.io" as io

import "std.env" as env

import "std.http" as http

import "std.bytes" as bytes

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "./company" as company

import "./migrate" as migrate

# ── Known role -> A2A capability id mapping ────────────────────────────────────
# Deliberately small and explicit: adding a role here means it has a real,
# already-tested A2A skill server (like src/server/cx_a2a.lex) to point at —
# never grow this by inference, only by wiring up the actual server first.
fn known_capabilities(role :: Str) -> List[Str] {
  if role == "cx" {
    ["support.fetch_items"]
  } else {
    []
  }
}

fn is_known_role(role :: Str) -> Bool {
  not list.is_empty(known_capabilities(role))
}

# ── Config ──────────────────────────────────────────────────────────────────────
fn split_roles(roles_csv :: Str) -> List[Str] {
  list.fold(str.split(roles_csv, ","), [], fn (acc :: List[Str], r :: Str) -> List[Str] {
    let t := str.trim(r)
    if str.is_empty(t) {
      acc
    } else {
      list.concat(acc, [t])
    }
  })
}

fn peer_id(org_id :: Str, role :: Str) -> Str {
  str.join([org_id, "-", role], "")
}

fn capabilities_json(caps :: List[Str]) -> jv.Json {
  JList(list.map(caps, fn (c :: Str) -> jv.Json {
    JStr(c)
  }))
}

# Pure — the exact `POST /peers` body lex-soft's federation.lex expects
# (`id`, `inbox_url` required; `kind`/`name`/`capabilities`/`org` optional).
fn peer_payload(id :: Str, inbox_url :: Str, role :: Str, org_id :: Str) -> Str {
  jv.stringify(JObj([("id", JStr(id)), ("inbox_url", JStr(inbox_url)), ("kind", JStr("loom-agent")), ("name", JStr(str.join(["loom ", role], ""))), ("capabilities", capabilities_json(known_capabilities(role))), ("org", JStr(org_id))]))
}

# ── HTTP ──────────────────────────────────────────────────────────────────────
fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn post_json(url :: Str, body :: Str) -> [net] Result[Str, Str] {
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(e) => Err(http_err(e)),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err("response body decode failed"),
      Ok(s) => Ok(s),
    },
  }
}

fn peers_url(mesh_url :: Str) -> Str {
  if str.ends_with(mesh_url, "/") {
    str.concat(str.slice(mesh_url, 0, str.len(mesh_url) - 1), "/peers")
  } else {
    str.concat(mesh_url, "/peers")
  }
}

# `{"ok":true,...}` on success (federation.lex's own POST /peers shape);
# anything else (an `{"error":...}` body, or a body that doesn't parse) is a
# clean, reported failure rather than a silently-swallowed one.
fn interpret_peers_response(body :: Str) -> Result[Unit, Str] {
  match jv.parse(body) {
    Err(_) => Err(str.concat("mesh node returned an unparseable response: ", body)),
    Ok(j) => match jv.get_field(j, "ok") {
      Some(JBool(true)) => Ok(()),
      _ => Err(str.concat("mesh node refused the registration: ", body)),
    },
  }
}

# ── Registration ──────────────────────────────────────────────────────────────
# Validates everything it can BEFORE making a network call — an unknown role
# or missing config is a clean error, not a wasted (or worse, malformed)
# request against a real mesh node. `inbox_url` is the role's own A2A
# server's base URL (e.g. CX's `src/server/cx_a2a.lex::serve_cx_a2a`'s
# BASE_URL) — this module has no way to discover that on its own; the caller
# supplies it (see register_configured_roles below).
fn register_role(mesh_url :: Str, org_id :: Str, role :: Str, inbox_url :: Str) -> [net] Result[Str, Str] {
  if str.is_empty(str.trim(mesh_url)) {
    Err("no [soft].mesh_url configured for this company")
  } else {
    if str.is_empty(str.trim(org_id)) {
      Err("no [soft].org_id configured for this company")
    } else {
      if not is_known_role(role) {
        Err(str.join(["role \"", role, "\" has no known A2A server to register (see soft_register.known_capabilities)"], ""))
      } else {
        if str.is_empty(str.trim(inbox_url)) {
          Err(str.join(["no inbox URL configured for role \"", role, "\" (set <ROLE>_A2A_URL)"], ""))
        } else {
          let id := peer_id(org_id, role)
          match post_json(peers_url(mesh_url), peer_payload(id, inbox_url, role, org_id)) {
            Err(e) => Err(str.concat("registration request failed: ", e)),
            Ok(body) => match interpret_peers_response(body) {
              Err(e) => Err(e),
              Ok(_) => Ok(id),
            },
          }
        }
      }
    }
  }
}

type RoleRegistration = { role :: Str, inbox_url :: Str }

type RoleResult = { role :: Str, outcome :: Result[Str, Str] }

# Registers every declared, known role that also has a configured inbox URL.
# A declared-but-unconfigured role (no A2A server running for it yet) is
# silently skipped here, not reported as an error — `register_role` is the
# place that reports a hard error for an operator who explicitly asked for
# one role; this is the batch entry point company.toml's `[soft].roles`
# feeds, where "not every declared role is live yet" is the expected,
# ordinary state, not a failure (see SA1's own defaulting-safety test).
fn register_configured_roles(mesh_url :: Str, org_id :: Str, roles_csv :: Str, inboxes :: List[RoleRegistration]) -> [net] List[RoleResult] {
  let wanted := split_roles(roles_csv)
  list.fold(wanted, [], fn (acc :: List[RoleResult], role :: Str) -> [net] List[RoleResult] {
    match find_inbox(inboxes, role) {
      None => acc,
      Some(inbox_url) => list.concat(acc, [{ role: role, outcome: register_role(mesh_url, org_id, role, inbox_url) }]),
    }
  })
}

fn find_inbox(inboxes :: List[RoleRegistration], role :: Str) -> Option[Str] {
  list.fold(inboxes, None, fn (acc :: Option[Str], r :: RoleRegistration) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => if r.role == role {
        Some(r.inbox_url)
      } else {
        None
      },
    }
  })
}

# ── CLI entry point ─────────────────────────────────────────────────────────────
# Run it:
#   COMPANY_ID=acme CX_A2A_URL=http://localhost:9200 \
#   lex run --allow-effects env,net,io,sql,fs_read \
#     src/soft_register.lex register_soft_roles_cmd
#
# Reads the company's saved [soft] config (COMPANY_ID) and, for each
# `<ROLE>_A2A_URL` env var present matching a role this company declared
# in [soft].roles, registers it. Only `cx` is wired to an env var today
# (CX_A2A_URL) — extend known_capabilities + this list together when a
# second role gets a real A2A server.
fn known_role_env_vars() -> List[(Str, Str)] {
  [("cx", "CX_A2A_URL")]
}

fn collect_inboxes() -> [env] List[RoleRegistration] {
  list.fold(known_role_env_vars(), [], fn (acc :: List[RoleRegistration], pair :: (Str, Str)) -> [env] List[RoleRegistration] {
    match pair {
      (role, var) => match env.get(var) {
        None => acc,
        Some(url) => if str.is_empty(str.trim(url)) {
          acc
        } else {
          list.concat(acc, [{ role: role, inbox_url: url }])
        },
      },
    }
  })
}

fn print_result(r :: RoleResult) -> [io] Unit {
  match r.outcome {
    Ok(id) => io.print(str.join(["[soft_register] ", r.role, ": registered as ", id], "")),
    Err(e) => io.print(str.join(["[soft_register] ", r.role, ": FAILED — ", e], "")),
  }
}

fn resolve_db_url_l() -> [env] Str {
  match env.get("DB_URL") {
    Some(u) => u,
    None => match env.get("DB_PATH") {
      Some(p) => p,
      None => "loom.db",
    },
  }
}

fn open_db_l(url_or_path :: Str) -> [sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.open(url_or_path) {
    Err(_) => Err("db connection failed"),
    Ok(c) => match migrate.run(c.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(c),
    },
  }
}

fn register_soft_roles_cmd() -> [env, net, io, sql, fs_read, fs_write] Unit {
  let company_id := match env.get("COMPANY_ID") {
    Some(v) => v,
    None => "",
  }
  if str.is_empty(company_id) {
    io.print("[soft_register] COMPANY_ID is required")
  } else {
    match open_db_l(resolve_db_url_l()) {
      Err(e) => io.print(str.concat("[soft_register] FATAL db open: ", e)),
      Ok(db) => match company.load_company(db, company_id) {
        None => io.print(str.concat("[soft_register] no company found with id: ", company_id)),
        Some(cfg) => {
          let inboxes := collect_inboxes()
          let results := register_configured_roles(cfg.soft_mesh_url, cfg.soft_org_id, cfg.soft_roles, inboxes)
          if list.is_empty(results) {
            io.print("[soft_register] nothing to register (check [soft].roles and <ROLE>_A2A_URL env vars)")
          } else {
            let __p := list.map(results, print_result)
            ()
          }
        },
      },
    }
  }
}

