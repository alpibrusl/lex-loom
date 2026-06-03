import "std.list" as list
import "std.str"  as str

# ── Types ────────────────────────────────────────────────────────────────────

type Phase =
  Intake | Design | Implementation | QA | Demo | Retro | Digest

# `gate` is the spec source evaluated by lex-spec at runtime.
# Empty gate is rejected by validate/metaspec — ungated output is not allowed.
type Node = {
  id   :: Str,
  role :: Str,
  gate :: Str,
}

# `handoff` is the schema source validated by lex-schema at runtime.
# On the wire only a content-hash ref travels, not the payload itself.
type Edge = {
  from    :: Str,
  to      :: Str,
  handoff :: Str,
}

# The dynamic artifact produced by the Architect per sprint.
# Content-addressed by its own hash once content-addressing lands in lex-vcs.
type SprintGraph = {
  id    :: Str,
  phase :: Phase,
  nodes :: List[Node],
  edges :: List[Edge],
}

# ── Internal helpers (pure) ───────────────────────────────────────────────────

fn node_ids(g :: SprintGraph) -> List[Str] {
  list.map(g.nodes, fn (n :: Node) -> Str { n.id })
}

fn predecessors(g :: SprintGraph, id :: Str) -> List[Str] {
  list.fold(g.edges, [], fn (acc :: List[Str], e :: Edge) -> List[Str] {
    if e.to == id { list.concat(acc, [e.from]) } else { acc }
  })
}

fn str_contains(items :: List[Str], target :: Str) -> Bool {
  list.fold(items, false, fn (found :: Bool, s :: Str) -> Bool {
    if found { true } else { s == target }
  })
}

fn str_filter(items :: List[Str], pred :: (Str) -> Bool) -> List[Str] {
  list.fold(items, [], fn (acc :: List[Str], s :: Str) -> List[Str] {
    if pred(s) { list.concat(acc, [s]) } else { acc }
  })
}

fn count_occurrences(items :: List[Str], target :: Str) -> Int {
  list.fold(items, 0, fn (n :: Int, s :: Str) -> Int {
    if s == target { n + 1 } else { n }
  })
}

# ── Structural validation (pure) ──────────────────────────────────────────────

fn validate_unique_ids(g :: SprintGraph) -> Result[Unit, Str] {
  let ids := node_ids(g)
  list.fold(ids, Ok(()), fn (acc :: Result[Unit, Str], id :: Str) -> Result[Unit, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(_) =>
        if count_occurrences(ids, id) > 1 {
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
      Ok(_) =>
        if str.is_empty(n.id) {
          Err("node has empty id")
        } else if str.is_empty(n.role) {
          Err(str.join(["node ", n.id, " has empty role"], ""))
        } else if str.is_empty(n.gate) {
          Err(str.join(["node ", n.id, " has no gate (ungated output not allowed)"], ""))
        } else {
          Ok(())
        },
    }
  })
}

fn validate_edge_refs(g :: SprintGraph) -> Result[Unit, Str] {
  let ids := node_ids(g)
  list.fold(g.edges, Ok(()), fn (acc :: Result[Unit, Str], e :: Edge) -> Result[Unit, Str] {
    match acc {
      Err(msg) => Err(msg),
      Ok(_) =>
        if !str_contains(ids, e.from) {
          Err(str.join(["edge references unknown source node: ", e.from], ""))
        } else if !str_contains(ids, e.to) {
          Err(str.join(["edge references unknown target node: ", e.to], ""))
        } else if str.is_empty(e.handoff) {
          Err(str.join(["edge ", e.from, "->", e.to, " has no handoff schema"], ""))
        } else {
          Ok(())
        },
    }
  })
}

# ── Topological sort (pure) ───────────────────────────────────────────────────
#
# Kahn's algorithm over immutable lists. Returns layers — each layer is a set
# of node ids whose predecessors are all in prior layers. Errors on a cycle
# (use metaspec iteration budgets to allow bounded cycles).

fn topo_sort(g :: SprintGraph) -> Result[List[List[Str]], Str] {
  topo_step(g, node_ids(g), [])
}

fn topo_step(
  g         :: SprintGraph,
  remaining :: List[Str],
  acc       :: List[List[Str]],
) -> Result[List[List[Str]], Str] {
  if list.is_empty(remaining) {
    Ok(acc)
  } else {
    # A node is ready when none of its predecessors are still remaining
    let ready := str_filter(remaining, fn (id :: Str) -> Bool {
      let preds := predecessors(g, id)
      !list.fold(preds, false, fn (any_pending :: Bool, pred :: Str) -> Bool {
        if any_pending { true } else { str_contains(remaining, pred) }
      })
    })
    if list.is_empty(ready) {
      Err("cycle detected in SprintGraph — add an iteration budget to allow bounded cycles")
    } else {
      let next := str_filter(remaining, fn (id :: Str) -> Bool {
        !str_contains(ready, id)
      })
      topo_step(g, next, list.concat(acc, [ready]))
    }
  }
}

# ── Public API ────────────────────────────────────────────────────────────────

# Structural validation only — schema and spec content are checked by metaspec.
fn validate(g :: SprintGraph) -> Result[Unit, Str] {
  match validate_unique_ids(g) {
    Err(e) => Err(e),
    Ok(_) => match validate_node_fields(g) {
      Err(e) => Err(e),
      Ok(_) => match validate_edge_refs(g) {
        Err(e) => Err(e),
        Ok(_) => match topo_sort(g) {
          Err(e) => Err(e),
          Ok(_)  => Ok(()),
        },
      },
    },
  }
}

examples {
  # Empty graph is valid
  validate({ id: "g0", phase: Intake, nodes: [], edges: [] }) == Ok(())

  # Duplicate node ids are rejected
  validate({
    id: "g1", phase: Intake,
    nodes: [
      { id: "n1", role: "build", gate: "spec true" },
      { id: "n1", role: "test",  gate: "spec true" },
    ],
    edges: [],
  }) == Err("duplicate node id: n1")

  # Ungated node is rejected
  validate({
    id: "g2", phase: Intake,
    nodes: [{ id: "n1", role: "build", gate: "" }],
    edges: [],
  }) == Err("node n1 has no gate (ungated output not allowed)")

  # Edge to unknown node is rejected
  validate({
    id: "g3", phase: Intake,
    nodes: [{ id: "n1", role: "build", gate: "spec true" }],
    edges: [{ from: "n1", to: "n2", handoff: "schema {}" }],
  }) == Err("edge references unknown target node: n2")

  # Cycle is rejected
  validate({
    id: "g4", phase: Intake,
    nodes: [
      { id: "a", role: "build", gate: "spec true" },
      { id: "b", role: "test",  gate: "spec true" },
    ],
    edges: [
      { from: "a", to: "b", handoff: "schema {}" },
      { from: "b", to: "a", handoff: "schema {}" },
    ],
  }) == Err("cycle detected in SprintGraph — add an iteration budget to allow bounded cycles")

  # Valid two-node DAG returns sorted layers
  topo_sort({
    id: "g5", phase: Intake,
    nodes: [
      { id: "a", role: "build", gate: "spec true" },
      { id: "b", role: "test",  gate: "spec true" },
    ],
    edges: [{ from: "a", to: "b", handoff: "schema {}" }],
  }) == Ok([["a"], ["b"]])
}
