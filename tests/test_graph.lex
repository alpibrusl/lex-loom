import "std.io"   as io
import "std.str"  as str
import "std.list" as list

import "../src/graph" as graph

# ── Helpers ───────────────────────────────────────────────────────────────────

fn pass(name :: Str) -> Unit {
  let __p := io.print(str.join(["  PASS  ", name], ""))
  ()
}

fn fail(name :: Str, got :: Str) -> Unit {
  let __p := io.print(str.join(["  FAIL  ", name, " — got: ", got], ""))
  ()
}

fn assert_ok(name :: Str, r :: Result[Unit, Str]) -> Unit {
  match r {
    Ok(_)  => pass(name),
    Err(e) => fail(name, e),
  }
}

fn assert_err(name :: Str, expected :: Str, r :: Result[Unit, Str]) -> Unit {
  match r {
    Ok(_)  => fail(name, "expected Err but got Ok"),
    Err(e) => if e == expected { pass(name) } else { fail(name, e) },
  }
}

# ── Fixtures ──────────────────────────────────────────────────────────────────

fn node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec true" }
}

fn edge(from :: Str, to :: Str) -> graph.Edge {
  { from: from, to: to, handoff: "schema {}" }
}

fn g(id :: Str, nodes :: List[graph.Node], edges :: List[graph.Edge]) -> graph.SprintGraph {
  { id: id, phase: graph.Intake, nodes: nodes, edges: edges }
}

# ── Tests ─────────────────────────────────────────────────────────────────────

fn test_empty_graph() -> Unit {
  assert_ok("empty graph is valid", graph.validate(g("t1", [], [])))
}

fn test_single_node() -> Unit {
  assert_ok("single node no edges", graph.validate(g("t2", [node("n1", "build")], [])))
}

fn test_duplicate_ids() -> Unit {
  assert_err(
    "duplicate node ids rejected",
    "duplicate node id: n1",
    graph.validate(g("t3", [node("n1", "build"), node("n1", "test")], [])),
  )
}

fn test_empty_role() -> Unit {
  assert_err(
    "empty role rejected",
    "node n1 has empty role",
    graph.validate(g("t4", [{ id: "n1", role: "", gate: "spec true" }], [])),
  )
}

fn test_ungated_node() -> Unit {
  assert_err(
    "ungated node rejected",
    "node n1 has no gate (ungated output not allowed)",
    graph.validate(g("t5", [{ id: "n1", role: "build", gate: "" }], [])),
  )
}

fn test_unknown_edge_target() -> Unit {
  assert_err(
    "edge to unknown node rejected",
    "edge references unknown target node: n2",
    graph.validate(g("t6", [node("n1", "build")], [edge("n1", "n2")])),
  )
}

fn test_unknown_edge_source() -> Unit {
  assert_err(
    "edge from unknown node rejected",
    "edge references unknown source node: n0",
    graph.validate(g("t7", [node("n1", "build")], [edge("n0", "n1")])),
  )
}

fn test_linear_dag() -> Unit {
  assert_ok(
    "linear three-node DAG is valid",
    graph.validate(g("t8",
      [node("a", "build"), node("b", "test"), node("c", "deploy")],
      [edge("a", "b"), edge("b", "c")],
    )),
  )
}

fn test_cycle_rejected() -> Unit {
  assert_err(
    "cycle rejected",
    "cycle detected in SprintGraph — add an iteration budget to allow bounded cycles",
    graph.validate(g("t9",
      [node("a", "build"), node("b", "test")],
      [edge("a", "b"), edge("b", "a")],
    )),
  )
}

fn test_diamond_dag() -> Unit {
  assert_ok(
    "diamond DAG is valid",
    graph.validate(g("t10",
      [node("a", "plan"), node("b", "build"), node("c", "build"), node("d", "merge")],
      [edge("a", "b"), edge("a", "c"), edge("b", "d"), edge("c", "d")],
    )),
  )
}

fn test_topo_sort_layers() -> Unit {
  let result := graph.topo_sort(g("t11",
    [node("a", "plan"), node("b", "build"), node("c", "test")],
    [edge("a", "b"), edge("b", "c")],
  ))
  match result {
    Err(e) => fail("topo sort linear layers", e),
    Ok(layers) =>
      if list.is_empty(layers) {
        fail("topo sort linear layers", "empty layers")
      } else {
        pass("topo sort linear layers")
      },
  }
}

fn main() -> [io] Unit {
  let __p := io.print("graph tests")
  let __1 := test_empty_graph()
  let __2 := test_single_node()
  let __3 := test_duplicate_ids()
  let __4 := test_empty_role()
  let __5 := test_ungated_node()
  let __6 := test_unknown_edge_target()
  let __7 := test_unknown_edge_source()
  let __8 := test_linear_dag()
  let __9 := test_cycle_rejected()
  let __10 := test_diamond_dag()
  let __11 := test_topo_sort_layers()
  ()
}
