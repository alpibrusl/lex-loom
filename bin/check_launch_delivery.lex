# check_launch_delivery.lex — a launch-delivery against the run-2 launch
# criteria (lex-loom#447, Run B).
#
#     check-launch-delivery.sh <company.db> <workspace dir>
#
# Two sources, and neither is the supplier's word.
#
# What LOOM recorded, by the sprint's graph (node_results has no role column,
# so the roles come out of the graph JSON):
#   checkable:iteration-passed          company_iterations status=success
#   checkable:channel-plan-present      an accepted node cast as community
#   checkable:welcome-sequence-present  an accepted node cast as lifecycle
#   checkable:launch-runbook-present    an accepted node cast as release_manager
#
# What the PRODUCT recorded, counted HERE in the product's own store.
# launch/evidence.json names the store and the read-only queries; the buyer
# runs each one itself and a number the supplier wrote into the file is never
# consulted. Thresholds are #452's stages.
#
# TWO DEFENCES, because this runs SQL THE SUPPLIER WROTE. The store is opened
# through the `file:...?mode=ro` URI, so a query that tries to write is refused
# by SQLite rather than trusted not to; and a query that does not begin with
# SELECT is not run at all. Both are load-bearing -- bin/check_launch_delivery
# is the one checker that executes a string from the thing it is judging.
#
# Ported from check_launch_delivery.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.sql" as sql

import "std.int" as int

import "lex-schema/json_value" as jv

type SprintRow = { sprint_id :: Str }

type GraphRow = { graph_json :: Str }

type NodeRow = { node_id :: Str }

# The scalar comes back COALESCEd to "" rather than typed Option[Str].
#
# A scalar query legitimately returns NULL -- "the first genuine submission"
# before there is one -- and a plain Str row panics on exactly the input this
# checker exists to report. Option[Str] is not the fix either: the driver hands
# back a bare Str for a non-NULL value and Unit for NULL, so an Option row
# panics on every row that HAS a value. COALESCE in the SQL makes the value
# always a string, and "" already means "nothing counted" everywhere below.
# Both directions found by differential against the Python.
type ValRow = { v :: Str }

fn min_signups() -> Int {
  100
}

fn min_would_pay() -> Int {
  15
}

fn min_paying() -> Int {
  1
}

fn passing_sprint(db :: Str) -> [sql, fs_read, fs_write, fs_walk] Str {
  if not fs.exists(db) {
    ""
  } else {
    match sql.open(db) {
      Err(_) => "",
      Ok(h) => {
        let rows :: Result[List[SprintRow], SqlError] := sql.query(h, "SELECT sprint_id FROM company_iterations WHERE status='success' ORDER BY idx DESC LIMIT 1", [])
        match rows {
          Err(_) => "",
          Ok(rs) => match list.head(rs) {
            None => "",
            Some(r) => r.sprint_id,
          },
        }
      },
    }
  }
}

fn role_of_node(graphs :: List[Str], node_id :: Str) -> Str {
  list.fold(graphs, "", fn (acc :: Str, gj :: Str) -> Str {
    if not str.is_empty(acc) {
      acc
    } else {
      match jv.parse(gj) {
        Err(_) => "",
        Ok(j) => match jv.get_field(j, "nodes") {
          None => "",
          Some(ns) => match ns {
            JList(items) => list.fold(items, "", fn (a :: Str, n :: jv.Json) -> Str {
              if not str.is_empty(a) {
                a
              } else {
                if field_str(n, "id") == node_id {
                  field_str(n, "role")
                } else {
                  a
                }
              }
            }),
            _ => "",
          },
        },
      }
    }
  })
}

fn field_str(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    None => "",
    Some(v) => match v {
      JStr(s) => s,
      _ => "",
    },
  }
}

fn accepted_roles(db :: Str, sprint :: Str) -> [sql, fs_read, fs_write, fs_walk] List[Str] {
  if str.is_empty(sprint) or not fs.exists(db) {
    []
  } else {
    match sql.open(db) {
      Err(_) => [],
      Ok(h) => {
        let graphs :: Result[List[GraphRow], SqlError] := sql.query(h, "SELECT graph_json FROM sprint_graphs WHERE sprint_id=?", [PStr(sprint)])
        let nodes :: Result[List[NodeRow], SqlError] := sql.query(h, "SELECT node_id FROM node_results WHERE sprint_id=? AND accepted=1", [PStr(sprint)])
        match (graphs, nodes) {
          (Ok(gs), Ok(ns)) => {
            let gjs := list.map(gs, fn (g :: GraphRow) -> Str {
              g.graph_json
            })
            list.filter(list.map(ns, fn (n :: NodeRow) -> Str {
              role_of_node(gjs, n.node_id)
            }), fn (r :: Str) -> Bool {
              not str.is_empty(r)
            })
          },
          _ => [],
        }
      },
    }
  }
}

# One read-only SELECT against the product's store. Returns the value, or an
# empty value and a reason -- never a crash, because a broken query in the
# supplier's own evidence file is a criterion unmet, not a checker failure.
fn scalar(store :: Str, query :: Str) -> [sql, fs_read, fs_write] (Str, Str) {
  if not str.starts_with(str.to_lower(str.trim(query)), "select") {
    ("", "not a SELECT (only read-only queries are run)")
  } else {
    match sql.open(str.join(["file:", store, "?mode=ro"], "")) {
      Err(e) => ("", str.join([basename(store), ": ", sql_reason(e.message)], "")),
      Ok(h) => {
        let rows :: Result[List[ValRow], SqlError] := sql.query(h, str.join(["SELECT CAST(COALESCE((", query, "), '') AS TEXT) AS v"], ""), [])
        match rows {
          Err(e) => ("", str.join([basename(store), ": ", sql_reason(e.message)], "")),
          Ok(rs) => match list.head(rs) {
            None => ("", ""),
            Some(r) => (r.v, ""),
          },
        }
      },
    }
  }
}

