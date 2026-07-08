import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/graph" as graph

import "../src/metaspec" as meta

# ── Fixtures ──────────────────────────────────────────────────────────────────
fn node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec non-empty", expand: None, activate_when: "" }
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
  assert_has_rule("ungated node", "all-nodes-gated", g("m5", [{ id: "n1", role: "build", gate: "", expand: None, activate_when: "" }], []))
}

fn test_no_role_fails() -> Result[Unit, Str] {
  assert_has_rule("no role", "all-nodes-have-role", g("m6", [{ id: "n1", role: "", gate: "spec true", expand: None, activate_when: "" }], []))
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
  assert_valid("indirect qa→security→demo", g("m10", [node("b", "build"), node("q", "qa"), node("r", "security"), node("d", "demo")], [edge("b", "q"), edge("q", "r"), edge("r", "d")]))
}

# ── #33: role-resolution + gate-well-formedness ───────────────────────────────
fn test_unknown_role_fails() -> Result[Unit, Str] {
  assert_has_rule("hallucinated role", "roles-resolve", g("m12", [node("n1", "builder")], []))
}

fn test_known_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("launch is a known role", g("m13", [node("b", "build"), node("q", "qa"), node("l", "launch"), node("d", "demo")], [edge("b", "q"), edge("q", "l"), edge("l", "d")]))
}

# #84/#88: distribution roles resolve — a company can now build a graph that
# markets what it shipped, not just build/QA/demo it.
fn test_distribution_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("distribution roles are known", g("m13d", [node("b", "build"), node("q", "qa"), node("d", "demo"), node("bs", "brand_strategist"), node("cw", "copywriter"), node("cc", "content_creator"), node("seo", "seo_specialist"), node("sc", "scribe")], [edge("b", "q"), edge("q", "d"), edge("d", "bs"), edge("bs", "cw"), edge("cw", "cc"), edge("cc", "seo"), edge("seo", "sc")]))
}

# #84/#92: finance + legal role-packs resolve — tech-agnostic business
# functions, independent of the distribution phase.
fn test_finance_legal_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("finance/legal roles are known", g("m13e", [node("b", "build"), node("q", "qa"), node("d", "demo"), node("fin", "finance"), node("leg", "legal"), node("sc", "scribe")], [edge("b", "q"), edge("q", "d"), edge("d", "fin"), edge("fin", "leg"), edge("leg", "sc")]))
}

fn test_unrecognized_gate_fails() -> Result[Unit, Str] {
  assert_has_rule("garbage gate", "gates-well-formed", g("m14", [{ id: "n1", role: "build", gate: "spec maybe-ok", expand: None, activate_when: "" }], []))
}

fn test_grounded_gate_is_well_formed() -> Result[Unit, Str] {
  assert_valid("spec compiles is well-formed", g("m15", [{ id: "n1", role: "build", gate: "spec compiles", expand: None, activate_when: "" }], []))
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

fn test_expand_weak_gate_fails() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec len-gt 10", expand: Some("sub-task"), activate_when: "" }
  assert_has_rule("expand node with len-gt gate", "expand-gate", g("m12", [expand_node], []))
}

fn test_expand_strong_gate_valid() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec json", expand: Some("sub-task"), activate_when: "" }
  assert_valid("expand node with json gate", g("m13", [expand_node], []))
}

fn test_expand_non_empty_gate_valid() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec non-empty", expand: Some("sub-task"), activate_when: "" }
  assert_valid("expand node with non-empty gate", g("m14", [expand_node], []))
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> List[Result[Unit, Str]] {
  [test_valid_single_node(), test_valid_qa_demo(), test_valid_pipeline(), test_empty_fails_non_empty(), test_ungated_fails(), test_no_role_fails(), test_no_handoff_fails(), test_cycle_fails_dag(), test_demo_without_qa_fails(), test_indirect_qa_valid(), test_multiple_violations_collected(), test_unknown_role_fails(), test_known_roles_pass_resolution(), test_distribution_roles_pass_resolution(), test_finance_legal_roles_pass_resolution(), test_unrecognized_gate_fails(), test_grounded_gate_is_well_formed(), test_expand_weak_gate_fails(), test_expand_strong_gate_valid(), test_expand_non_empty_gate_valid()]
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

