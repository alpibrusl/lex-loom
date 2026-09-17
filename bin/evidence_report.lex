# evidence_report.lex — what each accepted node was actually sealed ON.
#
# A claim sealed on "output longer than N characters" is a claim nobody
# checked. This walks a company's trail and says, per accepted node, whether
# the gate that admitted it was a real check or a presence test.
#
# THE GATE COMES FROM THE STORED GRAPHS, NOT FROM DENIAL RECORDS. Reading it
# off denials only would leave every node that passed FIRST TIME labelled "gate
# not recorded" and counted as unwitnessed -- a report that misreports, which
# is the exact failure these books exist to catch. The first version of this
# script did precisely that.
#
# Ported from the heredoc in bin/evidence-report.sh (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.sql" as sql

import "std.int" as int

import "lex-schema/json_value" as jv

type GraphRow = { graph_json :: Str }

type DataRow = { data_json :: Str }

type NodeGate = { node :: Str, gate :: Str }

fn field_str(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn gates_of(rows :: List[GraphRow]) -> List[NodeGate] {
  list.fold(rows, [], fn (acc :: List[NodeGate], r :: GraphRow) -> List[NodeGate] {
    match jv.parse(r.graph_json) {
      Err(_) => acc,
      Ok(g) => match jv.get_field(g, "nodes") {
        Some(JList(items)) => list.fold(items, acc, fn (a :: List[NodeGate], n :: jv.Json) -> List[NodeGate] {
          let id := field_str(n, "id")
          let gate := field_str(n, "gate")
          if str.is_empty(id) or str.is_empty(gate) or has_node(a, id) {
            a
          } else {
            list.concat(a, [{ node: id, gate: gate }])
          }
        }),
        _ => acc,
      },
    }
  })
}

fn has_node(xs :: List[NodeGate], id :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: NodeGate) -> Bool {
    acc or x.node == id
  })
}

fn gate_for(xs :: List[NodeGate], id :: Str) -> Str {
  list.fold(xs, "", fn (acc :: Str, x :: NodeGate) -> Str {
    if not str.is_empty(acc) {
      acc
    } else {
      if x.node == id {
        x.gate
      } else {
        acc
      }
    }
  })
}

fn starts_with_any(s :: Str, prefixes :: List[Str]) -> Bool {
  list.fold(prefixes, false, fn (acc :: Bool, p :: Str) -> Bool {
    acc or str.starts_with(s, p)
  })
}

# "grounded", "judged" and "human" are all a real check; "presence" is the one
# that seals on nothing. The tag is what a reader scans for.
fn strength(gate :: Str) -> (Str, Str) {
  if str.is_empty(gate) {
    ("unknown", "[NO GATE FOUND]")
  } else {
    if starts_with_any(gate, ["spec compiles", "spec json-verdict-pass", "spec json-ok-true", "spec sh "]) {
      ("grounded", "[checkable]")
    } else {
      if str.starts_with(gate, "spec judge ") {
        ("judged", "[judged]")
      } else {
        if str.starts_with(gate, "human ") {
          ("human", "[human]")
        } else {
          if starts_with_any(gate, ["spec len-gt", "spec non-empty", "spec json"]) {
            ("presence", "[UNWITNESSED]")
          } else {
            ("unknown", "[NO GATE FOUND]")
          }
        }
      }
    }
  }
}

fn pad(s :: Str, n :: Int) -> Str {
  if str.len(s) >= n {
    s
  } else {
    pad(str.concat(s, " "), n)
  }
}

fn main(db_path :: Str) -> [sql, fs_read, fs_write, io] Int {
  match sql.open(str.join(["file:", db_path, "?mode=ro"], "")) {
    Err(_) => 1,
    Ok(h) => {
      let graphs :: Result[List[GraphRow], SqlError] := sql.query(h, "select graph_json from sprint_graphs", [])
      let accepted :: Result[List[DataRow], SqlError] := sql.query(h, "select data_json from traces where event_kind='node_accepted'", [])
      match (graphs, accepted) {
        (Ok(gs), Ok(acc)) => {
          let gates := gates_of(gs)
          let nodes := list.fold(acc, [], fn (ns :: List[Str], r :: DataRow) -> List[Str] {
            match jv.parse(r.data_json) {
              Err(_) => ns,
              Ok(j) => {
                let n := field_str(j, "node")
                if str.is_empty(n) or list.fold(ns, false, fn (f :: Bool, x :: Str) -> Bool {
                  f or x == n
                }) {
                  ns
                } else {
                  list.concat(ns, [n])
                }
              },
            }
          })
          report(nodes, gates)
        },
        _ => 1,
      }
    },
  }
}

fn report(nodes :: List[Str], gates :: List[NodeGate]) -> [io] Int {
  let counts := list.fold(nodes, (0, 0), fn (sw :: (Int, Int), n :: Str) -> [io] (Int, Int) {
    let g := gate_for(gates, n)
    match strength(g) {
      (kind, tag) => {
        let __ := io.print(str.join(["   ", pad(tag, 15), " ", pad(n, 22), " ", if str.is_empty(g) {
          "(no gate in any stored graph)"
        } else {
          g
        }], ""))
        match sw {
          (s, w) => if kind == "presence" or kind == "unknown" {
            (s, w + 1)
          } else {
            (s + 1, w)
          },
        }
      },
    }
  })
  match counts {
    (strong, weak) => {
      let __a := io.print("")
      let __b := io.print(str.join(["   sealed on a real check: ", int.to_str(strong), "    sealed on presence alone: ", int.to_str(weak)], ""))
      if weak > 0 {
        let __c := io.print("   A claim sealed on 'output longer than N characters' is a claim nobody checked.")
        0
      } else {
        0
      }
    },
  }
}