# std.sql prefixes its message with "sql.query: "; the supplier reading this
# refusal cares about "no such table: waitlist", not about which Lex function
# reported it.
fn sql_reason(m :: Str) -> Str {
  match str.strip_prefix(m, "sql.query: ") {
    None => m,
    Some(rest) => rest,
  }
}

fn basename(p :: Str) -> Str {
  match list.head(list.reverse(str.split(p, "/"))) {
    None => p,
    Some(b) => b,
  }
}

fn at_least(v :: Str, n :: Int) -> Bool {
  match str.to_int(v) {
    None => false,
    Some(i) => i >= n,
  }
}

fn shown(v :: Str, e :: Str) -> Str {
  if str.is_empty(e) {
    if str.is_empty(v) {
      "None"
    } else {
      v
    }
  } else {
    e
  }
}

type Check = { attr :: Str, ok :: Bool, why :: Str }

fn main(db :: Str, ws :: Str) -> [sql, fs_read, fs_write, fs_walk, io] Int {
  if str.is_empty(db) or str.is_empty(ws) {
    let __ := io.print("usage: check-launch-delivery.sh <company.db> <workspace dir>")
    2
  } else {
    let sprint := passing_sprint(db)
    let roles := accepted_roles(db, sprint)
    let sprint_name := if str.is_empty(sprint) {
      "any sprint"
    } else {
      sprint
    }
    let loom_checks := list.concat([{ attr: "checkable:iteration-passed", ok: not str.is_empty(sprint), why: "no iteration ended with status success" }], list.map([("checkable:channel-plan-present", "community"), ("checkable:welcome-sequence-present", "lifecycle"), ("checkable:launch-runbook-present", "release_manager")], fn (ar :: (Str, Str)) -> Check {
      match ar {
        (attr, role) => { attr: attr, ok: not str.is_empty(sprint) and md_contains(roles, role), why: str.join(["no accepted ", role, " node in ", sprint_name], "") },
      }
    }))
    let ev_path := str.join([ws, "/launch/evidence.json"], "")
    let product_checks := if not fs.exists(ev_path) {
      unavailable("no launch/evidence.json in the workspace (the product must name its store and the queries)")
    } else {
      match io.read(ev_path) {
        Err(_) => unavailable("launch/evidence.json unreadable"),
        Ok(raw) => match jv.parse(raw) {
          Err(_) => unavailable("launch/evidence.json unreadable: JSONDecodeError"),
          Ok(ev) => {
            let store := str.join([ws, "/", field_str(ev, "db")], "")
            if not fs.exists(store) {
              unavailable(str.join(["launch/evidence.json names '", field_str(ev, "db"), "', which is not in the workspace"], ""))
            } else {
              measured(store, ev)
            }
          },
        },
      }
    }
    report(list.concat(loom_checks, product_checks))
  }
}

fn md_contains(xs :: List[Str], want :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == want
    }
  })
}

fn unavailable(why :: Str) -> List[Check] {
  list.map(["checkable:waitlist-threshold", "checkable:first-genuine-submission", "checkable:paying-customer"], fn (a :: Str) -> Check {
    { attr: a, ok: false, why: why }
  })
}

fn measured(store :: Str, ev :: jv.Json) -> [sql, fs_read, fs_write] List[Check] {
  match scalar(store, field_str(ev, "waitlist_signups_sql")) {
    (signups, e1) => match scalar(store, field_str(ev, "would_pay_sql")) {
      (would_pay, e2) => match scalar(store, field_str(ev, "first_genuine_submission_sql")) {
        (first, e3) => match scalar(store, field_str(ev, "paying_customers_sql")) {
          (paying, e4) => [{ attr: "checkable:waitlist-threshold", ok: str.is_empty(e1) and at_least(signups, min_signups()) or str.is_empty(e2) and at_least(would_pay, min_would_pay()), why: str.join(["counted ", shown(signups, e1), " signups and ", shown(would_pay, e2), " would-pay; Stage 0 needs ", int.to_str(min_signups()), " or ", int.to_str(min_would_pay())], "") }, { attr: "checkable:first-genuine-submission", ok: str.is_empty(e3) and not str.is_empty(first) and first != "0", why: if str.is_empty(e3) {
            "the store records no genuine submission"
          } else {
            e3
          } }, { attr: "checkable:paying-customer", ok: str.is_empty(e4) and at_least(paying, min_paying()), why: if str.is_empty(e4) {
            str.join(["counted ", shown(paying, e4), " paying customers; Stage 2 needs ", int.to_str(min_paying())], "")
          } else {
            e4
          } }],
        },
      },
    },
  }
}

fn report(checks :: List[Check]) -> [io] Int {
  let met := list.filter(checks, fn (c :: Check) -> Bool {
    c.ok
  })
  let unmet := list.filter(checks, fn (c :: Check) -> Bool {
    not c.ok
  })
  let attrs := str.join(list.map(met, fn (c :: Check) -> Str {
    c.attr
  }), " ")
  let __v := io.print(str.concat("LAUNCH_DELIVERY_VERIFIED ", attrs))
  if list.is_empty(unmet) {
    let __o := io.print(str.concat("LAUNCH_DELIVERY_OK ", attrs))
    0
  } else {
    let __h := io.print("check_launch_delivery: the delivery does not meet these checkable criteria:\n")
    let __l := list.fold(unmet, 0, fn (n :: Int, c :: Check) -> [io] Int {
      let __ := io.print(str.join(["  ", c.attr, ": ", c.why], ""))
      n + 1
    })
    1
  }
}

