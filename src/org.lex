# org.lex — ORG1 (lex-loom#216): reporting lines.
#
# The company's org chart: who reports to whom. One declaration per role —
# `child reports_to parent` — from which the decision-rights vocabulary is
# DERIVED (v1): a parent `may_assign` to, `reviews`, and is `escalates_to`
# for each of its children. ORG2/ORG3 consume `may_assign`/`reviews`; what
# ORG1 wires in is the third: the gate-timeout escalation path walks the
# chain upward before landing on the human oracle.
#
# Storage rides relationships.lex — the same generic (from, to, role,
# contract_json) graph oracle contacts already use — under the reserved role
# prefix `org:`:
#
#   from_agent = company_id, role = "org:<child>", to_agent = <parent>,
#   contract_json = {"reports_to":true,"may_assign":true,
#                    "reviews":true,"escalates_to":true}
#
# Declared via company.toml's [org] table (bootstrap-company.sh flattens it
# to the ORG_EDGES env var, "child:parent,child:parent,..."). Validation is
# REFUSE, DON'T DOWNGRADE: a malformed spec, a duplicate child, a cycle, or
# a leaf role outside role_kinds.known_kinds() aborts the company launch loudly —
# it never runs with a half-loaded org. A company with no [org] is exactly
# what it was before: flat, oracle-direct.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-orm/src/connection" as conn

import "./agent/relationships" as rel

import "./role_kinds" as role_kinds

type OrgEdge = { child :: Str, parent :: Str }

fn org_role_prefix() -> Str {
  "org:"
}

fn derived_contract() -> Str {
  "{\"reports_to\":true,\"may_assign\":true,\"reviews\":true,\"escalates_to\":true}"
}

# ── Parsing ───────────────────────────────────────────────────────────────────
# "build:eng_manager,qa:eng_manager,eng_manager:founder" -> edges.
fn parse_org_spec(spec :: Str) -> Result[List[OrgEdge], Str] {
  let entries := list.filter(str.split(str.trim(spec), ","), fn (e :: Str) -> Bool {
    not str.is_empty(str.trim(e))
  })
  let parsed := list.fold(entries, Ok([]), fn (acc :: Result[List[OrgEdge], Str], e :: Str) -> Result[List[OrgEdge], Str] {
    match acc {
      Err(m) => Err(m),
      Ok(so_far) => {
        let parts := str.split(str.trim(e), ":")
        let child := match list.head(parts) {
          None => "",
          Some(c) => str.trim(c),
        }
        let parent := match list.head(list.tail(parts)) {
          None => "",
          Some(p) => str.trim(p),
        }
        if str.is_empty(child) or str.is_empty(parent) or list.len(parts) != 2 {
          Err(str.join(["malformed org entry '", e, "' — expected child:parent"], ""))
        } else {
          Ok(list.concat(so_far, [{ child: child, parent: parent }]))
        }
      },
    }
  })
  match parsed {
    Err(m) => Err(m),
    Ok(edges) => validate(edges),
  }
}

fn has_child(edges :: List[OrgEdge], role :: Str) -> Bool {
  list.fold(edges, false, fn (found :: Bool, e :: OrgEdge) -> Bool {
    found or e.child == role
  })
}

fn is_parent_somewhere(edges :: List[OrgEdge], role :: Str) -> Bool {
  list.fold(edges, false, fn (found :: Bool, e :: OrgEdge) -> Bool {
    found or e.parent == role
  })
}

fn is_known_role(role :: Str) -> Bool {
  list.fold(role_kinds.known_kinds(), false, fn (found :: Bool, k :: Str) -> Bool {
    found or k == role
  })
}

# Structural validation: one parent per child, no self-edges, no cycles, and
# every LEAF child (a role that manages nobody) must be a castable sprint
# role — a typo'd worker role is refused at load, not discovered mid-sprint.
# Management roles (any role that is itself a parent) may be org-only names
# like "founder" or "eng_manager": they exist to be escalated to (and, from
# ORG3 on, to manage), not to be cast as sprint nodes.
fn validate(edges :: List[OrgEdge]) -> Result[List[OrgEdge], Str] {
  let structural := list.fold(edges, Ok(()), fn (acc :: Result[Unit, Str], e :: OrgEdge) -> Result[Unit, Str] {
    match acc {
      Err(m) => Err(m),
      Ok(_) => if e.child == e.parent {
        Err(str.join(["org: role '", e.child, "' cannot report to itself"], ""))
      } else {
        if list.len(list.filter(edges, fn (o :: OrgEdge) -> Bool {
          o.child == e.child
        })) > 1 {
          Err(str.join(["org: role '", e.child, "' has more than one manager"], ""))
        } else {
          if not is_parent_somewhere(edges, e.child) and not is_known_role(e.child) {
            Err(str.join(["org: unknown role '", e.child, "' — not a castable sprint role and manages nobody"], ""))
          } else {
            Ok(())
          }
        }
      },
    }
  })
  match structural {
    Err(m) => Err(m),
    Ok(_) => {
      let cyclic := list.fold(edges, "", fn (found :: Str, e :: OrgEdge) -> Str {
        if not str.is_empty(found) {
          found
        } else {
          if chain_hits(edges, e.parent, e.child, list.len(edges) + 1) {
            e.child
          } else {
            ""
          }
        }
      })
      if str.is_empty(cyclic) {
        Ok(edges)
      } else {
        Err(str.join(["org: cycle detected through role '", cyclic, "' — reporting lines must form a tree"], ""))
      }
    },
  }
}

