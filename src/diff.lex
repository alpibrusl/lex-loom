# diff.lex — semantic diff between two SprintGraphs (§III, §8).
#
# The Architect may refine the graph after the Design phase. The executor
# takes a semantic diff of (old, new) and re-instantiates only the changed
# nodes — unchanged nodes keep their running state and their attestations.
#
# "Semantic" here means field-level comparison of id/role/gate for nodes
# and from/to/handoff for edges. A change to a node's gate or role means
# its output can no longer be trusted, so it must re-run. A change to an
# edge's handoff means the downstream node must re-run too.
#
# All functions are pure (no effects).

import "std.list" as list

import "std.str" as str

import "./graph" as graph

# ── Types ─────────────────────────────────────────────────────────────────────
type NodeDiff = NodeAdded(graph.Node) | NodeRemoved(Str) | NodeChanged((graph.Node, graph.Node))

type EdgeDiff = EdgeAdded(graph.Edge) | EdgeRemoved(graph.Edge) | EdgeModified((graph.Edge, graph.Edge))

type GraphDiff = { node_diffs :: List[NodeDiff], edge_diffs :: List[EdgeDiff] }

# ── Node comparison ───────────────────────────────────────────────────────────
fn nodes_equal(a :: graph.Node, b :: graph.Node) -> Bool {
  if a.id == b.id {
    if a.role == b.role {
      a.gate == b.gate
    } else {
      false
    }
  } else {
    false
  }
}

fn edges_equal(a :: graph.Edge, b :: graph.Edge) -> Bool {
  if a.from == b.from {
    if a.to == b.to {
      a.handoff == b.handoff
    } else {
      false
    }
  } else {
    false
  }
}

fn find_node(nodes :: List[graph.Node], id :: Str) -> Option[graph.Node] {
  list.fold(nodes, None, fn (acc :: Option[graph.Node], n :: graph.Node) -> Option[graph.Node] {
    match acc {
      Some(_) => acc,
      None => if n.id == id {
        Some(n)
      } else {
        None
      },
    }
  })
}

fn find_edge(edges :: List[graph.Edge], from :: Str, to :: Str) -> Option[graph.Edge] {
  list.fold(edges, None, fn (acc :: Option[graph.Edge], e :: graph.Edge) -> Option[graph.Edge] {
    match acc {
      Some(_) => acc,
      None => if e.from == from {
        if e.to == to {
          Some(e)
        } else {
          None
        }
      } else {
        None
      },
    }
  })
}

# ── Diff computation ──────────────────────────────────────────────────────────
fn diff_nodes(old_nodes :: List[graph.Node], new_nodes :: List[graph.Node]) -> List[NodeDiff] {
  let from_old := list.fold(old_nodes, [], fn (acc :: List[NodeDiff], old_n :: graph.Node) -> List[NodeDiff] {
    match find_node(new_nodes, old_n.id) {
      None => list.concat(acc, [NodeRemoved(old_n.id)]),
      Some(new_n) => if nodes_equal(old_n, new_n) {
        acc
      } else {
        list.concat(acc, [NodeChanged(old_n, new_n)])
      },
    }
  })
  let added := list.fold(new_nodes, [], fn (acc :: List[NodeDiff], new_n :: graph.Node) -> List[NodeDiff] {
    match find_node(old_nodes, new_n.id) {
      None => list.concat(acc, [NodeAdded(new_n)]),
      Some(_) => acc,
    }
  })
  list.concat(from_old, added)
}

fn diff_edges(old_edges :: List[graph.Edge], new_edges :: List[graph.Edge]) -> List[EdgeDiff] {
  let from_old := list.fold(old_edges, [], fn (acc :: List[EdgeDiff], old_e :: graph.Edge) -> List[EdgeDiff] {
    match find_edge(new_edges, old_e.from, old_e.to) {
      None => list.concat(acc, [EdgeRemoved(old_e)]),
      Some(new_e) => if edges_equal(old_e, new_e) {
        acc
      } else {
        list.concat(acc, [EdgeModified(old_e, new_e)])
      },
    }
  })
  let added := list.fold(new_edges, [], fn (acc :: List[EdgeDiff], new_e :: graph.Edge) -> List[EdgeDiff] {
    match find_edge(old_edges, new_e.from, new_e.to) {
      None => list.concat(acc, [EdgeAdded(new_e)]),
      Some(_) => acc,
    }
  })
  list.concat(from_old, added)
}

fn diff(old :: graph.SprintGraph, new :: graph.SprintGraph) -> GraphDiff
  examples {
    diff({ id: "g", phase: graph.Intake, nodes: [{ id: "a", role: "build", gate: "spec true" }], edges: [] }, { id: "g", phase: graph.Intake, nodes: [{ id: "a", role: "build", gate: "spec true" }], edges: [] }) => { node_diffs: [], edge_diffs: [] }
  }
{
  { node_diffs: diff_nodes(old.nodes, new.nodes), edge_diffs: diff_edges(old.edges, new.edges) }
}

# ── Derived queries (pure) ────────────────────────────────────────────────────
fn is_empty(d :: GraphDiff) -> Bool {
  if list.is_empty(d.node_diffs) {
    list.is_empty(d.edge_diffs)
  } else {
    false
  }
}

# Node ids that must be re-run after a re-plan.
# Includes added and changed nodes; also includes downstream nodes of
# modified edges (their input changed so their prior artifact is invalid).
fn nodes_to_rerun(d :: GraphDiff, g :: graph.SprintGraph) -> List[Str] {
  let direct := list.fold(d.node_diffs, [], fn (acc :: List[Str], nd :: NodeDiff) -> List[Str] {
    match nd {
      NodeAdded(n) => list.concat(acc, [n.id]),
      NodeChanged(_, n) => list.concat(acc, [n.id]),
      NodeRemoved(_) => acc,
    }
  })
  let from_edges := list.fold(d.edge_diffs, [], fn (acc :: List[Str], ed :: EdgeDiff) -> List[Str] {
    match ed {
      EdgeAdded(e) => if graph.str_contains(acc, e.to) {
        acc
      } else {
        list.concat(acc, [e.to])
      },
      EdgeModified(_, e) => if graph.str_contains(acc, e.to) {
        acc
      } else {
        list.concat(acc, [e.to])
      },
      EdgeRemoved(_) => acc,
    }
  })
  list.fold(from_edges, direct, fn (acc :: List[Str], id :: Str) -> List[Str] {
    if graph.str_contains(acc, id) {
      acc
    } else {
      list.concat(acc, [id])
    }
  })
}

# Nodes that can keep their existing artifact after a re-plan.
fn nodes_to_keep(d :: GraphDiff, g :: graph.SprintGraph) -> List[Str] {
  let rerun := nodes_to_rerun(d, g)
  graph.str_filter(graph.node_ids(g), fn (id :: Str) -> Bool {
    not graph.str_contains(rerun, id)
  })
}

