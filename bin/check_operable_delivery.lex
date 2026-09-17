# check_operable_delivery.lex — an operable-delivery against the run-2
# operable criteria.
#
#     check-operable-delivery.sh <company.db> <workspace dir> [--domain <host>]
#
# Run 1's software contract ended at "software built". This contract pays for
# the product being OPERABLE -- measurable, restorable, documented for launch,
# and reachable over TLS. Every criterion is re-derived by the BUYER: from what
# loom itself recorded, and by re-running the same grounded checkers the roles'
# own gates used.
#
# A domain is a founder-provided need and is never assumed: without --domain
# the TLS criterion is reported UNMET rather than skipped, because a criterion
# nobody assessed must not read like one that passed.
#
# Ported from check_operable_delivery.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.sql" as sql

import "std.process" as proc

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

type SprintRow = { sprint_id :: Str }

type CountRow = { n :: Int }

type GraphRow = { graph_json :: Str }

type NodeRow = { node_id :: Str }

type Finding = { attr :: Str, ok :: Bool, why :: Str }

fn field_str(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    None => "",
    Some(v) => match v {
      JStr(s) => s,
      _ => "",
    },
  }
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

fn acceptance_count(db :: Str, sprint :: Str) -> [sql, fs_read, fs_write, fs_walk] Int {
  if str.is_empty(sprint) or not fs.exists(db) {
    0
  } else {
    match sql.open(db) {
      Err(_) => 0,
      Ok(h) => {
        let rows :: Result[List[CountRow], SqlError] := sql.query(h, "SELECT count(*) AS n FROM traces WHERE run_id=? AND event_kind='acceptance_passed'", [PStr(sprint)])
        match rows {
          Err(_) => 0,
          Ok(rs) => match list.head(rs) {
            None => 0,
            Some(r) => r.n,
          },
        }
      },
    }
  }
}

# node_results carries no role column; the sprint's GRAPH does.
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
          (Ok(gs), Ok(ns)) => list.filter(list.map(ns, fn (n :: NodeRow) -> Str {
            role_of(list.map(gs, fn (g :: GraphRow) -> Str {
              g.graph_json
            }), n.node_id)
          }), fn (r :: Str) -> Bool {
            not str.is_empty(r)
          }),
          _ => [],
        }
      },
    }
  }
}

fn role_of(graphs :: List[Str], node_id :: Str) -> Str {
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

fn has(xs :: List[Str], want :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == want
    }
  })
}

# The sub-checker's own unmet DETAIL ("  checkable:x: why") is what a founder
# needs to read; its last line is the fallback when it did not produce one.
fn sub_checker(script :: Str, ws :: Str) -> [proc, fs_walk, io] (Bool, Str) {
  let path := str.join(["bin/", script], "")
  if not fs.exists(path) {
    (false, str.join([script, " not found beside this checker"], ""))
  } else {
    match proc.run("bash", [path, ws]) {
      Err(m) => (false, clip(m, 200)),
      Ok(r) => {
        let lines := list.filter(str.split(str.trim(r.stdout), "\n"), fn (l :: Str) -> Bool {
          not str.is_empty(str.trim(l))
        })
        let detail := match list.head(list.filter(lines, fn (l :: Str) -> Bool {
          str.starts_with(l, "  checkable:")
        })) {
          Some(l) => str.trim(l),
          None => match list.head(list.reverse(lines)) {
            None => "",
            Some(l) => l,
          },
        }
        (r.exit_code == 0, clip(detail, 200))
      },
    }
  }
}

fn clip(s :: Str, n :: Int) -> Str {
  if str.len(s) > n {
    str.slice(s, 0, n)
  } else {
    s
  }
}

# The ONE place this port cannot be byte-identical to the Python. urllib
# reported the exception class ("URLError: <urlopen error ...>"); Lex has a
# typed HttpError with different names for the same conditions. The criterion,
# the verdict and the URL are unchanged -- only the words describing WHY the
# host did not answer differ, and they were never stable across Python versions
# either.
fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

fn tls_check(domain :: Str) -> [net] Finding {
  let url := str.join(["https://", domain, "/healthz"], "")
  match http.get(url) {
    Err(e) => { attr: "checkable:reachable-over-tls", ok: false, why: str.join([url, ": ", http_err(e)], "") },
    Ok(resp) => match jv.parse(match bytes.to_str(resp.body) {
      Err(_) => "",
      Ok(b) => b,
    }) {
      Err(_) => { attr: "checkable:reachable-over-tls", ok: false, why: str.join([url, " answered but not ok:true"], "") },
      Ok(j) => {
        let ok := match jv.get_field(j, "ok") {
          Some(JBool(b)) => b,
          _ => false,
        }
        { attr: "checkable:reachable-over-tls", ok: ok, why: str.join([url, " answered but not ok:true"], "") }
      },
    },
  }
}

fn main(db :: Str, ws :: Str, domain :: Str) -> [sql, fs_read, fs_write, fs_walk, proc, net, io] Int {
  if str.is_empty(db) or str.is_empty(ws) {
    let __ := io.print("usage: check-operable-delivery.sh <company.db> <workspace dir> [--domain <host>]")
    2
  } else {
    let sprint := passing_sprint(db)
    let sprint_name := if str.is_empty(sprint) {
      "any sprint"
    } else {
      sprint
    }
    let metrics := sub_checker("check-metrics-instrumented.sh", ws)
    let restore := sub_checker("check-restore-performed.sh", ws)
    let roles := accepted_roles(db, sprint)
    let checks := list.concat([{ attr: "checkable:iteration-passed", ok: not str.is_empty(sprint), why: "no iteration ended with status success" }, { attr: "checkable:acceptance-passed", ok: acceptance_count(db, sprint) > 0, why: str.join(["no acceptance_passed in the trail of ", sprint_name], "") }, sub_finding("checkable:metrics-instrumented", metrics), sub_finding("checkable:restore-performed", restore)], list.concat(list.map([("checkable:runbook-present", "release_manager"), ("checkable:data-map-present", "data_protection")], fn (ar :: (Str, Str)) -> Finding {
      match ar {
        (attr, role) => { attr: attr, ok: not str.is_empty(sprint) and has(roles, role), why: str.join(["no accepted ", role, " node in ", sprint_name], "") },
      }
    }), [if str.is_empty(domain) {
      { attr: "checkable:reachable-over-tls", ok: false, why: "no --domain given; a hostname is a founder-provided need and is never assumed" }
    } else {
      tls_check(domain)
    }]))
    report(checks)
  }
}

fn sub_finding(attr :: Str, r :: (Bool, Str)) -> Finding {
  match r {
    (ok, why) => { attr: attr, ok: ok, why: why },
  }
}

fn report(checks :: List[Finding]) -> [io] Int {
  let met := list.filter(checks, fn (c :: Finding) -> Bool {
    c.ok
  })
  let unmet := list.filter(checks, fn (c :: Finding) -> Bool {
    not c.ok
  })
  let attrs := str.join(list.map(met, fn (c :: Finding) -> Str {
    c.attr
  }), " ")
  let __v := io.print(str.concat("OPERABLE_DELIVERY_VERIFIED ", attrs))
  if list.is_empty(unmet) {
    let __o := io.print(str.concat("OPERABLE_DELIVERY_OK ", attrs))
    0
  } else {
    let __h := io.print("check_operable_delivery: the delivery does not meet these checkable criteria:\n")
    let __l := list.fold(unmet, 0, fn (n :: Int, c :: Finding) -> [io] Int {
      let __ := io.print(str.join(["  ", c.attr, ": ", c.why], ""))
      n + 1
    })
    1
  }
}