# Does walking up from `from` ever reach `target` within `budget` hops?
fn chain_hits(edges :: List[OrgEdge], from :: Str, target :: Str, budget :: Int) -> Bool {
  if budget <= 0 {
    false
  } else {
    if from == target {
      true
    } else {
      match manager_of(edges, from) {
        None => false,
        Some(m) => chain_hits(edges, m, target, budget - 1),
      }
    }
  }
}

# ── Queries (pure over loaded edges) ─────────────────────────────────────────
fn manager_of(edges :: List[OrgEdge], role :: Str) -> Option[Str] {
  list.fold(edges, None, fn (acc :: Option[Str], e :: OrgEdge) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => if e.child == role {
        Some(e.parent)
      } else {
        None
      },
    }
  })
}

# The escalation chain for a role: its manager, then the manager's manager,
# up to the root. Empty when the role has no reporting line — the caller
# falls back to the human oracle directly, exactly as before ORG1.
fn escalation_chain(edges :: List[OrgEdge], role :: Str) -> List[Str] {
  chain_step(edges, role, [], list.len(edges) + 1)
}

fn chain_step(edges :: List[OrgEdge], role :: Str, acc :: List[Str], budget :: Int) -> List[Str] {
  if budget <= 0 {
    acc
  } else {
    match manager_of(edges, role) {
      None => acc,
      Some(m) => chain_step(edges, m, list.concat(acc, [m]), budget - 1),
    }
  }
}

# ── Persistence (relationships.lex under the org: prefix) ────────────────────
fn save_org(db :: conn.ConnDb, company_id :: Str, edges :: List[OrgEdge]) -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  let __clear := list.map(load_org(db, company_id), fn (e :: OrgEdge) -> [sql, fs_write] Unit {
    let __r := rel.remove(db, company_id, e.parent, str.concat(org_role_prefix(), e.child))
    ()
  })
  list.fold(edges, Ok(()), fn (acc :: Result[Unit, Str], e :: OrgEdge) -> [sql, fs_write, random, time] Result[Unit, Str] {
    match acc {
      Err(m) => Err(m),
      Ok(_) => rel.add(db, company_id, e.parent, str.concat(org_role_prefix(), e.child), derived_contract()),
    }
  })
}

fn load_org(db :: conn.ConnDb, company_id :: Str) -> [sql, fs_read] List[OrgEdge] {
  match rel.peers_of(db, company_id) {
    Err(_) => [],
    Ok(rels) => list.fold(rels, [], fn (acc :: List[OrgEdge], r :: rel.Relationship) -> List[OrgEdge] {
      match str.strip_prefix(r.role, org_role_prefix()) {
        None => acc,
        Some(child) => list.concat(acc, [{ child: child, parent: r.to_agent }]),
      }
    }),
  }
}

# ── Rendering (board_report) ─────────────────────────────────────────────────
fn org_chart(edges :: List[OrgEdge]) -> Str {
  if list.is_empty(edges) {
    "(flat — no org declared)"
  } else {
    let parents := list.fold(edges, [], fn (acc :: List[Str], e :: OrgEdge) -> List[Str] {
      if list.fold(acc, false, fn (found :: Bool, p :: Str) -> Bool {
        found or p == e.parent
      }) {
        acc
      } else {
        list.concat(acc, [e.parent])
      }
    })
    str.join(list.map(parents, fn (p :: Str) -> Str {
      let kids := list.map(list.filter(edges, fn (e :: OrgEdge) -> Bool {
        e.parent == p
      }), fn (e :: OrgEdge) -> Str {
        e.child
      })
      str.join(["  ", p, " <- ", str.join(kids, ", ")], "")
    }), "\n")
  }
}

