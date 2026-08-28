import "std.list" as list

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

import "./phase" as ph

# ── Types ────────────────────────────────────────────────────────────────────
type Phase = ph.Phase

# `expand` is an optional sub-task description. When set, the orchestrator
# runs a child sprint on the sub-task instead of invoking an LLM agent.
# The child sprint must pass for the node to be accepted (#35).
# `activate_when` (C4, #57) is an optional condition (company DSL, see company.lex)
# gating whether the node runs in the current iteration. Empty = always active.
type Node = { id :: Str, role :: Str, gate :: Str, expand :: Option[Str], activate_when :: Str }

# `handoff` is the schema source validated by lex-schema at runtime.
# On the wire only a content-hash ref travels, not the payload itself.
type Edge = { from :: Str, to :: Str, handoff :: Str }

# The dynamic artifact produced by the Architect per sprint.
# Content-addressed by its own hash once content-addressing lands in lex-vcs.
type SprintGraph = { id :: Str, phase :: Phase, nodes :: List[Node], edges :: List[Edge] }

# ── Internal helpers (pure) ───────────────────────────────────────────────────
fn node_ids(g :: SprintGraph) -> List[Str] {
  list.map(g.nodes, fn (n :: Node) -> Str {
    n.id
  })
}

fn predecessors(g :: SprintGraph, id :: Str) -> List[Str] {
  list.fold(g.edges, [], fn (acc :: List[Str], e :: Edge) -> List[Str] {
    if e.to == id {
      list.concat(acc, [e.from])
    } else {
      acc
    }
  })
}

fn str_contains(items :: List[Str], target :: Str) -> Bool {
  list.fold(items, false, fn (found :: Bool, s :: Str) -> Bool {
    if found {
      true
    } else {
      s == target
    }
  })
}

fn str_filter(items :: List[Str], pred :: (Str) -> Bool) -> List[Str] {
  list.fold(items, [], fn (acc :: List[Str], s :: Str) -> List[Str] {
    if pred(s) {
      list.concat(acc, [s])
    } else {
      acc
    }
  })
}

fn count_occurrences(items :: List[Str], target :: Str) -> Int {
  list.fold(items, 0, fn (n :: Int, s :: Str) -> Int {
    if s == target {
      n + 1
    } else {
      n
    }
  })
}

# ── Structural validation (pure) ──────────────────────────────────────────────
fn validate_unique_ids(g :: SprintGraph) -> Result[Unit, Str] {
  let ids := node_ids(g)
  list.fold(ids, Ok(()), fn (acc :: Result[Unit, Str], id :: Str) -> Result[Unit, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(_) => if count_occurrences(ids, id) > 1 {
        Err(str.join(["duplicate node id: ", id], ""))
      } else {
        Ok(())
      },
    }
  })
}

fn validate_node_fields(g :: SprintGraph) -> Result[Unit, Str] {
  list.fold(g.nodes, Ok(()), fn (acc :: Result[Unit, Str], n :: Node) -> Result[Unit, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(_) => if str.is_empty(n.id) {
        Err("node has empty id")
      } else {
        if str.is_empty(n.role) {
          Err(str.join(["node ", n.id, " has empty role"], ""))
        } else {
          if str.is_empty(n.gate) {
            Err(str.join(["node ", n.id, " has no gate (ungated output not allowed)"], ""))
          } else {
            Ok(())
          }
        }
      },
    }
  })
}

fn validate_edge_refs(g :: SprintGraph) -> Result[Unit, Str] {
  let ids := node_ids(g)
  list.fold(g.edges, Ok(()), fn (acc :: Result[Unit, Str], e :: Edge) -> Result[Unit, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(_) => if not str_contains(ids, e.from) {
        Err(str.join(["edge references unknown source node: ", e.from], ""))
      } else {
        if not str_contains(ids, e.to) {
          Err(str.join(["edge references unknown target node: ", e.to], ""))
        } else {
          if str.is_empty(e.handoff) {
            Err(str.join(["edge ", e.from, "->", e.to, " has no handoff schema"], ""))
          } else {
            Ok(())
          }
        }
      },
    }
  })
}

