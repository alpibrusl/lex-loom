import "std.io"   as io
import "std.str"  as str
import "std.list" as list

import "../src/graph"    as graph
import "../src/metaspec" as meta

# ── Helpers ───────────────────────────────────────────────────────────────────

fn pass(name :: Str) -> Unit {
  let __p := io.print(str.join(["  PASS  ", name], ""))
  ()
}

fn fail(name :: Str, detail :: Str) -> Unit {
  let __p := io.print(str.join(["  FAIL  ", name, " — ", detail], ""))
  ()
}

fn assert_valid(name :: Str, g :: graph.SprintGraph) -> Unit {
  match meta.check(g) {
    meta.Valid        => pass(name),
    meta.Invalid(vs)  => fail(name, str.join(["expected Valid but got violations: ", violations_str(vs)], "")),
  }
}

fn assert_invalid(name :: Str, rule :: Str, g :: graph.SprintGraph) -> Unit {
  match meta.check(g) {
    meta.Valid => fail(name, "expected Invalid but got Valid"),
    meta.Invalid(vs) =>
      if has_rule(vs, rule) {
        pass(name)
      } else {
        fail(name, str.join(["expected rule '", rule, "' but violations were: ", violations_str(vs)], ""))
      },
  }
}

fn has_rule(vs :: List[meta.Violation], rule :: Str) -> Bool {
  list.fold(vs, false, fn (found :: Bool, v :: meta.Violation) -> Bool {
    if found { true } else { v.rule == rule }
  })
}

fn violations_str(vs :: List[meta.Violation]) -> Str {
  list.fold(vs, "", fn (acc :: Str, v :: meta.Violation) -> Str {
    str.join([acc, "[", v.rule, ": ", v.message, "] "], "")
  })
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

fn test_valid_minimal() -> Unit {
  assert_valid("single node graph", g("m1", [node("n1", "build")], []))
}

fn test_valid_qa_demo() -> Unit {
  assert_valid("qa → demo is valid", g("m2",
    [node("q", "qa"), node("d", "demo")],
    [edge("q", "d")],
  ))
}

fn test_valid_full_pipeline() -> Unit {
  assert_valid("build → qa → demo pipeline", g("m3",
    [node("b", "build"), node("q", "qa"), node("d", "demo")],
    [edge("b", "q"), edge("q", "d")],
  ))
}

fn test_empty_graph() -> Unit {
  assert_invalid("empty graph fails non-empty", "non-empty", g("m4", [], []))
}

fn test_ungated_node() -> Unit {
  assert_invalid("ungated node", "all-nodes-gated",
    g("m5", [{ id: "n1", role: "build", gate: "" }], []),
  )
}

fn test_node_no_role() -> Unit {
  assert_invalid("node without role", "all-nodes-have-role",
    g("m6", [{ id: "n1", role: "", gate: "spec true" }], []),
  )
}

fn test_edge_no_handoff() -> Unit {
  assert_invalid("edge without handoff", "all-edges-have-handoff",
    g("m7",
      [node("a", "build"), node("b", "test")],
      [{ from: "a", to: "b", handoff: "" }],
    ),
  )
}

fn test_cycle() -> Unit {
  assert_invalid("cycle fails dag rule", "dag-or-budgeted-cycle",
    g("m8",
      [node("a", "build"), node("b", "test")],
      [edge("a", "b"), edge("b", "a")],
    ),
  )
}

fn test_demo_without_qa() -> Unit {
  assert_invalid("demo without qa ancestor", "qa-dominates-demo",
    g("m9", [node("d", "demo")], []),
  )
}

fn test_demo_with_indirect_qa() -> Unit {
  # build → qa → review → demo  (QA is indirect ancestor)
  assert_valid("qa indirect ancestor of demo", g("m10",
    [node("b", "build"), node("q", "qa"), node("r", "review"), node("d", "demo")],
    [edge("b", "q"), edge("q", "r"), edge("r", "d")],
  ))
}

fn test_multiple_violations_collected() -> Unit {
  # Both empty graph + ungated would fire if there were nodes, but empty fires first.
  # Use a graph with two separate violations: cycle + demo without qa.
  let result := meta.check(g("m11",
    [node("a", "build"), node("b", "build"), node("d", "demo")],
    [edge("a", "b"), edge("b", "a")],
  ))
  match result {
    meta.Valid => fail("multiple violations collected", "expected Invalid"),
    meta.Invalid(vs) =>
      if list.fold(vs, 0, fn (n :: Int, _v :: meta.Violation) -> Int { n + 1 }) > 1 {
        pass("multiple violations collected")
      } else {
        fail("multiple violations collected", str.join(["only one violation: ", violations_str(vs)], ""))
      },
  }
}

fn main() -> [io] Unit {
  let __p := io.print("metaspec tests")
  let __1 := test_valid_minimal()
  let __2 := test_valid_qa_demo()
  let __3 := test_valid_full_pipeline()
  let __4 := test_empty_graph()
  let __5 := test_ungated_node()
  let __6 := test_node_no_role()
  let __7 := test_edge_no_handoff()
  let __8 := test_cycle()
  let __9 := test_demo_without_qa()
  let __10 := test_demo_with_indirect_qa()
  let __11 := test_multiple_violations_collected()
  ()
}
