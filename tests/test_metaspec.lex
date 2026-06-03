import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/graph" as graph

import "../src/metaspec" as meta

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

# ── Helpers ───────────────────────────────────────────────────────────────────
fn assert_valid(label :: Str, gr :: graph.SprintGraph) -> Result[Unit, Str] {
  match meta.check(gr) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.join([label, " should be valid but got violations: ", list.fold(vs, "", fn (acc :: Str, v :: meta.Violation) -> Str {
      str.join([acc, v.rule, ": ", v.message, "; "], "")
    })], "")),
  }
}

fn assert_has_rule(label :: Str, rule :: Str, gr :: graph.SprintGraph) -> Result[Unit, Str] {
  match meta.check(gr) {
    Valid => Err(str.join([label, " should fail rule '", rule, "' but was Valid"], "")),
    Invalid(vs) => if list.fold(vs, false, fn (found :: Bool, v :: meta.Violation) -> Bool {
      if found {
        true
      } else {
        v.rule == rule
      }
    }) {
      Ok(())
    } else {
      Err(str.join([label, " expected rule '", rule, "' but violations were: ", list.fold(vs, "", fn (acc :: Str, v :: meta.Violation) -> Str {
        str.join([acc, "[", v.rule, "] "], "")
      })], ""))
    },
  }
}

# ── Tests ─────────────────────────────────────────────────────────────────────
fn test_valid_single_node() -> Result[Unit, Str] {
  assert_valid("single node", g("m1", [node("n1", "build")], []))
}

fn test_valid_qa_demo() -> Result[Unit, Str] {
  assert_valid("qa→demo", g("m2", [node("q", "qa"), node("d", "demo")], [edge("q", "d")]))
}

fn test_valid_pipeline() -> Result[Unit, Str] {
  assert_valid("build→qa→demo", g("m3", [node("b", "build"), node("q", "qa"), node("d", "demo")], [edge("b", "q"), edge("q", "d")]))
}

fn test_empty_fails_non_empty() -> Result[Unit, Str] {
  assert_has_rule("empty graph", "non-empty", g("m4", [], []))
}

fn test_ungated_fails() -> Result[Unit, Str] {
  assert_has_rule("ungated node", "all-nodes-gated", g("m5", [{ id: "n1", role: "build", gate: "" }], []))
}

fn test_no_role_fails() -> Result[Unit, Str] {
  assert_has_rule("no role", "all-nodes-have-role", g("m6", [{ id: "n1", role: "", gate: "spec true" }], []))
}

fn test_no_handoff_fails() -> Result[Unit, Str] {
  assert_has_rule("no handoff", "all-edges-have-handoff", g("m7", [node("a", "build"), node("b", "test")], [{ from: "a", to: "b", handoff: "" }]))
}

fn test_cycle_fails_dag() -> Result[Unit, Str] {
  assert_has_rule("cycle", "dag-or-budgeted-cycle", g("m8", [node("a", "build"), node("b", "test")], [edge("a", "b"), edge("b", "a")]))
}

fn test_demo_without_qa_fails() -> Result[Unit, Str] {
  assert_has_rule("demo no qa", "qa-dominates-demo", g("m9", [node("d", "demo")], []))
}

fn test_indirect_qa_valid() -> Result[Unit, Str] {
  assert_valid("indirect qa→review→demo", g("m10", [node("b", "build"), node("q", "qa"), node("r", "review"), node("d", "demo")], [edge("b", "q"), edge("q", "r"), edge("r", "d")]))
}

fn test_multiple_violations_collected() -> Result[Unit, Str] {
  match meta.check(g("m11", [node("a", "build"), node("b", "build"), node("d", "demo")], [edge("a", "b"), edge("b", "a")])) {
    Valid => Err("expected Invalid"),
    Invalid(vs) => if list.len(vs) > 1 {
      Ok(())
    } else {
      Err(str.concat("expected multiple violations, got: ", int.to_str(list.len(vs))))
    },
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> List[Result[Unit, Str]] {
  [test_valid_single_node(), test_valid_qa_demo(), test_valid_pipeline(), test_empty_fails_non_empty(), test_ungated_fails(), test_no_role_fails(), test_no_handoff_fails(), test_cycle_fails_dag(), test_demo_without_qa_fails(), test_indirect_qa_valid(), test_multiple_violations_collected()]
}

fn run_all() -> Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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