# ── Topological sort (pure) ───────────────────────────────────────────────────
#
# Kahn's algorithm over immutable lists. Returns layers — each layer is a set
# of node ids whose predecessors are all in prior layers. Errors on a cycle
# (use metaspec iteration budgets to allow bounded cycles).
fn topo_sort(g :: SprintGraph) -> Result[List[List[Str]], Str]
  examples {
    topo_sort({ id: "g5", phase: Intake, nodes: [{ id: "a", role: "build", gate: "spec true", expand: None, activate_when: "" }, { id: "b", role: "test", gate: "spec true", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }] }) => Ok([["a"], ["b"]])
  }
{
  topo_step(g, node_ids(g), [])
}

fn topo_step(g :: SprintGraph, remaining :: List[Str], acc :: List[List[Str]]) -> Result[List[List[Str]], Str] {
  if list.is_empty(remaining) {
    Ok(acc)
  } else {
    let ready := str_filter(remaining, fn (id :: Str) -> Bool {
      let preds := predecessors(g, id)
      not list.fold(preds, false, fn (any_pending :: Bool, pred :: Str) -> Bool {
        if any_pending {
          true
        } else {
          str_contains(remaining, pred)
        }
      })
    })
    if list.is_empty(ready) {
      Err("cycle detected in SprintGraph — add an iteration budget to allow bounded cycles")
    } else {
      let next := str_filter(remaining, fn (id :: Str) -> Bool {
        not str_contains(ready, id)
      })
      topo_step(g, next, list.concat(acc, [ready]))
    }
  }
}

