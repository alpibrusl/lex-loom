# test_org.lex — ORG1 (lex-loom#216): reporting lines.
#
# Parsing/validation and chain-walking are pure; persistence is round-tripped
# against a real migrated DB through the same relationships.lex store the
# oracle contacts live in.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "../src/migrate" as migrate

import "../src/org" as org

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn ok_edges(r :: Result[List[org.OrgEdge], Str]) -> List[org.OrgEdge] {
  match r {
    Ok(es) => es,
    Err(_) => [],
  }
}

fn is_err_containing(r :: Result[List[org.OrgEdge], Str], needle :: Str) -> Bool {
  match r {
    Ok(_) => false,
    Err(m) => str.contains(m, needle),
  }
}

fn test_parse_valid_spec() -> Result[Unit, Str] {
  let edges := ok_edges(org.parse_org_spec("build:eng_manager,qa:eng_manager,eng_manager:founder"))
  match check("three edges parsed", list.len(edges) == 3) {
    Err(e) => Err(e),
    Ok(_) => match check("manager lookup works", org.manager_of(edges, "build") == Some("eng_manager")) {
      Err(e) => Err(e),
      Ok(_) => check("root has no manager", org.manager_of(edges, "founder") == None),
    },
  }
}

fn test_empty_spec_is_flat() -> Result[Unit, Str] {
  check("empty spec is a valid flat org", list.is_empty(ok_edges(org.parse_org_spec(""))))
}

fn test_malformed_entry_refused() -> Result[Unit, Str] {
  check("malformed entry refused", is_err_containing(org.parse_org_spec("build-eng_manager"), "malformed"))
}

fn test_two_managers_refused() -> Result[Unit, Str] {
  check("a role with two managers is refused", is_err_containing(org.parse_org_spec("build:qa,build:pm"), "more than one manager"))
}

fn test_self_edge_refused() -> Result[Unit, Str] {
  check("self-reporting refused", is_err_containing(org.parse_org_spec("build:build"), "itself"))
}

fn test_cycle_refused() -> Result[Unit, Str] {
  check("cycle refused", is_err_containing(org.parse_org_spec("build:qa,qa:pm,pm:build"), "cycle"))
}

fn test_unknown_leaf_role_refused() -> Result[Unit, Str] {
  match check("typo'd worker role refused", is_err_containing(org.parse_org_spec("bulid:eng_manager,eng_manager:founder"), "unknown role")) {
    Err(e) => Err(e),
    Ok(_) => check("org-only management names are fine", list.len(ok_edges(org.parse_org_spec("build:eng_manager,eng_manager:founder"))) == 2),
  }
}

# The gate-timeout escalation path (scheduler.escalate_overdue) walks this.
fn test_escalation_chain() -> Result[Unit, Str] {
  let edges := ok_edges(org.parse_org_spec("build:eng_manager,qa:eng_manager,eng_manager:founder"))
  match check("worker chain walks to the root", org.escalation_chain(edges, "build") == ["eng_manager", "founder"]) {
    Err(e) => Err(e),
    Ok(_) => check("unmanaged role has an empty chain (falls back to the oracle)", list.is_empty(org.escalation_chain(edges, "legal"))),
  }
}

fn test_org_chart_rendering() -> Result[Unit, Str] {
  let edges := ok_edges(org.parse_org_spec("build:eng_manager,qa:eng_manager,eng_manager:founder"))
  let chart := org.org_chart(edges)
  match check("chart groups children under managers", str.contains(chart, "eng_manager <- build, qa")) {
    Err(e) => Err(e),
    Ok(_) => match check("chart shows the root line", str.contains(chart, "founder <- eng_manager")) {
      Err(e) => Err(e),
      Ok(_) => check("flat org renders as flat", org.org_chart([]) == "(flat — no org declared)"),
    },
  }
}

# Save -> load -> re-save round-trip against the real relationships store.
fn test_db_round_trip() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match conn.open(str.join(["/tmp/loom-t-", crypto.random_str_hex(8), ".db"], "")) {
    Err(_) => Err("open memory db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(str.concat("migrate: ", e)),
      Ok(_) => {
        let cid := str.concat("orgco-", crypto.random_str_hex(6))
        let edges := ok_edges(org.parse_org_spec("build:eng_manager,eng_manager:founder"))
        match org.save_org(db, cid, edges) {
          Err(m) => Err(str.concat("save_org: ", m)),
          Ok(_) => {
            let loaded := org.load_org(db, cid)
            match check("edges round-trip", list.len(loaded) == 2 and org.manager_of(loaded, "build") == Some("eng_manager")) {
              Err(e) => Err(e),
              Ok(_) => {
                let smaller := ok_edges(org.parse_org_spec("build:founder"))
                match org.save_org(db, cid, smaller) {
                  Err(m) => Err(str.concat("re-save: ", m)),
                  Ok(_) => check("re-save replaces, not appends", list.len(org.load_org(db, cid)) == 1),
                }
              },
            }
          },
        }
      },
    },
  }
}

fn suite() -> [sql, fs_read, fs_write, random, time, io] List[Result[Unit, Str]] {
  [test_parse_valid_spec(), test_empty_spec_is_flat(), test_malformed_entry_refused(), test_two_managers_refused(), test_self_edge_refused(), test_cycle_refused(), test_unknown_leaf_role_refused(), test_escalation_chain(), test_org_chart_rendering(), test_db_round_trip()]
}

fn run_all() -> [io, sql, fs_read, fs_write, random, time] Unit {
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

