import "std.list" as list

import "std.str" as str

import "./graph" as graph

# ── Types ────────────────────────────────────────────────────────────────────
# A single rule violation. Collecting all violations (not short-circuiting)
# lets the Architect fix everything in one round-trip.
type Violation = { rule :: Str, message :: Str }

type MetaspecResult = Valid | Invalid(List[Violation])

fn rule_all_nodes_gated(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.gate) {
      list.concat(acc, [{ rule: "all-nodes-gated", message: str.join(["node ", n.id, " has no gate"], "") }])
    } else {
      acc
    }
  })
}

# Rule 2: every edge must carry a handoff schema (structural; also in graph.validate).
fn rule_all_edges_have_handoff(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.edges, [], fn (acc :: List[Violation], e :: graph.Edge) -> List[Violation] {
    if str.is_empty(e.handoff) {
      list.concat(acc, [{ rule: "all-edges-have-handoff", message: str.join(["edge ", e.from, "->", e.to, " has no handoff schema"], "") }])
    } else {
      acc
    }
  })
}

# Rule 3: every node must have a non-empty role.
fn rule_all_nodes_have_role(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.role) {
      list.concat(acc, [{ rule: "all-nodes-have-role", message: str.join(["node ", n.id, " has empty role"], "") }])
    } else {
      acc
    }
  })
}

# Rule 4: graph must be a DAG (no unbounded cycles).
# Bounded cycles are allowed in a future extension via an iteration-budget field
# on Edge; until that field exists every cycle is a violation.
fn rule_dag(g :: graph.SprintGraph) -> List[Violation] {
  match graph.topo_sort(g) {
    Ok(_) => [],
    Err(e) => [{ rule: "dag-or-budgeted-cycle", message: e }],
  }
}

# Rule 5: every node whose role contains "demo" (case-insensitive) must be
# reachable from at least one node whose role contains "qa".
# This encodes: you cannot demo unverified work.
fn rule_qa_dominates_demo(g :: graph.SprintGraph) -> List[Violation] {
  let demo_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "demo") {
      list.concat(acc, [n])
    } else {
      acc
    }
  })
  let qa_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "qa") {
      list.concat(acc, [n])
    } else {
      acc
    }
  })
  list.fold(demo_nodes, [], fn (acc :: List[Violation], demo :: graph.Node) -> List[Violation] {
    let has_qa_ancestor := list.fold(qa_nodes, false, fn (found :: Bool, qa :: graph.Node) -> Bool {
      if found {
        true
      } else {
        can_reach(g, qa.id, demo.id)
      }
    })
    if not has_qa_ancestor {
      list.concat(acc, [{ rule: "qa-dominates-demo", message: str.join(["demo node ", demo.id, " has no qa node ancestor (cannot demo unverified work)"], "") }])
    } else {
      acc
    }
  })
}

# Rule 6: graph must not be empty.
fn rule_non_empty(g :: graph.SprintGraph) -> List[Violation] {
  if list.is_empty(g.nodes) {
    [{ rule: "non-empty", message: "SprintGraph has no nodes" }]
  } else {
    []
  }
}

# ── Graph reachability helper (pure) ──────────────────────────────────────────
fn successors(g :: graph.SprintGraph, id :: Str) -> List[Str] {
  list.fold(g.edges, [], fn (acc :: List[Str], e :: graph.Edge) -> List[Str] {
    if e.from == id {
      list.concat(acc, [e.to])
    } else {
      acc
    }
  })
}

# BFS reachability — can we get from `from` to `to` following edges?
fn can_reach(g :: graph.SprintGraph, from :: Str, to :: Str) -> Bool {
  bfs(g, [from], to, [])
}

fn bfs(g :: graph.SprintGraph, frontier :: List[Str], target :: Str, visited :: List[Str]) -> Bool {
  match list.head(frontier) {
    None => false,
    Some(current) => if current == target {
      true
    } else {
      let next_visited := list.concat(visited, [current])
      let rest := graph.str_filter(frontier, fn (s :: Str) -> Bool {
        s != current
      })
      let nexts := list.fold(successors(g, current), rest, fn (acc :: List[Str], s :: Str) -> List[Str] {
        if if graph.str_contains(next_visited, s) {
          true
        } else {
          graph.str_contains(acc, s)
        } {
          acc
        } else {
          list.concat(acc, [s])
        }
      })
      bfs(g, nexts, target, next_visited)
    },
  }
}

fn str_role_is(role :: Str, keyword :: Str) -> Bool {
  str.starts_with(str.to_lower(role), keyword)
}

# ── Public API ────────────────────────────────────────────────────────────────
fn check(g :: graph.SprintGraph) -> MetaspecResult
  examples {
    check({ id: "g0", phase: graph.Intake, nodes: [{ id: "n1", role: "build", gate: "spec true" }], edges: [] }) => Valid,
    check({ id: "g1", phase: graph.Intake, nodes: [], edges: [] }) => Invalid([{ rule: "non-empty", message: "SprintGraph has no nodes" }]),
    check({ id: "g2", phase: graph.QA, nodes: [{ id: "d", role: "demo", gate: "spec true" }], edges: [] }) => Invalid([{ rule: "qa-dominates-demo", message: "demo node d has no qa node ancestor (cannot demo unverified work)" }]),
    check({ id: "g3", phase: graph.QA, nodes: [{ id: "q", role: "qa", gate: "spec true" }, { id: "d", role: "demo", gate: "spec true" }], edges: [{ from: "q", to: "d", handoff: "schema {}" }] }) => Valid,
    check({ id: "g4", phase: graph.Intake, nodes: [{ id: "a", role: "build", gate: "spec true" }, { id: "b", role: "test", gate: "spec true" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }, { from: "b", to: "a", handoff: "schema {}" }] }) => Invalid([{ rule: "dag-or-budgeted-cycle", message: "cycle detected in SprintGraph — add an iteration budget to allow bounded cycles" }])
  }
{
  let violations := list.fold([rule_non_empty(g), rule_all_nodes_have_role(g), rule_all_nodes_gated(g), rule_all_edges_have_handoff(g), rule_dag(g), rule_qa_dominates_demo(g)], [], fn (acc :: List[Violation], vs :: List[Violation]) -> List[Violation] {
    list.concat(acc, vs)
  })
  if list.is_empty(violations) {
    Valid
  } else {
    Invalid(violations)
  }
}