# ── Descendants (GOV1, lex-loom#221) ─────────────────────────────────────────
# Every node reachable from `roots` via edges (roots excluded unless reachable
# from another root). What a blocking `human` gate parks: the gate node's
# dependent subtree waits while independent tracks continue.
fn descendants(g :: SprintGraph, roots :: List[Str]) -> List[Str]
  examples {
    descendants({ id: "g6", phase: Intake, nodes: [{ id: "a", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "b", role: "test", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "c", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }] }, ["a"]) => ["b"],
    descendants({ id: "g7", phase: Intake, nodes: [{ id: "a", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "b", role: "test", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "c", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }, { from: "b", to: "c", handoff: "schema {}" }] }, ["a"]) => ["b", "c"],
    descendants({ id: "g8", phase: Intake, nodes: [{ id: "a", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }, []) => []
  }
{
  descend_step(g, roots, [])
}

fn descend_step(g :: SprintGraph, frontier :: List[Str], seen :: List[Str]) -> List[Str] {
  let next := list.fold(g.edges, [], fn (acc :: List[Str], e :: Edge) -> List[Str] {
    if str_contains(frontier, e.from) {
      if str_contains(seen, e.to) {
        acc
      } else {
        if str_contains(acc, e.to) {
          acc
        } else {
          list.concat(acc, [e.to])
        }
      }
    } else {
      acc
    }
  })
  if list.is_empty(next) {
    seen
  } else {
    descend_step(g, next, list.concat(seen, next))
  }
}

# ── Public API ────────────────────────────────────────────────────────────────
# Structural validation only — schema and spec content are checked by metaspec.
fn validate(g :: SprintGraph) -> Result[Unit, Str]
  examples {
    validate({ id: "g0", phase: Intake, nodes: [], edges: [] }) => Ok(()),
    validate({ id: "g1", phase: Intake, nodes: [{ id: "n1", role: "build", gate: "spec true", expand: None, activate_when: "" }, { id: "n1", role: "test", gate: "spec true", expand: None, activate_when: "" }], edges: [] }) => Err("duplicate node id: n1"),
    validate({ id: "g2", phase: Intake, nodes: [{ id: "n1", role: "build", gate: "", expand: None, activate_when: "" }], edges: [] }) => Err("node n1 has no gate (ungated output not allowed)"),
    validate({ id: "g3", phase: Intake, nodes: [{ id: "n1", role: "build", gate: "spec true", expand: None, activate_when: "" }], edges: [{ from: "n1", to: "n2", handoff: "schema {}" }] }) => Err("edge references unknown target node: n2"),
    validate({ id: "g4", phase: Intake, nodes: [{ id: "a", role: "build", gate: "spec true", expand: None, activate_when: "" }, { id: "b", role: "test", gate: "spec true", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }, { from: "b", to: "a", handoff: "schema {}" }] }) => Err("cycle detected in SprintGraph — add an iteration budget to allow bounded cycles")
  }
{
  match validate_unique_ids(g) {
    Err(e) => Err(e),
    Ok(_) => match validate_node_fields(g) {
      Err(e) => Err(e),
      Ok(_) => match validate_edge_refs(g) {
        Err(e) => Err(e),
        Ok(_) => match topo_sort(g) {
          Err(e) => Err(e),
          Ok(_) => Ok(()),
        },
      },
    },
  }
}

# ── JSON serialisation ────────────────────────────────────────────────────────
# Which roles judge work rather than produce it. The Architect writes one
# graph with a single phase, so without this every QA node runs inside
# Implementation and its failure simply sinks the sprint -- the QA<->
# Implementation bounce never gets a chance to send the work back. Note
# py_qa/ts_qa: matching only the bare "qa" missed the Python and TypeScript
# judges entirely.
fn is_qa_role(role :: Str) -> Bool {
  if role == "qa" {
    true
  } else {
    if role == "py_qa" {
      true
    } else {
      role == "ts_qa"
    }
  }
}

# demo rides with QA: metaspec's qa-dominates-demo rule requires a demo node to
# have a qa ancestor, so separating them would leave demo unreachable.
fn belongs_to_qa_phase(role :: Str) -> Bool {
  if is_qa_role(role) {
    true
  } else {
    role == "demo"
  }
}

fn has_qa_node(g :: SprintGraph) -> Bool {
  list.fold(g.nodes, false, fn (acc :: Bool, n :: Node) -> Bool {
    if acc {
      true
    } else {
      is_qa_role(n.role)
    }
  })
}

# Keep only the nodes the predicate selects, plus every edge whose BOTH ends
# survived -- an edge to a dropped node would fail validate_edge_refs.
fn subgraph(g :: SprintGraph, keep_qa_half :: Bool, p :: Phase, suffix :: Str) -> SprintGraph {
  let nodes := list.filter(g.nodes, fn (n :: Node) -> Bool {
    if keep_qa_half {
      belongs_to_qa_phase(n.role)
    } else {
      not belongs_to_qa_phase(n.role)
    }
  })
  let ids := list.map(nodes, fn (n :: Node) -> Str {
    n.id
  })
  let edges := list.filter(g.edges, fn (e :: Edge) -> Bool {
    if str_contains(ids, e.from) {
      str_contains(ids, e.to)
    } else {
      false
    }
  })
  { id: str.concat(g.id, suffix), phase: p, nodes: nodes, edges: edges }
}

# Which QA role can actually read what this graph builds. The synthetic QA
# fallback used to hardcode "qa" -- the Lex judge -- so a Python company whose
# Architect omitted QA got a judge that ran lex_check against Python and could
# never ground a verdict. Mixed-language graphs keep the generic judge: there
# is no single right answer there, and guessing would be worse than the
# Architect being explicit.
fn qa_role_for_graph(g :: SprintGraph) -> Str {
  let py := list.fold(g.nodes, false, fn (acc :: Bool, n :: Node) -> Bool {
    if acc {
      true
    } else {
      n.role == "py_build"
    }
  })
  let ts := list.fold(g.nodes, false, fn (acc :: Bool, n :: Node) -> Bool {
    if acc {
      true
    } else {
      n.role == "ts_build"
    }
  })
  let lex := list.fold(g.nodes, false, fn (acc :: Bool, n :: Node) -> Bool {
    if acc {
      true
    } else {
      n.role == "build"
    }
  })
  if py {
    if ts {
      "qa"
    } else {
      if lex {
        "qa"
      } else {
        "py_qa"
      }
    }
  } else {
    if ts {
      if lex {
        "qa"
      } else {
        "ts_qa"
      }
    } else {
      "qa"
    }
  }
}

# A subgraph restricted to an explicit set of node ids, keeping only edges
# whose BOTH ends survived (an edge to a dropped node fails validate_edge_refs).
# Used to re-run just the part of Implementation a QA failure actually
# implicates, instead of the whole phase.
fn subgraph_of_ids(g :: SprintGraph, ids :: List[Str], p :: Phase, suffix :: Str) -> SprintGraph {
  let nodes := list.filter(g.nodes, fn (n :: Node) -> Bool {
    str_contains(ids, n.id)
  })
  let edges := list.filter(g.edges, fn (e :: Edge) -> Bool {
    if str_contains(ids, e.from) {
      str_contains(ids, e.to)
    } else {
      false
    }
  })
  { id: str.concat(g.id, suffix), phase: p, nodes: nodes, edges: edges }
}

fn qa_subgraph(g :: SprintGraph) -> SprintGraph {
  subgraph(g, true, QA, "-qa")
}

# The implementation half: what the Implementation phase RUNS.
#
# Callers must not let this replace the full graph. run_sprint once rebound
# `sprint_graph` to the extension of THIS half, and since it contains no QA
# node by construction, has_qa_node was then always false and every sprint fell
# through to the synthetic QA fallback. Found live: a tzconvert graph that
# correctly paired py_build-1..3 with py_qa-1..3 had all three py_qa nodes
# silently discarded, and a Lex judge ran lex_check against Python. The split
# narrows what Implementation runs; it must never narrow what QA is selected
# from.
fn impl_subgraph(g :: SprintGraph) -> SprintGraph {
  subgraph(g, false, Implementation, "-impl")
}

fn phase_to_str(p :: Phase) -> Str {
  match p {
    Intake => "Intake",
    Design => "Design",
    Implementation => "Implementation",
    QA => "QA",
    Demo => "Demo",
    Retro => "Retro",
    Digest => "Digest",
  }
}

fn phase_from_str(s :: Str) -> Result[Phase, Str] {
  if s == "Intake" {
    Ok(Intake)
  } else {
    if s == "Design" {
      Ok(Design)
    } else {
      if s == "Implementation" {
        Ok(Implementation)
      } else {
        if s == "QA" {
          Ok(QA)
        } else {
          if s == "Demo" {
            Ok(Demo)
          } else {
            if s == "Retro" {
              Ok(Retro)
            } else {
              if s == "Digest" {
                Ok(Digest)
              } else {
                Err(str.concat("unknown phase: ", s))
              }
            }
          }
        }
      }
    }
  }
}

fn node_to_json(n :: Node) -> jv.Json {
  let base := [("id", JStr(n.id)), ("role", JStr(n.role)), ("gate", JStr(n.gate))]
  let with_act := if str.is_empty(n.activate_when) {
    base
  } else {
    list.concat(base, [("activate_when", JStr(n.activate_when))])
  }
  JObj(with_act)
}

fn edge_to_json(e :: Edge) -> jv.Json {
  JObj([("from", JStr(e.from)), ("to", JStr(e.to)), ("handoff", JStr(e.handoff))])
}

fn to_json(g :: SprintGraph) -> jv.Json {
  JObj([("id", JStr(g.id)), ("phase", JStr(phase_to_str(g.phase))), ("nodes", JList(list.map(g.nodes, fn (n :: Node) -> jv.Json {
    node_to_json(n)
  }))), ("edges", JList(list.map(g.edges, fn (e :: Edge) -> jv.Json {
    edge_to_json(e)
  })))])
}

fn node_from_json(j :: jv.Json) -> Result[Node, Str] {
  let id := match jv.get_field(j, "id") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let role := match jv.get_field(j, "role") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let gate := match jv.get_field(j, "gate") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let expand := match jv.get_field(j, "expand") {
    Some(JStr(s)) => if str.is_empty(str.trim(s)) {
      None
    } else {
      Some(s)
    },
    _ => None,
  }
  let activate_when := match jv.get_field(j, "activate_when") {
    Some(JStr(s)) => s,
    _ => "",
  }
  if str.is_empty(id) {
    Err("node missing id field")
  } else {
    Ok({ id: id, role: role, gate: gate, expand: expand, activate_when: activate_when })
  }
}

fn edge_from_json(j :: jv.Json) -> Result[Edge, Str] {
  let from := match jv.get_field(j, "from") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let to := match jv.get_field(j, "to") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let handoff := match jv.get_field(j, "handoff") {
    Some(JStr(s)) => s,
    _ => "schema {}",
  }
  if str.is_empty(from) {
    Err("edge missing from or to field")
  } else {
    if str.is_empty(to) {
      Err("edge missing from or to field")
    } else {
      Ok({ from: from, to: to, handoff: handoff })
    }
  }
}

fn nodes_from_json(j :: jv.Json) -> Result[List[Node], Str] {
  match j {
    JList(items) => list.fold(items, Ok([]), fn (acc :: Result[List[Node], Str], item :: jv.Json) -> Result[List[Node], Str] {
      match acc {
        Err(e) => Err(e),
        Ok(ns) => match node_from_json(item) {
          Err(e) => Err(e),
          Ok(n) => Ok(list.concat(ns, [n])),
        },
      }
    }),
    _ => Ok([]),
  }
}

fn edges_from_json(j :: jv.Json) -> Result[List[Edge], Str] {
  match j {
    JList(items) => list.fold(items, Ok([]), fn (acc :: Result[List[Edge], Str], item :: jv.Json) -> Result[List[Edge], Str] {
      match acc {
        Err(e) => Err(e),
        Ok(es) => match edge_from_json(item) {
          Err(e) => Err(e),
          Ok(e2) => Ok(list.concat(es, [e2])),
        },
      }
    }),
    _ => Ok([]),
  }
}

fn from_json(j :: jv.Json) -> Result[SprintGraph, Str] {
  match j {
    JObj(_) => {
      let id := match jv.get_field(j, "id") {
        Some(JStr(s)) => s,
        _ => "graph-1",
      }
      let phase_str := match jv.get_field(j, "phase") {
        Some(JStr(s)) => s,
        _ => "Intake",
      }
      match phase_from_str(phase_str) {
        Err(e) => Err(e),
        Ok(p) => {
          let nodes_j := match jv.get_field(j, "nodes") {
            Some(v) => v,
            None => JList([]),
          }
          let edges_j := match jv.get_field(j, "edges") {
            Some(v) => v,
            None => JList([]),
          }
          match nodes_from_json(nodes_j) {
            Err(e) => Err(e),
            Ok(nodes) => match edges_from_json(edges_j) {
              Err(e) => Err(e),
              Ok(edges) => Ok({ id: id, phase: p, nodes: nodes, edges: edges }),
            },
          }
        },
      }
    },
    _ => Err("SprintGraph must be a JSON object"),
  }
}

# Strip markdown code fences that models often wrap around JSON output.
fn strip_fences(s :: Str) -> Str {
  let trimmed := str.trim(s)
  let after_open := if str.starts_with(trimmed, "```json") {
    str.trim(str.slice(trimmed, 7, str.len(trimmed)))
  } else {
    if str.starts_with(trimmed, "```") {
      str.trim(str.slice(trimmed, 3, str.len(trimmed)))
    } else {
      trimmed
    }
  }
  if str.ends_with(after_open, "```") {
    str.trim(str.slice(after_open, 0, str.len(after_open) - 3))
  } else {
    after_open
  }
}

fn from_json_str(s :: Str) -> Result[SprintGraph, Str] {
  let clean := strip_fences(s)
  match jv.parse(clean) {
    Err(e) => Err(str.join(["JSON parse error at pos ", int.to_str(e.pos), ": ", e.message], "")),
    Ok(j) => from_json(j),
  }
}

fn to_json_str(g :: SprintGraph) -> Str {
  jv.stringify(to_json(g))
}

